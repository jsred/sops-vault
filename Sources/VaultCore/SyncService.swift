import Foundation

public struct PullRequestRef: Codable, Sendable, Equatable {
    public let branch: String
    public let url: URL?
    public init(branch: String, url: URL?) { self.branch = branch; self.url = url }
}

public struct SyncStatus: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        /// Not synced with git; saving writes the local file. The string explains why.
        case local(String)
        /// Read from and saved to this branch of origin.
        case git(branch: String)
    }
    public enum LocalCopy: Sendable, Equatable {
        /// The working copy matches what is shown.
        case current
        /// The working copy is an older committed version: `git pull` brings it up to date.
        case behind
        /// The working copy has uncommitted edits that are not in origin.
        case modified
        /// SOPS Vault saved changes here while offline; they are staged to upload.
        case savedOffline
        /// The file is not in origin yet; saving uploads it.
        case newFile
    }
    public var storage: Storage
    public var localCopy: LocalCopy = .current
    public var pullRequest: PullRequestRef?
    public var fetchFailed = false
    public var alwaysPullRequest = false
    public var isGit: Bool { if case .git = storage { return true }; return false }
}

public struct LoadedFile: Sendable {
    /// What the app shows and edits: origin's version for synced files, otherwise the local file.
    public let document: VaultDocument
    public let status: SyncStatus
    /// Unpushed edits found in the working copy, as changes that can be replayed on origin's version.
    public let localChanges: [SecretChange]
}

public enum SaveOutcome: Sendable {
    case saved(LoadedFile, message: String)
    /// Someone changed these keys in origin since the edit started. Nothing was saved.
    case conflicts([SecretChange])
}

public enum ConflictResolution: Sendable { case keepMine, keepTheirs }

public enum SyncError: Error, Equatable { case offline }

/// Non-secret sync bookkeeping in UserDefaults: open PRs, offline saves and per-repo PR preference.
public final class SyncMemory: @unchecked Sendable {
    private struct Entry: Codable { var pullRequest: PullRequestRef?; var offlineBlob: String?; var offlineBase: String? }
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let key = "vault.sync.files"
    private let prKey = "vault.sync.alwaysPullRequest"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var all = entries()
        var entry = all[id] ?? Entry()
        change(&entry)
        all[id] = (entry.pullRequest == nil && entry.offlineBlob == nil) ? nil : entry
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
    }
    func pullRequest(_ id: String) -> PullRequestRef? { entries()[id]?.pullRequest }
    func setPullRequest(_ id: String, _ value: PullRequestRef?) { update(id) { $0.pullRequest = value } }
    func offline(_ id: String) -> (blob: String, base: String?)? {
        entries()[id].flatMap { entry in entry.offlineBlob.map { ($0, entry.offlineBase) } }
    }
    func setOffline(_ id: String, blob: String?, base: String?) { update(id) { $0.offlineBlob = blob; $0.offlineBase = base } }
    func alwaysPullRequest(_ root: String) -> Bool { (defaults.stringArray(forKey: prKey) ?? []).contains(root) }
    func setAlwaysPullRequest(_ root: String, _ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        var roots = Set(defaults.stringArray(forKey: prKey) ?? [])
        if enabled { roots.insert(root) } else { roots.remove(root) }
        defaults.set(roots.sorted(), forKey: prKey)
    }
}

/// Keeps edits in origin instead of only on this Mac. For files tracked in a repo with an `origin`
/// remote, it reads origin's latest version, replays pending changes on it, commits only that file on
/// top of origin's branch and pushes. The local checkout (branch, index, working tree) is never touched,
/// so `git pull` keeps working. Protected branches get a pull request instead.
public actor SyncService {
    private let sops: SOPSService
    private let memory: SyncMemory
    private let git: GitClient?
    private let pullRequests: PullRequestClient

    public init(sops: SOPSService = SOPSService(), memory: SyncMemory = SyncMemory(),
                gitPath: String? = nil, ghPath: String? = nil) {
        self.sops = sops; self.memory = memory
        git = GitClient(path: gitPath)
        pullRequests = PullRequestClient(path: ghPath)
    }

    private struct Repo {
        let git: GitClient
        let root: URL
        let path: String
        let branch: String
        let remote: String
        var id: String { root.path + "|" + path }
    }

    private func repo(for file: URL) -> (Repo?, String) {
        guard let git else { return (nil, String(localized: "git is not installed")) }
        guard let (root, path) = git.locate(file) else { return (nil, String(localized: "not in a git repository")) }
        guard let remote = git.remoteURL(in: root) else { return (nil, String(localized: "the repository has no origin remote")) }
        if git.isIgnored(path, in: root) { return (nil, String(localized: "git ignores this file")) }
        guard let branch = git.defaultBranch(in: root) else { return (nil, String(localized: "origin's default branch could not be determined")) }
        return (Repo(git: git, root: root, path: path, branch: branch, remote: remote), "")
    }

    /// Explicitly update the checkout, without merging or stashing local work.
    public func pullLocalCopy(for file: URL) throws {
        guard let git, let (root, _) = git.locate(file),
              let state = try? git.run(["status", "--porcelain", "--untracked-files=all"], in: root),
              state.status == 0, state.output.isEmpty,
              let result = try? git.run(["-c", "core.hooksPath=/dev/null", "pull", "--ff-only", "--no-rebase", "--no-autostash"], in: root, timeout: 60),
              result.status == 0 else {
            throw NSError(domain: "SOPSVault.Pull", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Could not update the local copy. Check the connection, branch upstream, and that the repository has no local changes or diverging commits.")])
        }
    }

    public func setAlwaysPullRequest(for file: URL, _ enabled: Bool) {
        if let git, let (root, _) = git.locate(file) { memory.setAlwaysPullRequest(root.path, enabled) }
    }

    // MARK: Load

    public func load(_ file: URL, configuration: SOPSConfiguration) async throws -> LoadedFile {
        let (found, reason) = repo(for: file)
        guard let repo = found else {
            let document = try await sops.load(url: file, configuration: configuration)
            return LoadedFile(document: document, status: SyncStatus(storage: .local(reason)), localChanges: [])
        }
        let fetched = repo.git.fetch(repo.branch, in: repo.root) == .ok
        let pullRequest = refreshPullRequest(repo)
        return try await describe(repo, file: file, pullRequest: pullRequest, fetchFailed: !fetched, configuration: configuration)
    }

    /// Drops the tracked PR once it is merged, closed or its branch is gone. Network failures keep it.
    private func refreshPullRequest(_ repo: Repo) -> PullRequestRef? {
        guard let pr = memory.pullRequest(repo.id) else { return nil }
        let fetch = repo.git.fetch(pr.branch, in: repo.root)
        var finished = fetch == .missingRef
        if fetch == .ok {
            if let url = pr.url, let state = pullRequests.state(of: url, in: repo.root) {
                finished = state != "OPEN"
            } else {
                finished = repo.git.isAncestor(GitClient.remoteRef(pr.branch), of: GitClient.remoteRef(repo.branch), in: repo.root)
            }
        }
        if finished { memory.setPullRequest(repo.id, nil); return nil }
        return pr
    }

    private func describe(_ repo: Repo, file: URL, pullRequest: PullRequestRef?, fetchFailed: Bool,
                          configuration: SOPSConfiguration) async throws -> LoadedFile {
        let git = repo.git
        let sourceRef = GitClient.remoteRef(pullRequest?.branch ?? repo.branch)
        var status = SyncStatus(storage: .git(branch: repo.branch), pullRequest: pullRequest, fetchFailed: fetchFailed,
                                alwaysPullRequest: memory.alwaysPullRequest(repo.root.path))
        guard let remoteID = git.blobID(sourceRef, repo.path, in: repo.root),
              let remoteBlob = git.blob(id: remoteID, in: repo.root) else {
            if !fetchFailed && !git.hasRef(sourceRef, in: repo.root) {
                throw VaultError.localized("Branch \(repo.branch) was not found in origin.")
            }
            status.localCopy = .newFile
            let document = try await sops.load(url: file, configuration: configuration)
            return LoadedFile(document: document, status: status, localChanges: [])
        }
        let format = FileFormat.detect(url: file, data: remoteBlob)
        let document = try await sops.decrypt(ciphertext: remoteBlob, format: format, configuration: configuration)
        let localID = git.workingBlobID(repo.path, in: repo.root)
        let headID = git.blobID("HEAD", repo.path, in: repo.root)
        let offline = memory.offline(repo.id)
        if let offline, offline.blob != localID { memory.setOffline(repo.id, blob: nil, base: nil) }
        var baseID: String?
        if localID == nil || localID == remoteID || (pullRequest != nil && localID == git.blobID(GitClient.remoteRef(repo.branch), repo.path, in: repo.root)) {
            status.localCopy = .current
        } else if let offline, offline.blob == localID {
            status.localCopy = .savedOffline; baseID = offline.base
        } else if localID == headID {
            status.localCopy = .behind
        } else {
            status.localCopy = .modified; baseID = headID ?? remoteID
        }
        var localChanges: [SecretChange] = []
        if let baseID, let baseBlob = git.blob(id: baseID, in: repo.root), let localData = try? await sops.ciphertext(of: file) {
            let base = try await sops.decrypt(ciphertext: baseBlob, format: format, configuration: configuration)
            let local = try await sops.decrypt(ciphertext: localData, format: format, configuration: configuration)
            localChanges = Merge.diff(from: base.root, to: local.root)
        }
        return LoadedFile(document: document, status: status, localChanges: localChanges)
    }

    // MARK: Save

    /// Saves `changes` (made on top of `displayed`). For synced files, throws `SyncError.offline` when origin
    /// cannot be reached; `saveOffline` is the fallback.
    public func save(_ file: URL, changes: [SecretChange], displayed: VaultDocument, resolution: ConflictResolution?,
                     configuration: SOPSConfiguration) async throws -> SaveOutcome {
        let (found, reason) = repo(for: file)
        guard let repo = found else {
            let document = try await sops.mutate(url: file, expectedCiphertext: displayed.ciphertext,
                                                 changes: changes, configuration: configuration)
            return .saved(LoadedFile(document: document, status: SyncStatus(storage: .local(reason)), localChanges: []),
                          message: String(localized: "Changes saved and verified on this Mac."))
        }
        let git = repo.git
        for _ in 0..<3 {
            guard git.fetch(repo.branch, in: repo.root) == .ok else { throw SyncError.offline }
            let pullRequest = refreshPullRequest(repo)
            let target = pullRequest?.branch ?? repo.branch
            let sourceRef = GitClient.remoteRef(target)
            let remoteBlob = git.blob(sourceRef, repo.path, in: repo.root)
            let base: Data
            if let remoteBlob { base = remoteBlob } else { base = try await sops.ciphertext(of: file) }
            let format = FileFormat.detect(url: file, data: base)
            let current = try await sops.decrypt(ciphertext: base, format: format, configuration: configuration)
            var effective = changes
            let conflicts = Merge.conflicts(changes, remote: current.root)
            if !conflicts.isEmpty {
                switch resolution {
                case nil: return .conflicts(conflicts)
                case .keepTheirs: effective.removeAll { change in conflicts.contains { $0.id == change.id } }
                case .keepMine: break
                }
            }
            let updated = try await sops.apply(effective, to: base, format: format, near: file.deletingLastPathComponent(),
                                               configuration: configuration)
            if remoteBlob != nil && updated.ciphertext == base {
                return .saved(try await describe(repo, file: file, pullRequest: pullRequest, fetchFailed: false, configuration: configuration),
                              message: String(localized: "There was nothing new to push; origin already had those values."))
            }
            let changedNames = Merge.diff(from: current.root, to: updated.root).map(\.name)
            let commit = try git.commit(updated.ciphertext, at: repo.path, onto: sourceRef,
                                        message: commitMessage(path: repo.path, keys: changedNames, isNew: remoteBlob == nil),
                                        in: repo.root)
            var outcome: PushResult = .rejected
            if pullRequest != nil || !memory.alwaysPullRequest(repo.root.path) {
                outcome = git.push(commit, to: target, in: repo.root)
            }
            var message: String
            switch outcome {
            case .pushed:
                message = pullRequest == nil ? String(localized: "Changes pushed to origin/\(repo.branch).") : String(localized: "Changes added to the open PR.")
            case .outdated:
                continue
            case .failed(let text):
                throw VaultError.message(text)
            case .rejected:
                guard pullRequest == nil else {
                    throw VaultError.localized("Origin rejected the change on the PR branch. Check your permissions in the repository.")
                }
                let pr = try openPullRequest(repo, commit: commit, keys: changedNames)
                message = pr.url == nil ? String(localized: "Branch \(repo.branch) is protected: the change was pushed to \(pr.branch). Open the PR on GitHub.")
                                        : String(localized: "Branch \(repo.branch) is protected: a PR with the change was opened.")
            }
            settleOfflineCopy(repo)
            // Refresh the remote-tracking refs the status is computed from.
            _ = git.fetch(repo.branch, in: repo.root)
            if let pr = memory.pullRequest(repo.id) { _ = git.fetch(pr.branch, in: repo.root) }
            var loaded = try await describe(repo, file: file, pullRequest: memory.pullRequest(repo.id), fetchFailed: false,
                                            configuration: configuration)
            if loaded.document.root != updated.root {
                // origin moved again between the push and the refresh; show what was saved.
                loaded = LoadedFile(document: updated, status: loaded.status, localChanges: loaded.localChanges)
            }
            if loaded.status.localCopy == .behind { message += " " + String(localized: "Update your local copy with git pull.") }
            if remoteBlob == nil && git.blobID("HEAD", repo.path, in: repo.root) == nil {
                message += " " + String(localized: "Before running git pull, delete the untracked local copy of this file.")
            }
            return .saved(loaded, message: message)
        }
        throw VaultError.localized("Origin changed several times while saving. Try again.")
    }

    /// Offline fallback: writes the encrypted result to the local file and remembers it, so the next
    /// load stages those edits again for upload.
    public func saveOffline(_ file: URL, changes: [SecretChange], displayed: VaultDocument,
                            configuration: SOPSConfiguration) async throws -> LoadedFile {
        let (found, _) = repo(for: file)
        guard let repo = found else { throw VaultError.localized("This file is not synced with git.") }
        let git = repo.git
        let localID = git.workingBlobID(repo.path, in: repo.root)
        let headID = git.blobID("HEAD", repo.path, in: repo.root)
        let offline = memory.offline(repo.id)
        guard localID == headID || localID == offline?.blob || headID == nil && localID == nil else {
            throw VaultError.localized("Your local copy has its own changes. Bring them in before saving offline.")
        }
        let format = FileFormat.detect(url: file, data: displayed.ciphertext)
        let updated = try await sops.apply(changes, to: displayed.ciphertext, format: format,
                                           near: file.deletingLastPathComponent(), configuration: configuration)
        let current = try await sops.ciphertext(of: file)
        try await sops.replace(file, expected: current, with: updated.ciphertext)
        let baseID = offline?.base ?? git.text(["hash-object", "-w", "--stdin"], in: repo.root, input: displayed.ciphertext)
        memory.setOffline(repo.id, blob: git.workingBlobID(repo.path, in: repo.root), base: baseID)
        var status = SyncStatus(storage: .git(branch: repo.branch), pullRequest: memory.pullRequest(repo.id), fetchFailed: true,
                                alwaysPullRequest: memory.alwaysPullRequest(repo.root.path))
        status.localCopy = .savedOffline
        return LoadedFile(document: updated, status: status, localChanges: [])
    }

    /// After a successful upload, a working copy SOPS Vault wrote offline goes back to its committed
    /// version so `git pull` is not blocked by it.
    private func settleOfflineCopy(_ repo: Repo) {
        guard let offline = memory.offline(repo.id) else { return }
        if repo.git.workingBlobID(repo.path, in: repo.root) == offline.blob,
           repo.git.blobID("HEAD", repo.path, in: repo.root) != nil {
            repo.git.restoreFromHEAD(repo.path, in: repo.root)
        }
        memory.setOffline(repo.id, blob: nil, base: nil)
    }

    private func openPullRequest(_ repo: Repo, commit: String, keys: [String]) throws -> PullRequestRef {
        let stem = (repo.path as NSString).lastPathComponent.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let branch = "sops-vault/\(stem)-\(formatter.string(from: Date()))"
        switch repo.git.push(commit, to: branch, in: repo.root) {
        case .pushed: break
        case .failed(let text): throw VaultError.message(text)
        default: throw VaultError.localized("Origin rejected the PR branch. Check your permissions in the repository.")
        }
        let web = GitClient.webRepository(remote: repo.remote)
        let body = """
        Updated with SOPS Vault. The file stays encrypted with SOPS + age; only key names are listed here.

        \(keys.isEmpty ? "" : "Keys: " + keys.map { "`\($0)`" }.joined(separator: ", "))
        """
        // PR text goes to GitHub and stays in English, like commit messages.
        let prTitle = "Update \(repo.path) (SOPS Vault)"
        var url = pullRequests.create(in: repo.root, slug: web?.slug, head: branch, base: repo.branch,
                                      title: prTitle, body: body)
        if url == nil, let web {
            url = URL(string: web.web.absoluteString + "/compare/\(repo.branch)...\(branch)?expand=1")
        }
        let pr = PullRequestRef(branch: branch, url: url)
        memory.setPullRequest(repo.id, pr)
        return pr
    }

    private func commitMessage(path: String, keys: [String], isNew: Bool) -> String {
        var message = isNew ? "Add \(path) via SOPS Vault" : "Update \(path) via SOPS Vault"
        if !keys.isEmpty { message += "\n\nKeys: " + keys.joined(separator: ", ") }
        return message + "\n"
    }
}
