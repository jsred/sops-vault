import Foundation

public struct VaultFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let projectURL: URL
    public var id: String { url.path }
    public var projectName: String { projectURL.lastPathComponent }
    public var relativePath: String {
        let prefix = projectURL.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }
    public init(url: URL, projectURL: URL) { self.url = url; self.projectURL = projectURL }
}

public struct DiscoveryResult: Sendable {
    public let files: [VaultFile]
    public let warnings: [String]
}

public enum Discovery {
    private static let ignored: Set<String> = [".git", ".build", "node_modules", "vendor", ".swiftpm", ".sops-vault", "dist", "Library", ".Trash"]

    public static func scan(_ roots: [URL]) -> DiscoveryResult {
        let fm = FileManager.default
        var found: [String: VaultFile] = [:]
        var warnings: [String] = []
        for root in roots {
            guard let info = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), info.isSymbolicLink != true else {
                warnings.append("Una referencia ya no está disponible. Volvé a agregarla."); continue
            }
            // The root itself is not a symlink; resolve parent links (/var → /private/var) so
            // files reached through different references deduplicate to one canonical path.
            let root = canonical(root)
            let fallback = info.isDirectory == true ? root : root.deletingLastPathComponent()
            func add(_ url: URL) {
                guard isCandidate(url) else { return }
                let url = canonical(url)
                let project = projectRoot(for: url, fallback: fallback)
                found[url.path] = VaultFile(url: url, projectURL: project)
            }
            if info.isDirectory == true {
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [], errorHandler: { _, _ in
                        warnings.append("No se pudo leer parte de una carpeta. Revisá sus permisos."); return true
                    }) else { continue }
                var count = 0
                for case let url as URL in enumerator {
                    count += 1
                    if count > 30_000 { warnings.append("La búsqueda llegó a 30.000 entradas. Agregá una carpeta más específica."); break }
                    let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if info?.isSymbolicLink == true || ignored.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".sops-vault-") {
                        enumerator.skipDescendants(); continue
                    }
                    if info?.isDirectory != true { add(url) }
                }
            } else { add(root) }
        }
        return DiscoveryResult(files: found.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
                               warnings: Array(Set(warnings)).sorted())
    }

    public static func isCandidate(_ url: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 8 * 1024 * 1024 else { return false }
        let name = url.lastPathComponent.lowercased()
        if [".enc.env", ".enc.yaml", ".enc.yml", ".enc.json"].contains(where: name.hasSuffix) { return true }
        // Restrict content sniffing to text-like files; never read binary assets or age identities.
        guard ["yaml", "yml", "json", "env", "sops", "enc"].contains(url.pathExtension.lowercased()) || name.hasPrefix(".env") else { return false }
        guard let bytes = try? Data(contentsOf: url), let text = String(data: bytes, encoding: .utf8) else { return false }
        return text.range(of: #"(?m)^\s*(?:"sops"\s*:|sops\s*:|sops_(?:age|mac|version)[A-Za-z0-9_]*\s*=)"#, options: .regularExpression) != nil
    }

    /// realpath(3): unlike `resolvingSymlinksInPath`, keeps the same form FileManager's enumerator returns.
    public static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
    }

    public static func projectRoot(for file: URL, fallback: URL) -> URL {
        var current = file.deletingLastPathComponent()
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current.deleteLastPathComponent()
        }
        return fallback
    }
}
