import Foundation
import Testing
@testable import VaultCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct CoverageTests {
    @Test func valuePresentationPathsAndErrors() throws {
        let values: [JSONValue] = [.object([:]), .array([]), .string("example"), .number(2), .bool(true), .null]
        #expect(values.map(\.typeName) == ["Object", "List", "Text", "Number", "Boolean", "Null"])
        #expect(values[2].display == "example")
        #expect(values[3].display == "2")
        #expect(try values[0].updating(path: [], value: .bool(true)) == .bool(true))
        #expect(throws: VaultError.self) { try values[0].updating(path: [], value: nil) }
        #expect(throws: VaultError.self) { try values[0].updating(path: [.key("absent"), .key("child")], value: .null) }
        #expect(throws: VaultError.self) { try values[3].updating(path: [.index(0)], value: .null) }
        let entry = SecretEntry(path: [.key("list"), .index(1)], value: .null)
        #expect(entry.id == "[\"list\"][1]")
        #expect([PathPart.key("a")].isPrefix(of: [.key("a"), .key("b")]))
        #expect(![PathPart.key("a")].isPrefix(of: []))
        #expect(![PathPart.key("a")].isPrefix(of: [.key("b")]))
        #expect(Merge.diff(from: .null, to: .array([])).isEmpty)
        #expect(VaultError.message("message").localizedDescription == "message")
        for (text, format) in [("  {}", FileFormat.json), ("sops_age__list=1", .dotenv), ("key: value", .yaml)] {
            #expect(FileFormat.detect(url: URL(fileURLWithPath: "/test.unknown"), data: Data(text.utf8)) == format)
        }
    }

    @Test func discoveryReferencesAndBookmarks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fake.enc.env")
        try Data().write(to: file)
        let vault = VaultFile(url: file, projectURL: dir)
        #expect(vault.id == file.path)
        #expect(vault.projectName == dir.lastPathComponent)
        #expect(vault.relativePath == "fake.enc.env")
        #expect(VaultFile(url: file, projectURL: URL(fileURLWithPath: "/elsewhere")).relativePath == file.lastPathComponent)
        #expect(Discovery.projectRoot(for: file, fallback: dir) == dir)
        #expect(!Discovery.scan([dir.appendingPathComponent("missing")]).warnings.isEmpty)
        let unreadable = dir.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        #expect(!Discovery.scan([dir]).warnings.isEmpty)
        let suite = "coverage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([Data("invalid bookmark".utf8)], forKey: "vault.references")
        #expect(BookmarkStore(defaults: defaults).restore().unavailable == 1)
        #expect(!SyncStatus(storage: .local("test")).isGit)
        #expect(SyncStatus(storage: .git(branch: "main")).isGit)
    }

    @Test func processLaunchFailureAndForcedTermination() throws {
        for tool in ["SOPS", "git"] {
            #expect(throws: VaultError.self) {
                try ProcessRunner.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [], environment: [:], tool: tool)
            }
        }
        #expect(throws: VaultError.self) {
            try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while :; do :; done"],
                                  environment: [:], timeout: 0.2, tool: "git")
        }
    }

    @Test func remoteURLParsing() {
        for remote in ["https://github.com/owner/repo.git", "ssh://git@github.com:22/owner/repo.git", "git@github.com:owner/repo.git"] {
            #expect(GitClient.webRepository(remote: remote)?.slug == "owner/repo")
            #expect(GitClient.webRepository(remote: remote)?.web.absoluteString == "https://github.com/owner/repo")
        }
        for remote in ["/local/repo", "https://github.com", "https://user@github.com", "git@:owner/repo", "https://github.com/too/many/parts"] {
            #expect(GitClient.webRepository(remote: remote) == nil)
        }
    }
}

extension CoverageTests {
    @Test func remainingValueAndBookmarkEdges() throws {
        let array = JSONValue.array([.object(["key": .number(1)])])
        #expect(array[[.index(5)]] == nil)
        #expect(try array.updating(path: [.index(0), .key("key")], value: .number(2)) == .array([.object(["key": .number(2)])]))
        #expect(VaultDocument(root: .null, ciphertext: Data()).entries.isEmpty)
        let suite = "empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BookmarkStore(defaults: defaults).restore().urls.isEmpty)
        #expect(GitClient() != nil)
        #expect(GitClient(path: "/nonexistent/git") == nil)
        #expect(GitClient.environment(extra: ["PATH": "/test"])["PATH"] == "/test")
        _ = PullRequestClient()
    }

    @Test func pipeDrainRetriesInterruptedReadsAndStopsOnError() {
        let pipe = Pipe()
        // finish runs on the drain's serial queue; no events fire on this empty pipe.
        var calls = 0
        let drain = PipeDrain(pipe.fileHandleForReading, readBytes: { _, _, _ in
            calls += 1
            errno = calls == 1 ? EINTR : EIO
            return -1
        })
        #expect(drain.finish().isEmpty)
        #expect(calls == 2)
        #expect(drain.finish().isEmpty)
    }

    @Test func discoveryLimitAndInvalidCandidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0...30000 { FileManager.default.createFile(atPath: dir.appendingPathComponent("\(i).txt").path, contents: Data()) }
        #expect(Discovery.scan([dir]).warnings.contains { $0.contains("30,000") })
        let invalid = dir.appendingPathComponent("bad.json")
        try Data([0xff]).write(to: invalid)
        #expect(!Discovery.isCandidate(invalid))
        let missing = dir.appendingPathComponent("missing")
        #expect(Discovery.canonical(missing) == missing.standardizedFileURL)
    }
}

extension CoverageTests {
    @Test func absentEnvironmentAndEncodingFailure() throws {
        #expect(GitClient.environment(base: [:])["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        var config = SOPSConfiguration()
        config.processEnvironment = { [:] }
        #expect(try config.executable().lastPathComponent == "sops")
        #expect(JSONValue.null.encoded(using: { _ in throw VaultError.message("encoder failure") }).isEmpty)
    }
}
