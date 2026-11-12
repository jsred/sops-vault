import Foundation

public struct SOPSConfiguration: Sendable {
    public var executablePath: String
    public var ageKeyPath: String
    var processEnvironment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    public init(executablePath: String = "", ageKeyPath: String = "~/.config/sops/age/keys.txt") {
        self.executablePath = executablePath
        self.ageKeyPath = ageKeyPath
    }
    public func executable() throws -> URL {
        let fm = FileManager.default
        let candidates: [String]
        if !executablePath.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates = [(executablePath as NSString).expandingTildeInPath]
        } else {
            candidates = ["/opt/homebrew/bin/sops", "/usr/local/bin/sops"] +
                (processEnvironment()["PATH"] ?? "").split(separator: ":").map { "\($0)/sops" }
        }
        guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw VaultError.localized("SOPS was not found. Install it with “brew install sops age” or choose its binary in Settings.")
        }
        return URL(fileURLWithPath: path)
    }
    public func environment() throws -> [String: String] {
        let path = (ageKeyPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
            throw VaultError.localized("No readable age key was found. Choose the identity file in Settings. Default path: ~/.config/sops/age/keys.txt.")
        }
        // Deliberately do not inherit SOPS_*, cloud credentials or editor configuration.
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "SOPS_AGE_KEY_FILE": path,
                   "SOPS_DECRYPTION_ORDER": "age", "LANG": "en_US.UTF-8"]
        if let home = processEnvironment()["HOME"] { env["HOME"] = home }
        env["SOPS_AGE_SSH_PRIVATE_KEY_FILE"] = "/dev/null"
        return env
    }
}

/// Serialized off the main actor. Only encrypted bytes are ever written by this service.
public actor SOPSService {
    private var createFile: @Sendable (URL, Data) -> Bool = { url, data in
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    private var renameFile: @Sendable (URL, URL) -> Int32 = { rename($0.path, $1.path) }
    public init() {}
    // Internal filesystem seam for deterministic failure tests; production uses the real operations.
    init(createFile: @escaping @Sendable (URL, Data) -> Bool,
         renameFile: @escaping @Sendable (URL, URL) -> Int32) {
        self.createFile = createFile; self.renameFile = renameFile
    }
    public func load(url: URL, configuration: SOPSConfiguration) throws -> VaultDocument {
        let bytes = try readCiphertext(url)
        return try decrypt(bytes, format: .detect(url: url, data: bytes), configuration: configuration)
    }

    public func decrypt(ciphertext: Data, format: FileFormat, configuration: SOPSConfiguration) throws -> VaultDocument {
        try decrypt(ciphertext, format: format, configuration: configuration)
    }

    /// Edits the file in place: applies the changes and atomically replaces it if it still matches `expectedCiphertext`.
    public func mutate(url: URL, expectedCiphertext: Data, changes: [SecretChange],
                       configuration: SOPSConfiguration) throws -> VaultDocument {
        let original = try readCiphertext(url)
        guard original == expectedCiphertext else { throw conflict }
        let updated = try apply(changes, to: original, format: .detect(url: url, data: original),
                                near: url.deletingLastPathComponent(), configuration: configuration)
        try replace(url, expected: expectedCiphertext, with: updated.ciphertext)
        return updated
    }

    public func mutate(url: URL, expectedCiphertext: Data, path: [PathPart], value: JSONValue?,
                       configuration: SOPSConfiguration) throws -> VaultDocument {
        try mutate(url: url, expectedCiphertext: expectedCiphertext,
                   changes: [SecretChange(path: path, original: nil, value: value)], configuration: configuration)
    }

    /// Applies the changes to `ciphertext` with `sops set`/`unset` and returns the verified result.
    /// Changes already satisfied by `ciphertext` are skipped. Only ciphertext is written, in a private
    /// 0700 staging directory inside `directory`, which is removed before returning.
    public func apply(_ changes: [SecretChange], to ciphertext: Data, format: FileFormat, near directory: URL,
                      configuration: SOPSConfiguration) throws -> VaultDocument {
        let before = try decrypt(ciphertext, format: format, configuration: configuration)
        let effective = changes.filter { before.root[$0.path] != $0.value }
        guard !effective.isEmpty else { return before }
        for change in effective { try validate(change, format: format) }
        let expectedRoot = try Merge.applying(effective, to: before.root)
        let executable = try configuration.executable()
        let environment = try configuration.environment()
        let staging = directory.appendingPathComponent(".sops-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("secret.\(format == .dotenv ? "env" : format.rawValue)")
        guard createFile(staged, ciphertext) else {
            throw VaultError.localized("The encrypted write could not be prepared. Check the folder's permissions.")
        }
        for change in effective {
            var args = [change.value == nil ? "unset" : "set", "--input-type", format.rawValue, "--output-type", format.rawValue]
            if change.value != nil { args.append("--value-stdin") }
            args += [staged.path, change.path.map(\.sops).joined()]
            let result = try ProcessRunner.run(executable: executable, arguments: args, input: change.value?.data ?? Data(),
                                               environment: environment, directory: directory)
            guard result.status == 0 else {
                throw VaultError.localized("SOPS could not apply the change to “\(change.name)”. Check the key, the format and that SOPS is 3.11 or later. Nothing was saved.")
            }
        }
        let encrypted = try readCiphertext(staged)
        // Verify MAC, decode and validate the intended result before anything uses it.
        let verified = try decrypt(encrypted, format: format, configuration: configuration)
        guard expectedRoot == verified.root else {
            throw VaultError.localized("Verifying the change failed. Nothing was saved.")
        }
        return verified
    }

    /// Atomically replaces `url` with ciphertext, preserving its mode. `expected` nil skips the outside-change check.
    public func replace(_ url: URL, expected: Data?, with ciphertext: Data) throws {
        let directory = url.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".sops-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(url.lastPathComponent)
        guard createFile(staged, ciphertext) else {
            throw VaultError.localized("The encrypted write could not be prepared. Check the folder's permissions.")
        }
        if let expected { guard try readCiphertext(url) == expected else { throw conflict } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let mode = attrs[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path) }
        guard renameFile(staged, url) == 0 else {
            throw VaultError.localized("The encrypted file could not be replaced. Check the permissions. The original is intact.")
        }
    }

    public func ciphertext(of url: URL) throws -> Data { try readCiphertext(url) }

    private func validate(_ change: SecretChange, format: FileFormat) throws {
        let path = change.path
        guard !path.isEmpty, case .key(let first) = path[0], first != "sops", !first.hasPrefix("sops_") else {
            throw VaultError.localized("The path must start with a key and cannot change SOPS metadata.")
        }
        guard format == .dotenv else { return }
        guard path.count == 1, !first.isEmpty,
              first.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw VaultError.localized("ENV files need a simple key, for example API_TOKEN.")
        }
        if let value = change.value, case .string = value {} else if change.value != nil {
            throw VaultError.localized("ENV values must be text.")
        }
    }

    private var conflict: VaultError {
        .localized("The file changed outside SOPS Vault. Reload it before editing so those changes are not overwritten.")
    }
    private func decrypt(_ data: Data, format: FileFormat, configuration: SOPSConfiguration) throws -> VaultDocument {
        let executable = try configuration.executable()
        let environment = try configuration.environment()
        let result = try ProcessRunner.run(executable: executable,
            arguments: ["decrypt", "--input-type", format.rawValue, "--output-type", "json", "/dev/stdin"],
            input: data, environment: environment)
        guard result.status == 0 else {
            throw VaultError.localized("Could not decrypt. The age identity must match one of the file's recipients and the MAC must be valid. Check Settings; the file was not changed.")
        }
        do {
            let root = try JSONDecoder().decode(JSONValue.self, from: result.output)
            guard case .object = root else {
                throw VaultError.localized("The document must have keys at the root. YAML files with several documents are not supported.")
            }
            return VaultDocument(root: root, ciphertext: data)
        } catch let error as VaultError { throw error }
        catch { throw VaultError.localized("The document could not be read. ENV, JSON and single-document YAML with keys at the root are supported.") }
    }
    private func readCiphertext(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else {
            throw VaultError.localized("Choose a regular file. For safety, symbolic links are not edited.")
        }
        guard let size = info.fileSize, size <= 8 * 1024 * 1024 else {
            throw VaultError.localized("The file is larger than the 8 MB limit.")
        }
        return try Data(contentsOf: url)
    }
}
