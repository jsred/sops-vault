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
