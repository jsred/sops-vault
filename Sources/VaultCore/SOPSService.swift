import Foundation

public struct SOPSConfiguration: Sendable {
    public var executablePath: String
    public var ageKeyPath: String
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
                (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/sops" }
        }
        guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw VaultError.message("No se encontró SOPS. Instalalo con «brew install sops age» o elegí su binario en Ajustes.")
        }
        return URL(fileURLWithPath: path)
    }
    public func environment() throws -> [String: String] {
        let path = (ageKeyPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
            throw VaultError.message("No se encontró una clave age legible. Elegí el archivo de identidad en Ajustes. Ruta predeterminada: ~/.config/sops/age/keys.txt.")
        }
        // Deliberately do not inherit SOPS_*, cloud credentials or editor configuration.
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "SOPS_AGE_KEY_FILE": path,
                   "SOPS_DECRYPTION_ORDER": "age", "LANG": "en_US.UTF-8"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        env["SOPS_AGE_SSH_PRIVATE_KEY_FILE"] = "/dev/null"
        return env
    }
}

/// Serialized off the main actor. Only encrypted bytes are ever written by this service.
public actor SOPSService {
    public init() {}
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
        guard FileManager.default.createFile(atPath: staged.path, contents: ciphertext, attributes: [.posixPermissions: 0o600]) else {
            throw VaultError.message("No se pudo preparar la escritura cifrada. Revisá los permisos de la carpeta.")
        }
        for change in effective {
            var args = [change.value == nil ? "unset" : "set", "--input-type", format.rawValue, "--output-type", format.rawValue]
            if change.value != nil { args.append("--value-stdin") }
            args += [staged.path, change.path.map(\.sops).joined()]
            let result = try ProcessRunner.run(executable: executable, arguments: args, input: change.value?.data ?? Data(),
                                               environment: environment, directory: directory)
            guard result.status == 0 else {
                throw VaultError.message("SOPS no pudo aplicar el cambio en «\(change.name)». Revisá la clave, el formato y que SOPS sea 3.11 o posterior. Nada se guardó.")
            }
        }
        let encrypted = try readCiphertext(staged)
        // Verify MAC, decode and validate the intended result before anything uses it.
        let verified = try decrypt(encrypted, format: format, configuration: configuration)
        guard expectedRoot == verified.root else {
            throw VaultError.message("La verificación del cambio falló. Nada se guardó.")
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
        guard FileManager.default.createFile(atPath: staged.path, contents: ciphertext, attributes: [.posixPermissions: 0o600]) else {
            throw VaultError.message("No se pudo preparar la escritura cifrada. Revisá los permisos de la carpeta.")
        }
        if let expected { guard try readCiphertext(url) == expected else { throw conflict } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let mode = attrs[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path) }
        guard rename(staged.path, url.path) == 0 else {
            throw VaultError.message("No se pudo reemplazar el archivo cifrado. Revisá los permisos. El original sigue intacto.")
        }
    }

    public func ciphertext(of url: URL) throws -> Data { try readCiphertext(url) }

    private func validate(_ change: SecretChange, format: FileFormat) throws {
        let path = change.path
        guard !path.isEmpty, case .key(let first) = path[0], first != "sops", !first.hasPrefix("sops_") else {
            throw VaultError.message("La ruta debe empezar con una clave y no puede modificar metadata SOPS.")
        }
        guard format == .dotenv else { return }
        guard path.count == 1, !first.isEmpty,
              first.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw VaultError.message("Los archivos ENV necesitan una clave simple, por ejemplo API_TOKEN.")
        }
        if let value = change.value, case .string = value {} else if change.value != nil {
            throw VaultError.message("Los valores ENV deben ser texto.")
        }
    }

    private var conflict: VaultError {
        .message("El archivo cambió fuera de SOPS Vault. Recargalo antes de editar para no sobrescribir esos cambios.")
    }
    private func decrypt(_ data: Data, format: FileFormat, configuration: SOPSConfiguration) throws -> VaultDocument {
        let executable = try configuration.executable()
        let environment = try configuration.environment()
        let result = try ProcessRunner.run(executable: executable,
            arguments: ["decrypt", "--input-type", format.rawValue, "--output-type", "json", "/dev/stdin"],
            input: data, environment: environment)
        guard result.status == 0 else {
            throw VaultError.message("No se pudo descifrar. La identidad age debe corresponder a un destinatario del archivo y la firma MAC debe ser válida. Revisá Ajustes; el archivo no se modificó.")
        }
        do {
            let root = try JSONDecoder().decode(JSONValue.self, from: result.output)
            guard case .object = root else {
                throw VaultError.message("El documento debe tener claves en la raíz. Los YAML con varios documentos no se admiten.")
            }
            return VaultDocument(root: root, ciphertext: data)
        } catch let error as VaultError { throw error }
        catch { throw VaultError.message("No se pudo interpretar el documento. Se admiten ENV, JSON y YAML de un solo documento con claves en la raíz.") }
    }
    private func readCiphertext(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else {
            throw VaultError.message("Elegí un archivo regular. Por seguridad no se editan enlaces simbólicos.")
        }
        guard (info.fileSize ?? 0) <= 8 * 1024 * 1024 else {
            throw VaultError.message("El archivo supera el límite de 8 MB.")
        }
        return try Data(contentsOf: url)
    }
}
