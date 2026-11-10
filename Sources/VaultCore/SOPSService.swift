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

    public func mutate(url: URL, expectedCiphertext: Data, path: [PathPart], value: JSONValue?,
                       configuration: SOPSConfiguration) throws -> VaultDocument {
        guard !path.isEmpty, case .key(let first) = path[0], first != "sops", !first.hasPrefix("sops_") else {
            throw VaultError.message("La ruta debe empezar con una clave y no puede modificar metadata SOPS.")
        }
        let original = try readCiphertext(url)
        guard original == expectedCiphertext else { throw conflict }
        let format = FileFormat.detect(url: url, data: original)
        if format == .dotenv {
            guard path.count == 1, !first.isEmpty,
                  first.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw VaultError.message("Los archivos ENV necesitan una clave simple, por ejemplo API_TOKEN.")
            }
            if let value, case .string = value {} else if value != nil {
                throw VaultError.message("Los valores ENV deben ser texto.")
            }
        }
        let executable = try configuration.executable()
        let environment = try configuration.environment()
        let before = try decrypt(original, format: format, configuration: configuration)
        let expectedRoot = try before.root.updating(path: path, value: value)
        // Private staging directory contains ciphertext only, on the same volume for atomic replacement.
        let directory = url.deletingLastPathComponent().appendingPathComponent(".sops-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("secret.\(format == .dotenv ? "env" : format.rawValue)")
        guard FileManager.default.createFile(atPath: staged.path, contents: original, attributes: [.posixPermissions: 0o600]) else {
            throw VaultError.message("No se pudo preparar la escritura cifrada. Revisá los permisos de la carpeta.")
        }
        var args = [value == nil ? "unset" : "set", "--input-type", format.rawValue, "--output-type", format.rawValue]
        if value != nil { args.append("--value-stdin") }
        args += [staged.path, path.map(\.sops).joined()]
        let result = try ProcessRunner.run(executable: executable, arguments: args, input: value?.data ?? Data(),
                                           environment: environment, directory: url.deletingLastPathComponent())
        guard result.status == 0 else {
            throw VaultError.message("SOPS no pudo guardar el cambio. Revisá la clave, el formato y que SOPS sea 3.11 o posterior. El original sigue intacto.")
        }
        let encrypted = try readCiphertext(staged)
        // Verify MAC, decode and validate the intended change before touching the original.
        let verified = try decrypt(encrypted, format: format, configuration: configuration)
        guard expectedRoot == verified.root else {
            throw VaultError.message("La verificación del cambio falló. El archivo original sigue intacto.")
        }
        guard try readCiphertext(url) == expectedCiphertext else { throw conflict }
        // Preserve the original mode while keeping staging private. No plaintext backup.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let mode = attrs[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path) }
        guard rename(staged.path, url.path) == 0 else {
            throw VaultError.message("No se pudo reemplazar el archivo cifrado. Revisá los permisos. El original sigue intacto.")
        }
        return verified
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
