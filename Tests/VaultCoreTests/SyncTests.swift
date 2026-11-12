import Foundation
import Testing
@testable import VaultCore

/// Real git + SOPS against a throwaway bare "origin" in a private temp directory, with a test age key
/// and fake values. Never touches the user's repositories, remotes or identity.
@Suite(.serialized, .timeLimit(.minutes(2))) final class SyncTests {
    private let directory: URL
    private let origin: URL
    private let config: SOPSConfiguration
    private let recipient: String
    private let defaults: UserDefaults
    private let suite = "sops-vault-sync-tests-\(UUID().uuidString)"
    private let gitPath = ["/opt/homebrew/bin/git", "/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }!

    init() throws {
        let fm = FileManager.default
        let created = fm.temporaryDirectory.appendingPathComponent("sops-vault-sync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = Discovery.canonical(created)
        origin = directory.appendingPathComponent("origin.git", isDirectory: true)
        let ageKeygen = ["/opt/homebrew/bin/age-keygen", "/usr/local/bin/age-keygen"].first { fm.isExecutableFile(atPath: $0) }!
        let key = directory.appendingPathComponent("test.agekey")
        let env = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": directory.path]
        _ = try ProcessRunner.run(executable: URL(fileURLWithPath: ageKeygen), arguments: ["-o", key.path], environment: env)
        let publicKey = try ProcessRunner.run(executable: URL(fileURLWithPath: ageKeygen), arguments: ["-y", key.path], environment: env)
        recipient = String(decoding: publicKey.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        config = SOPSConfiguration(executablePath: try SOPSConfiguration().executable().path, ageKeyPath: key.path)
        defaults = UserDefaults(suiteName: suite)!
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @discardableResult
    private func git(_ args: String..., in dir: URL? = nil) throws -> String {
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: gitPath), arguments: args,
                                           environment: GitClient.environment(), directory: dir ?? directory, captureErrors: true, tool: "git")
        guard result.status == 0 else { throw VaultError.message("git \(args.joined(separator: " ")) failed: \(result.combinedText)") }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func clone(_ name: String) throws -> URL {
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        try git("clone", "-q", origin.path, dir.path)
        try git("config", "user.name", "SOPS Vault Test", in: dir)
        try git("config", "user.email", "test@example.invalid", in: dir)
        return dir
    }
    private func encrypt(_ plaintext: String, name: String) throws -> Data {
        let result = try ProcessRunner.run(executable: try config.executable(),
            arguments: ["encrypt", "--age", recipient, "--input-type", "dotenv", "--output-type", "dotenv",
                        "--filename-override", name, "/dev/stdin"],
            input: Data(plaintext.utf8), environment: try config.environment())
        guard result.status == 0 else { throw VaultError.message("encrypt failed") }
        return result.output
    }
    /// origin with one commit containing secrets.enc.env, plus a clone `a` that made it.
    private func makeOrigin() throws -> URL {
        try git("init", "-q", "--bare", "-b", "main", origin.path)
        let a = try clone("a")
        try encrypt("API_TOKEN=FAKE_one\nDB_URL=FAKE_db\n", name: "secrets.enc.env")
            .write(to: a.appendingPathComponent("secrets.enc.env"))
        try git("add", "secrets.enc.env", in: a)
        try git("commit", "-q", "-m", "initial", in: a)
        try git("push", "-q", "origin", "main", in: a)
        return a
    }
    private func service() -> SyncService {
        SyncService(memory: SyncMemory(defaults: defaults), gitPath: gitPath, ghPath: "/nonexistent/gh")
    }
    private func originValue(_ key: String, branch: String = "main") async throws -> JSONValue? {
        let blob = try ProcessRunner.run(executable: URL(fileURLWithPath: gitPath), arguments: ["cat-file", "blob", "\(branch):secrets.enc.env"],
                                         environment: GitClient.environment(), directory: origin).output
        return try await SOPSService().decrypt(ciphertext: blob, format: .dotenv, configuration: config).root[[.key(key)]]
    }
    private func change(_ key: String, from old: String?, to new: String?) -> SecretChange {
        SecretChange(path: [.key(key)], original: old.map(JSONValue.string), value: new.map(JSONValue.string))
    }

    @Test func savePushesOnlyThatFileAndLeavesCheckoutAlone() async throws {
        _ = try makeOrigin()
        let b = try clone("b")
        let file = b.appendingPathComponent("secrets.enc.env")
        let before = try Data(contentsOf: file)
        let head = try git("rev-parse", "HEAD", in: b)
        let sync = service()
        let loaded = try await sync.load(file, configuration: config)
        #expect(loaded.status.storage == .git(branch: "main"))
        #expect(loaded.status.localCopy == .current)
        let outcome = try await sync.save(file, changes: [change("API_TOKEN", from: "FAKE_one", to: "FAKE_two")],
                                          displayed: loaded.document, resolution: nil, configuration: config)
        guard case .saved(let saved, let message) = outcome else { Issue.record("expected save"); return }
        #expect(message.contains("origin/main"))
        #expect(saved.document.root[[.key("API_TOKEN")]] == .string("FAKE_two"))
        #expect(saved.status.localCopy == .behind)
        #expect(try await originValue("API_TOKEN") == .string("FAKE_two"))
        #expect(try await originValue("DB_URL") == .string("FAKE_db"))
        // Working tree, index and branch untouched; a normal pull then succeeds.
        #expect(try Data(contentsOf: file) == before)
        #expect(try git("rev-parse", "HEAD", in: b) == head)
        #expect(try git("status", "--porcelain", in: b).isEmpty)
        try git("pull", "-q", "--ff-only", in: b)
        #expect(try git("log", "-1", "--format=%s", in: b).hasPrefix("Update secrets.enc.env via SOPS Vault"))
        #expect(try git("diff", "--name-only", "HEAD~1", "HEAD", in: b) == "secrets.enc.env")
        let commitBody = try git("log", "-1", "--format=%B", in: b)
        #expect(commitBody.contains("API_TOKEN") && !commitBody.contains("FAKE_"))
    }

    @Test func replaysChangesOnNewerOriginAndReportsConflicts() async throws {
        let a = try makeOrigin()
        let b = try clone("b")
        let syncB = service()
        let fileB = b.appendingPathComponent("secrets.enc.env")
        let loadedB = try await syncB.load(fileB, configuration: config)
        // Meanwhile the other Mac changes API_TOKEN.
        let syncA = service()
        let fileA = a.appendingPathComponent("secrets.enc.env")
        let loadedA = try await syncA.load(fileA, configuration: config)
        _ = try await syncA.save(fileA, changes: [change("API_TOKEN", from: "FAKE_one", to: "FAKE_from_a")],
                                 displayed: loadedA.document, resolution: nil, configuration: config)
        // A different key merges cleanly on top of the newer origin.
        let merged = try await syncB.save(fileB, changes: [change("DB_URL", from: "FAKE_db", to: "FAKE_db_b")],
                                          displayed: loadedB.document, resolution: nil, configuration: config)
        guard case .saved = merged else { Issue.record("expected clean merge"); return }
        #expect(try await originValue("API_TOKEN") == .string("FAKE_from_a"))
        #expect(try await originValue("DB_URL") == .string("FAKE_db_b"))
        // The same key is a conflict; nothing is pushed until the user decides.
        let edit = [change("API_TOKEN", from: "FAKE_one", to: "FAKE_from_b"), change("NEW_KEY", from: nil, to: "FAKE_new")]
        let conflicted = try await syncB.save(fileB, changes: edit, displayed: loadedB.document, resolution: nil, configuration: config)
        guard case .conflicts(let list) = conflicted else { Issue.record("expected conflict"); return }
        #expect(list.map(\.name) == ["API_TOKEN"])
        #expect(try await originValue("NEW_KEY") == nil)
        let theirs = try await syncB.save(fileB, changes: edit, displayed: loadedB.document, resolution: .keepTheirs, configuration: config)
        guard case .saved = theirs else { Issue.record("expected save"); return }
        #expect(try await originValue("API_TOKEN") == .string("FAKE_from_a"))
        #expect(try await originValue("NEW_KEY") == .string("FAKE_new"))
        let mine = try await syncB.save(fileB, changes: edit, displayed: loadedB.document, resolution: .keepMine, configuration: config)
        guard case .saved = mine else { Issue.record("expected save"); return }
        #expect(try await originValue("API_TOKEN") == .string("FAKE_from_b"))
    }

    @Test func protectedBranchGoesToPullRequestBranch() async throws {
        _ = try makeOrigin()
        let hook = origin.appendingPathComponent("hooks/pre-receive")
        try """
        #!/bin/sh
        while read old new ref; do
          if [ "$ref" = "refs/heads/main" ]; then echo "GH006: Protected branch update failed for refs/heads/main." >&2; exit 1; fi
        done
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let b = try clone("b")
        let file = b.appendingPathComponent("secrets.enc.env")
        let sync = service()
        let loaded = try await sync.load(file, configuration: config)
        let first = try await sync.save(file, changes: [change("API_TOKEN", from: "FAKE_one", to: "FAKE_pr")],
                                        displayed: loaded.document, resolution: nil, configuration: config)
        guard case .saved(let saved, let message) = first, let pr = saved.status.pullRequest else { Issue.record("expected PR"); return }
        #expect(message.contains("protected"))
        #expect(pr.branch.hasPrefix("sops-vault/secrets-enc-env-"))
        #expect(try await originValue("API_TOKEN") == .string("FAKE_one"))
        #expect(try await originValue("API_TOKEN", branch: pr.branch) == .string("FAKE_pr"))
        // While the PR is open the app shows and extends the PR branch.
        #expect(saved.document.root[[.key("API_TOKEN")]] == .string("FAKE_pr"))
        let second = try await sync.save(file, changes: [change("DB_URL", from: "FAKE_db", to: "FAKE_db_pr")],
                                         displayed: saved.document, resolution: nil, configuration: config)
        guard case .saved(let again, let secondMessage) = second else { Issue.record("expected save"); return }
        #expect(secondMessage.contains("PR"))
        #expect(again.status.pullRequest == pr)
        #expect(try await originValue("DB_URL", branch: pr.branch) == .string("FAKE_db_pr"))
        #expect(try await originValue("API_TOKEN", branch: pr.branch) == .string("FAKE_pr"))
        // Once the branch is merged, the app goes back to main.
        try FileManager.default.removeItem(at: hook)
        let c = try clone("c")
        try git("merge", "-q", "--ff-only", "origin/\(pr.branch)", in: c)
        try git("push", "-q", "origin", "main", in: c)
        let reloaded = try await sync.load(file, configuration: config)
        #expect(reloaded.status.pullRequest == nil)
        #expect(reloaded.document.root[[.key("DB_URL")]] == .string("FAKE_db_pr"))
    }

    @Test func offlineSaveIsStagedAgainAndSettledAfterUpload() async throws {
        _ = try makeOrigin()
        let b = try clone("b")
        let file = b.appendingPathComponent("secrets.enc.env")
        let committed = try Data(contentsOf: file)
        let sync = service()
        let loaded = try await sync.load(file, configuration: config)
        try git("remote", "set-url", "origin", directory.appendingPathComponent("missing.git").path, in: b)
        let edit = [change("API_TOKEN", from: "FAKE_one", to: "FAKE_offline")]
        await #expect(throws: SyncError.offline) {
            _ = try await sync.save(file, changes: edit, displayed: loaded.document, resolution: nil, configuration: self.config)
        }
        let offline = try await sync.saveOffline(file, changes: edit, displayed: loaded.document, configuration: config)
        #expect(offline.status.localCopy == .savedOffline)
        #expect(try Data(contentsOf: file) != committed)
        let reopened = try await sync.load(file, configuration: config)
        #expect(reopened.status.fetchFailed)
        #expect(reopened.status.localCopy == .savedOffline)
        #expect(reopened.localChanges == edit)
        try git("remote", "set-url", "origin", origin.path, in: b)
        let uploaded = try await sync.save(file, changes: reopened.localChanges, displayed: reopened.document,
                                           resolution: nil, configuration: config)
        guard case .saved = uploaded else { Issue.record("expected upload"); return }
        #expect(try await originValue("API_TOKEN") == .string("FAKE_offline"))
        #expect(try Data(contentsOf: file) == committed)
        try git("pull", "-q", "--ff-only", in: b)
    }

    @Test func filesOutsideGitSaveLocally() async throws {
        let plain = directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        let file = plain.appendingPathComponent("local.enc.env")
        try encrypt("API_TOKEN=FAKE_local\n", name: "local.enc.env").write(to: file)
        let sync = service()
        let loaded = try await sync.load(file, configuration: config)
        guard case .local = loaded.status.storage else { Issue.record("expected local"); return }
        let outcome = try await sync.save(file, changes: [change("API_TOKEN", from: "FAKE_local", to: "FAKE_changed")],
                                          displayed: loaded.document, resolution: nil, configuration: config)
        guard case .saved(let saved, _) = outcome else { Issue.record("expected save"); return }
        #expect(saved.document.root[[.key("API_TOKEN")]] == .string("FAKE_changed"))
        let reread = try await SOPSService().load(url: file, configuration: config)
        #expect(reread.root[[.key("API_TOKEN")]] == .string("FAKE_changed"))
    }
}

extension SyncTests {
    @Test func pullFastForwardsAndRefusesLocalChangesAndDivergence() async throws {
        let a = try makeOrigin()
        let b = try clone("b")
        let file = b.appendingPathComponent("secrets.enc.env")
        let sync = service()
        try "remote".write(to: a.appendingPathComponent("readme"), atomically: true, encoding: .utf8)
        try git("add", ".", in: a); try git("commit", "-qm", "remote", in: a); try git("push", "-q", in: a)
        try await sync.pullLocalCopy(for: file)
        #expect(try git("rev-parse", "HEAD", in: b) == git("rev-parse", "HEAD", in: a))
        let dirty = b.appendingPathComponent("dirty")
        try Data().write(to: dirty)
        await #expect(throws: NSError.self) { try await sync.pullLocalCopy(for: file) }
        try FileManager.default.removeItem(at: dirty)
        try git("commit", "--allow-empty", "-qm", "local", in: b)
        try git("commit", "--allow-empty", "-qm", "remote", in: a); try git("push", "-q", in: a)
        let before = try git("rev-parse", "HEAD", in: b)
        await #expect(throws: NSError.self) { try await sync.pullLocalCopy(for: file) }
        #expect(try git("rev-parse", "HEAD", in: b) == before)
    }

    @Test func modifiedAndNewFilesNoOpSaveAndOfflineRejections() async throws {
        let a = try makeOrigin()
        let sync = service()
        let file = a.appendingPathComponent("secrets.enc.env")
        let loaded = try await sync.load(file, configuration: config)
        let noop = try await sync.save(file, changes: [], displayed: loaded.document, resolution: nil, configuration: config)
        guard case .saved(_, let message) = noop else { Issue.record("expected no-op"); return }
        #expect(message.contains("nothing new"))
        try encrypt("API_TOKEN=FAKE_local\nDB_URL=FAKE_db\n", name: file.lastPathComponent).write(to: file)
        let modified = try await sync.load(file, configuration: config)
        #expect(modified.status.localCopy == .modified)
        #expect(modified.localChanges == [change("API_TOKEN", from: "FAKE_one", to: "FAKE_local")])
        await #expect(throws: VaultError.self) {
            try await sync.saveOffline(file, changes: [], displayed: loaded.document, configuration: self.config)
        }
        let newFile = a.appendingPathComponent("new.enc.env")
        try encrypt("NEW=FAKE_new\n", name: newFile.lastPathComponent).write(to: newFile)
        let newLoaded = try await sync.load(newFile, configuration: config)
        #expect(newLoaded.status.localCopy == .newFile)
        let saved = try await sync.save(newFile, changes: [], displayed: newLoaded.document, resolution: nil, configuration: config)
        guard case .saved(_, let newMessage) = saved else { Issue.record("expected new file save"); return }
        #expect(newMessage.contains("untracked"))
        #expect(try git("log", "origin/main", "-1", "--format=%s", in: a).hasPrefix("Add new.enc.env"))
        await sync.setAlwaysPullRequest(for: file, true)
        #expect(try await sync.load(file, configuration: config).status.alwaysPullRequest)
        await sync.setAlwaysPullRequest(for: file, false)
        #expect(try await !sync.load(file, configuration: config).status.alwaysPullRequest)
    }

    /// Executable wrapper allows transport failures without networking or production remotes.
    private func gitWrapper(_ body: String) throws -> String {
        let url = directory.appendingPathComponent("git-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\nexec \(gitPath) \"$@\"\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    @Test func gitFailuresAndFallbackBranchDiscovery() throws {
        let a = try makeOrigin()
        let client = GitClient(path: gitPath)!
        #expect(client.hasRef("HEAD", in: a))
        #expect(!client.hasRef("missing", in: a))
        #expect(client.blob("missing", "no-file", in: a) == nil)
        #expect(client.blob(id: "missing", in: a) == nil)
        let fallback = GitClient(path: try gitWrapper("case \"$1\" in symbolic-ref|ls-remote) exit 1;; esac"))!
        #expect(fallback.defaultBranch(in: a) == "main")
        #expect(fallback.defaultBranch(in: directory) == nil)
        for (command, message) in [("rev-parse", "branch was not found"), ("hash-object", "store"), ("read-tree", "prepare"), ("commit-tree", "create")] {
            let broken = GitClient(path: try gitWrapper("if [ \"$1\" = \(command) ]; then exit 1; fi"))!
            do {
                _ = try broken.commit(Data(), at: "new", onto: "HEAD", message: "fixture", in: a)
                Issue.record("expected commit failure")
            } catch { #expect(error.localizedDescription.contains(message)) }
        }
        for (text, expected) in [("non-fast-forward", PushResult.outdated), ("permission denied", .failed("You don't have permission to push to this repository.")),
                                 ("unexpected transport failure", .failed("git could not push the change. Check the connection and try again."))] {
            let broken = GitClient(path: try gitWrapper("if [ \"$1\" = push ]; then echo '\(text)' >&2; exit 1; fi"))!
            #expect(broken.push("HEAD", to: "main", in: a) == expected)
        }
    }

    @Test func fakeGitHubCLIResponses() throws {
        let url = URL(string: "https://github.com/test/repo/pull/1")!
        let executable = try gitWrapper("cat >/dev/null; if [ \"$2\" = create ]; then echo notice; echo '\(url.absoluteString)'; else echo OPEN; fi; exit 0")
        let client = PullRequestClient(path: executable)
        #expect(client.create(in: directory, slug: "test/repo", head: "change", base: "main", title: "fixture", body: "body") == url)
        #expect(client.state(of: url, in: directory) == "OPEN")
        let failed = PullRequestClient(path: try gitWrapper("exit 1"))
        #expect(failed.create(in: directory, slug: nil, head: "change", base: "main", title: "fixture", body: "") == nil)
        #expect(failed.state(of: url, in: directory) == nil)
    }
}

extension SyncTests {
    @Test func unavailableToolsAndRemoteFailures() async throws {
        let a = try makeOrigin()
        let file = a.appendingPathComponent("secrets.enc.env")
        let deletedPath = try gitWrapper("")
        let client = GitClient(path: deletedPath)!
        try FileManager.default.removeItem(atPath: deletedPath)
        #expect(client.fetch("main", in: a) == .failed)
        #expect(client.push("HEAD", to: "main", in: a) == .failed("Could not connect to origin."))
        #expect(client.workingBlobID("missing", in: a) == nil)
        let emptyGH = PullRequestClient(path: try gitWrapper("exit 0"))
        #expect(emptyGH.state(of: URL(string: "https://github.com/test/repo/pull/1")!, in: a) == nil)
        let memory = SyncMemory(defaults: defaults)
        defaults.set(Data("broken json".utf8), forKey: "vault.sync.files")
        #expect(memory.offline("absent") == nil)
        let noGit = SyncService(gitPath: "/nonexistent/git")
        #expect(try await !noGit.load(file, configuration: config).status.isGit)
        await #expect(throws: VaultError.self) { try await noGit.saveOffline(file, changes: [], displayed: VaultDocument(root: .object([:]), ciphertext: Data()), configuration: self.config) }
        try git("remote", "remove", "origin", in: a)
        #expect(try await !service().load(file, configuration: config).status.isGit)
        try git("remote", "add", "origin", origin.path, in: a)
        try "secrets.enc.env\n".write(to: a.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        // check-ignore intentionally ignores only untracked paths.
        let ignored = a.appendingPathComponent("ignored.enc.env")
        try Data(contentsOf: file).write(to: ignored)
        try "ignored.enc.env\n".write(to: a.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(try await !service().load(ignored, configuration: config).status.isGit)
        let unknown = SyncService(gitPath: try gitWrapper("case \"$1\" in symbolic-ref|ls-remote) exit 1;; rev-parse) if [ \"$2\" = --verify ]; then exit 1; fi;; esac"))
        #expect(try await !unknown.load(file, configuration: config).status.isGit)
    }

    @Test func retryExhaustionPushErrorsAndPRBranchErrors() async throws {
        let a = try makeOrigin()
        let file = a.appendingPathComponent("secrets.enc.env")
        let loaded = try await service().load(file, configuration: config)
        let edit = [change("API_TOKEN", from: "FAKE_one", to: "FAKE_new")]
        for (response, expected) in [("non-fast-forward", "changed several times"), ("permission denied", "permission"), ("protected branch", "rejected the PR branch")] {
            let path = try gitWrapper("if [ \"$1\" = push ]; then echo '\(response)' >&2; exit 1; fi")
            let sync = SyncService(memory: SyncMemory(defaults: defaults), gitPath: path, ghPath: "/missing/gh")
            do { _ = try await sync.save(file, changes: edit, displayed: loaded.document, resolution: nil, configuration: config); Issue.record("must fail") }
            catch { #expect(error.localizedDescription.contains(expected)) }
        }
        let path = try gitWrapper("if [ \"$1\" = push ]; then case \"$*\" in *refs/heads/main) echo 'protected branch';; *) echo 'permission denied';; esac; exit 1; fi")
        let sync = SyncService(memory: SyncMemory(defaults: defaults), gitPath: path, ghPath: "/missing/gh")
        await #expect(throws: VaultError.self) { try await sync.save(file, changes: edit, displayed: loaded.document, resolution: nil, configuration: self.config) }
        let pr = PullRequestRef(branch: "main", url: nil)
        SyncMemory(defaults: defaults).setPullRequest(a.path + "|secrets.enc.env", pr)
        // Keep the remembered PR alive by failing its fetch, while the base fetch succeeds.
        let marker = directory.appendingPathComponent("fetch-count")
        let rejecting = try gitWrapper("if [ \"$1\" = fetch ]; then if [ -e '\(marker.path)' ]; then rm '\(marker.path)'; exit 1; else touch '\(marker.path)'; fi; fi\nif [ \"$1\" = push ]; then echo 'protected branch'; exit 1; fi")
        let prSync = SyncService(memory: SyncMemory(defaults: defaults), gitPath: rejecting, ghPath: "/missing/gh")
        do { _ = try await prSync.save(file, changes: edit, displayed: loaded.document, resolution: nil, configuration: config); Issue.record("must reject PR") }
        catch { #expect(error.localizedDescription.contains("PR branch")) }
    }
}

extension SyncTests {
    @Test func missingBranchAndSuccessfulPushWithChangedRemoteView() async throws {
        let a = try makeOrigin()
        let file = a.appendingPathComponent("secrets.enc.env")
        let missing = try gitWrapper("if [ \"$1\" = rev-parse ] && [ \"$2\" = --verify ]; then exit 1; fi")
        let sync = SyncService(gitPath: missing, ghPath: "/missing/gh")
        await #expect(throws: VaultError.self) { try await sync.load(file, configuration: self.config) }
        let loaded = try await service().load(file, configuration: config)
        // Simulate a successful push followed by a refresh that has a different root.
        let raced = SyncService(gitPath: try gitWrapper("if [ \"$1\" = push ]; then exit 0; fi"), ghPath: "/missing/gh")
        let result = try await raced.save(file, changes: [change("API_TOKEN", from: "FAKE_one", to: "FAKE_updated")],
                                          displayed: loaded.document, resolution: nil, configuration: config)
        guard case .saved(let saved, _) = result else { Issue.record("expected saved"); return }
        #expect(saved.document.root[[.key("API_TOKEN")]] == .string("FAKE_updated"))
        #expect(try await originValue("API_TOKEN") == .string("FAKE_one"))
        let client = GitClient(path: gitPath)!
        #expect(client.fetch("absent", in: a) == .missingRef)
        let falseRoot = GitClient(path: try gitWrapper("if [ \"$1\" = rev-parse ] && [ \"$2\" = --show-toplevel ]; then echo /elsewhere; exit 0; fi"))!
        #expect(falseRoot.locate(file) == nil)
    }

    @Test func pullRequestCLIStateAndCompareFallback() async throws {
        let a = try makeOrigin()
        let file = a.appendingPathComponent("secrets.enc.env")
        let memory = SyncMemory(defaults: defaults)
        let path = try gitWrapper("if [ \"$1\" = remote ] && [ \"$2\" = get-url ]; then echo https://github.com/test/repo.git; exit 0; fi")
        let state = directory.appendingPathComponent("pr-state")
        try "OPEN".write(to: state, atomically: true, encoding: .utf8)
        let gh = try gitWrapper("cat >/dev/null; if [ \"$2\" = create ]; then echo https://github.com/test/repo/pull/1; else cat '\(state.path)'; fi; exit 0")
        let sync = SyncService(memory: memory, gitPath: path, ghPath: gh)
        await sync.setAlwaysPullRequest(for: file, true)
        let loaded = try await sync.load(file, configuration: config)
        let outcome = try await sync.save(file, changes: [change("API_TOKEN", from: "FAKE_one", to: "FAKE_pr")],
                                         displayed: loaded.document, resolution: nil, configuration: config)
        guard case .saved(let saved, _) = outcome else { Issue.record("expected PR"); return }
        #expect(saved.status.pullRequest?.url?.absoluteString == "https://github.com/test/repo/pull/1")
        #expect(try await sync.load(file, configuration: config).status.pullRequest != nil)
        try "MERGED".write(to: state, atomically: true, encoding: .utf8)
        #expect(try await sync.load(file, configuration: config).status.pullRequest == nil)
        try git("push", "-q", "origin", "--delete", saved.status.pullRequest!.branch, in: a)
        let fallback = SyncService(memory: memory, gitPath: path, ghPath: "/missing/gh")
        let fresh = try await fallback.load(file, configuration: config)
        let result = try await fallback.save(file, changes: [change("DB_URL", from: "FAKE_db", to: "FAKE_changed")],
                                            displayed: fresh.document, resolution: nil, configuration: config)
        guard case .saved(let compare, _) = result else { Issue.record("expected fallback"); return }
        #expect(compare.status.pullRequest?.url?.absoluteString.contains("/compare/main...") == true)
        // External edits replace an offline save: its bookkeeping must be discarded.
        memory.setOffline(a.path + "|secrets.enc.env", blob: "outdated", base: nil)
        _ = try await fallback.load(file, configuration: config)
        #expect(memory.offline(a.path + "|secrets.enc.env") == nil)
    }
}

extension SyncTests {
    @Test func untrackedFilesWithRemoteBaseAndNewFilePR() async throws {
        let a = try makeOrigin()
        let sync = service()
        let file = a.appendingPathComponent("new.enc.env")
        try encrypt("NEW=FAKE_new\n", name: file.lastPathComponent).write(to: file)
        let loaded = try await sync.load(file, configuration: config)
        _ = try await sync.save(file, changes: [], displayed: loaded.document, resolution: nil, configuration: config)
        try encrypt("NEW=FAKE_local\n", name: file.lastPathComponent).write(to: file)
        let local = try await sync.load(file, configuration: config)
        await #expect(throws: VaultError.self) {
            try await sync.saveOffline(file, changes: [], displayed: local.document, configuration: self.config)
        }
        #expect(local.status.localCopy == .modified)
        #expect(local.localChanges == [change("NEW", from: "FAKE_new", to: "FAKE_local")])
        let prFile = a.appendingPathComponent("pr-new.enc.env")
        try encrypt("NEW=FAKE_pr\n", name: prFile.lastPathComponent).write(to: prFile)
        await sync.setAlwaysPullRequest(for: prFile, true)
        let newPR = try await sync.load(prFile, configuration: config)
        let result = try await sync.save(prFile, changes: [], displayed: newPR.document, resolution: nil, configuration: config)
        guard case .saved(let saved, _) = result else { Issue.record("expected new file PR"); return }
        #expect(saved.status.pullRequest != nil)
    }
}
