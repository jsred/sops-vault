import Foundation
import Testing
@testable import VaultCore

/// All identities and fixtures are generated under a fresh private temp directory.
/// Never uses the user's real identity, repos or secret files.
@Suite(.serialized, .timeLimit(.minutes(1))) final class IntegrationTests {
    private var directory: URL!
    private var config: SOPSConfiguration!
    private var recipient = ""
    private var sops: URL!

    init() throws {
        let fm = FileManager.default
        let created = fm.temporaryDirectory.appendingPathComponent("sops-vault-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = Discovery.canonical(created)
        sops = try SOPSConfiguration().executable()
        let agePath = ["/opt/homebrew/bin/age-keygen", "/usr/local/bin/age-keygen"].first { fm.isExecutableFile(atPath: $0) }
        guard let agePath else { throw VaultError.message("Install age to run real SOPS integration tests") }
        let key = directory.appendingPathComponent("test.agekey")
        let env = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": directory.path]
        let generated = try ProcessRunner.run(executable: URL(fileURLWithPath: agePath), arguments: ["-o", key.path], environment: env)
        #expect(generated.status == 0)
        let publicKey = try ProcessRunner.run(executable: URL(fileURLWithPath: agePath), arguments: ["-y", key.path], environment: env)
        recipient = String(decoding: publicKey.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(recipient.hasPrefix("age1"))
        config = SOPSConfiguration(executablePath: sops.path, ageKeyPath: key.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    }
    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func fixture(_ format: FileFormat, plaintext: String, filename: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(filename ?? "fixture.enc.\(format == .dotenv ? "env" : format.rawValue)")
        let encrypted = try ProcessRunner.run(executable: sops,
            arguments: ["encrypt", "--age", recipient, "--input-type", format.rawValue,
                        "--output-type", format.rawValue, "--filename-override", url.path],
            input: Data(plaintext.utf8), environment: try config.environment(), directory: directory)
        guard encrypted.status == 0 else { throw VaultError.message("Test fixture encryption failed") }
        try encrypted.output.write(to: url)
        return url
    }

    @Test func testJSONCRUDWithNestedTypedValuesAndNoPlaintextArtifacts() async throws {
        let url = try fixture(.json, plaintext: #"{"API_TOKEN":"FAKE_original_729","nested":{"enabled":true,"ports":[3000,4000]},"a.b":"literal"}"#)
        let service = SOPSService()
        var doc = try await service.load(url: url, configuration: config)
        #expect(doc.root[[.key("API_TOKEN")]] == .string("FAKE_original_729"))
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("API_TOKEN")], value: .string("FAKE_replacement_829"), configuration: config)
        #expect(doc.root[[.key("API_TOKEN")]] == .string("FAKE_replacement_829"))
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("NEW_TOKEN")], value: .string("FAKE_new_929"), configuration: config)
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("nested"), .key("enabled")], value: .bool(false), configuration: config)
        #expect(doc.root[[.key("nested"), .key("enabled")]] == .bool(false))
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("nested"), .key("ports"), .index(0)], value: nil, configuration: config)
        #expect(doc.root[[.key("nested"), .key("ports")]] == .array([.number(4000)]))
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("NEW_TOKEN")], value: nil, configuration: config)
        #expect(doc.root[[.key("NEW_TOKEN")]] == nil)
        #expect(doc.root[[.key("a.b")]] == .string("literal"))
        try assertNoPlaintextOrStaging(["FAKE_original_729", "FAKE_replacement_829", "FAKE_new_929"])
    }

    @Test func testDotenvCRUDAndMultilineText() async throws {
        let url = try fixture(.dotenv, plaintext: "API_TOKEN=FAKE_env_729\nEMPTY=\n")
        let service = SOPSService()
        var doc = try await service.load(url: url, configuration: config)
        #expect(doc.root[[.key("API_TOKEN")]] == .string("FAKE_env_729"))
        let value = "FAKE_env_changed\nsecond line=with\"quotes"
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("API_TOKEN")], value: .string(value), configuration: config)
        #expect(doc.root[[.key("API_TOKEN")]] == .string(value))
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("ADDED")], value: .string("FAKE_added"), configuration: config)
        doc = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("ADDED")], value: nil, configuration: config)
        #expect(doc.root[[.key("ADDED")]] == nil)
        #expect(doc.root[[.key("EMPTY")]] == .string(""))
        try assertNoPlaintextOrStaging(["FAKE_env_729", "FAKE_env_changed", "FAKE_added"])
    }

    @Test func testYAMLRetainsRecipientAndCommentsWithCreationRules() async throws {
        let rules = "creation_rules:\n  - path_regex: '.*enc.yaml$'\n    age: '\(recipient)'\n"
        try Data(rules.utf8).write(to: directory.appendingPathComponent(".sops.yaml"))
        let url = directory.appendingPathComponent("test.enc.yaml")
        let result = try ProcessRunner.run(executable: sops,
            arguments: ["encrypt", "--filename-override", url.path, "--input-type", "yaml", "--output-type", "yaml"],
            input: Data("# Keep this comment\ndatabase:\n  password: FAKE_yaml_729\n  port: 5432\n".utf8),
            environment: try config.environment(), directory: directory)
        #expect(result.status == 0)
        try result.output.write(to: url)
        let service = SOPSService()
        let doc = try await service.load(url: url, configuration: config)
        let changed = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
            path: [.key("database"), .key("password")], value: .string("FAKE_yaml_changed"), configuration: config)
        #expect(changed.root[[.key("database"), .key("port")]] == .number(5432))
        let encrypted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(encrypted.contains(recipient))
        // SOPS encrypts comments too; they must not leak, but must survive a YAML round trip.
        #expect(!encrypted.contains("Keep this comment"))
        let roundTrip = try ProcessRunner.run(executable: sops,
            arguments: ["decrypt", "--input-type", "yaml", "--output-type", "yaml", url.path],
            environment: try config.environment(), directory: directory)
        #expect(String(decoding: roundTrip.output, as: UTF8.self).contains("# Keep this comment"))
        try assertNoPlaintextOrStaging(["FAKE_yaml_729", "FAKE_yaml_changed"])
    }

    @Test func testConflictLeavesExternalChangeUntouched() async throws {
        let url = try fixture(.json, plaintext: #"{"KEY":"FAKE_first"}"#)
        let service = SOPSService()
        let initial = try await service.load(url: url, configuration: config)
        let external = try fixture(.json, plaintext: #"{"KEY":"FAKE_external"}"#, filename: "external.enc.json")
        let externalBytes = try Data(contentsOf: external)
        try externalBytes.write(to: url)
        do {
            _ = try await service.mutate(url: url, expectedCiphertext: initial.ciphertext,
                path: [.key("KEY")], value: .string("FAKE_ours"), configuration: config)
            Issue.record("Must reject stale document")
        } catch { #expect(error.localizedDescription.contains("changed outside")) }
        #expect(try Data(contentsOf: url) == externalBytes)
    }

    @Test func testInvalidKeyAndCorruptedFileNeverModifyCiphertext() async throws {
        let url = try fixture(.json, plaintext: #"{"KEY":"FAKE_safe"}"#)
        let service = SOPSService()
        let original = try Data(contentsOf: url)
        let missing = SOPSConfiguration(executablePath: sops.path, ageKeyPath: directory.appendingPathComponent("missing.agekey").path)
        do { _ = try await service.load(url: url, configuration: missing); Issue.record("Missing identity must fail") } catch {}
        #expect(try Data(contentsOf: url) == original)
        var corrupted = String(decoding: original, as: UTF8.self)
        corrupted = corrupted.replacingOccurrences(of: "AES256_GCM", with: "BROKEN_GCM")
        try Data(corrupted.utf8).write(to: url)
        do { _ = try await service.load(url: url, configuration: config); Issue.record("Corruption must fail") } catch {}
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == corrupted)
    }

    @Test func testMetadataAndProjectDiscoveryAndSymlinkExclusion() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: false)
        let env = try fixture(.dotenv, plaintext: "FAKE_KEY=fake\n")
        let yaml = try fixture(.yaml, plaintext: "FAKE_KEY: fake\n", filename: "settings.yaml")
        let json = try fixture(.json, plaintext: #"{"FAKE_KEY":"fake"}"#, filename: "settings.json")
        let node = directory.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: false)
        try Data(contentsOf: env).write(to: node.appendingPathComponent("ignored.enc.env"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.enc.env"), withDestinationURL: env)
        let result = Discovery.scan([directory, env])
        #expect(Set(result.files.map(\.url.path)) == Set([env, yaml, json].map(\.path)))
        #expect(result.files.allSatisfy { $0.projectURL.path == directory.path })
    }

    @Test func testBookmarkRoundTripAndMissingReference() throws {
        let url = try fixture(.json, plaintext: #"{"KEY":"fake"}"#)
        let suite = "test.sops-vault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookmarkStore(defaults: defaults)
        try store.save([url])
        let restored = store.restore()
        #expect(restored.urls.map { $0.resolvingSymlinksInPath().path } == [url.resolvingSymlinksInPath().path])
        #expect(restored.unavailable == 0)
        let data = defaults.array(forKey: "vault.references") as! [Data]
        #expect(!(data.contains { String(decoding: $0, as: UTF8.self).contains("FAKE") }))
    }

    @Test func testMetadataCannotBeEditedAndFailureCleansStaging() async throws {
        let url = try fixture(.json, plaintext: #"{"KEY":"FAKE_safe"}"#)
        let service = SOPSService()
        let doc = try await service.load(url: url, configuration: config)
        do {
            _ = try await service.mutate(url: url, expectedCiphertext: doc.ciphertext,
                path: [.key("sops")], value: .string("FAKE_invalid"), configuration: config)
            Issue.record("Must protect metadata")
        } catch {}
        #expect(try Data(contentsOf: url) == doc.ciphertext)
        try assertNoPlaintextOrStaging(["FAKE_safe", "FAKE_invalid"])
    }

    @Test func testProcessTimeoutAndLargePipes() throws {
        let env = ["PATH": "/usr/bin:/bin"]
        let payload = Data(repeating: 97, count: 256 * 1024)
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: payload, environment: env)
        #expect(result.output == payload)
        #expect(throws: (any Error).self) { try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: env, timeout: 0.1) }
    }

    private func assertNoPlaintextOrStaging(_ tokens: [String]) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!(files.contains { $0.lastPathComponent.hasPrefix(".sops-vault-") }))
        for file in files where file.lastPathComponent != "test.agekey" {
            guard let bytes = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            for token in tokens { #expect(!(text.contains(token)), "Plaintext found in test artifact") }
        }
    }
}

extension IntegrationTests {
    @Test func invalidENVPathsTypesAndInputFiles() async throws {
        let url = try fixture(.dotenv, plaintext: "KEY=FAKE_safe\n")
        let service = SOPSService()
        let doc = try await service.load(url: url, configuration: config)
        for (path, value) in [([PathPart.key("bad-key")], JSONValue.string("fake")), ([.key("KEY")], .number(1))] {
            await #expect(throws: VaultError.self) {
                try await service.mutate(url: url, expectedCiphertext: doc.ciphertext, path: path, value: value, configuration: self.config)
            }
        }
        await #expect(throws: VaultError.self) { try await service.ciphertext(of: self.directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: VaultError.self) { try await service.ciphertext(of: link) }
        let large = directory.appendingPathComponent("large")
        try Data(repeating: 0, count: 8 * 1024 * 1024 + 1).write(to: large)
        await #expect(throws: VaultError.self) { try await service.ciphertext(of: large) }
        #expect(try Data(contentsOf: url) == doc.ciphertext)
    }

    private func fakeSOPS(_ body: String) throws -> SOPSConfiguration {
        let url = directory.appendingPathComponent("fake-sops-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return SOPSConfiguration(executablePath: url.path, ageKeyPath: config.ageKeyPath)
    }

    @Test func rejectsInvalidDecryptedOutputAndFailedOrUnverifiedEdits() async throws {
        let service = SOPSService()
        for output in ["[]", "invalid-json"] {
            let fake = try fakeSOPS("cat >/dev/null; printf '%s' '\(output)'\n")
            await #expect(throws: VaultError.self) { try await service.decrypt(ciphertext: Data(), format: .json, configuration: fake) }
        }
        let change = SecretChange(path: [.key("KEY")], original: .string("old"), value: .string("new"))
        for status in [0, 1] {
            let fake = try fakeSOPS("cat >/dev/null; if [ \"$1\" = decrypt ]; then printf '%s' '{\"KEY\":\"old\"}'; else exit \(status); fi\n")
            await #expect(throws: VaultError.self) {
                try await service.apply([change], to: Data("ciphertext".utf8), format: .json, near: self.directory, configuration: fake)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".sops-vault-") })
        }
    }

    @Test func filesystemFailuresPreserveOriginalAndCleanStaging() async throws {
        let url = try fixture(.json, plaintext: #"{"KEY":"FAKE_safe"}"#)
        let original = try Data(contentsOf: url)
        let failingCreate = SOPSService(createFile: { _, _ in false }, renameFile: { _, _ in -1 })
        await #expect(throws: VaultError.self) { try await failingCreate.replace(url, expected: original, with: Data()) }
        await #expect(throws: VaultError.self) {
            try await failingCreate.apply([SecretChange(path: [.key("KEY")], original: .string("FAKE_safe"), value: .string("changed"))],
                                          to: original, format: .json, near: self.directory, configuration: self.config)
        }
        let failingRename = SOPSService(createFile: { url, data in
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }, renameFile: { _, _ in -1 })
        await #expect(throws: VaultError.self) { try await failingRename.replace(url, expected: original, with: Data()) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".sops-vault-") })
    }
}

extension IntegrationTests {
    @Test func replacementRejectsConcurrentChange() async throws {
        let url = try fixture(.json, plaintext: #"{"KEY":"fake"}"#)
        let original = try Data(contentsOf: url)
        await #expect(throws: VaultError.self) {
            try await SOPSService().replace(url, expected: Data("stale".utf8), with: Data())
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
