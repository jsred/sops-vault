import Foundation

public enum FetchResult: Sendable, Equatable { case ok, missingRef, failed }
public enum PushResult: Sendable, Equatable { case pushed, outdated, rejected, failed(String) }

/// Thin wrapper over the git CLI. It only ever handles ciphertext and never touches the working tree,
/// the index or the checked-out branch: commits are built with plumbing on a temporary index.
public struct GitClient: Sendable {
    public let executable: URL

    public init?(path: String? = nil) {
        let candidates = path.map { [$0] } ?? ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        executable = URL(fileURLWithPath: found)
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") || key.hasPrefix("SOPS_") { env[key] = nil }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" + (env["PATH"].map { ":" + $0 } ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
        return env.merging(extra) { $1 }
    }

    @discardableResult
    func run(_ arguments: [String], in directory: URL, input: Data = Data(), extra: [String: String] = [:],
             timeout: TimeInterval = 30) throws -> ProcessResult {
        try ProcessRunner.run(executable: executable, arguments: arguments, input: input,
                              environment: Self.environment(extra: extra), directory: directory,
                              timeout: timeout, captureErrors: true, tool: "git")
    }

    func text(_ arguments: [String], in directory: URL, input: Data = Data(), extra: [String: String] = [:]) -> String? {
        guard let result = try? run(arguments, in: directory, input: input, extra: extra), result.status == 0 else { return nil }
        let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Repository root and the file's path relative to it, or nil outside a work tree.
    public func locate(_ file: URL) -> (root: URL, path: String)? {
        let directory = file.deletingLastPathComponent()
        guard let top = text(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let root = Discovery.canonical(URL(fileURLWithPath: top, isDirectory: true))
        let canonicalFile = Discovery.canonical(file).path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard canonicalFile.hasPrefix(prefix) else { return nil }
        return (root, String(canonicalFile.dropFirst(prefix.count)))
    }

    public func isIgnored(_ path: String, in root: URL) -> Bool {
        (try? run(["check-ignore", "-q", "--", path], in: root))?.status == 0
    }

    public func remoteURL(in root: URL) -> String? { text(["remote", "get-url", "origin"], in: root) }

    public func defaultBranch(in root: URL) -> String? {
        if let ref = text(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root), ref.hasPrefix("origin/") {
            return String(ref.dropFirst("origin/".count))
        }
        if let listing = text(["ls-remote", "--symref", "origin", "HEAD"], in: root),
           let line = listing.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") }),
           let ref = line.split(separator: "\t").first {
            return String(ref.dropFirst("ref: refs/heads/".count))
        }
        for candidate in ["main", "master"] where text(["rev-parse", "--verify", "--quiet", Self.remoteRef(candidate)], in: root) != nil {
            return candidate
        }
        return nil
    }

    public static func remoteRef(_ branch: String) -> String { "refs/remotes/origin/\(branch)" }

    public func fetch(_ branch: String, in root: URL) -> FetchResult {
        guard let result = try? run(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin",
                                     "+refs/heads/\(branch):\(Self.remoteRef(branch))"], in: root, timeout: 25) else { return .failed }
        if result.status == 0 { return .ok }
        return result.combinedText.lowercased().contains("couldn't find remote ref") ? .missingRef : .failed
    }

    public func hasRef(_ ref: String, in root: URL) -> Bool {
        text(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root) != nil
    }

    /// Object id of `path` at `ref`, or nil when the file is not there.
    public func blobID(_ ref: String, _ path: String, in root: URL) -> String? {
        text(["rev-parse", "--verify", "--quiet", "\(ref):\(path)"], in: root)
    }

    public func blob(_ ref: String, _ path: String, in root: URL) -> Data? {
        guard blobID(ref, path, in: root) != nil,
              let result = try? run(["cat-file", "blob", "\(ref):\(path)"], in: root), result.status == 0 else { return nil }
        return result.output
    }

    public func blob(id: String, in root: URL) -> Data? {
        guard let result = try? run(["cat-file", "blob", id], in: root), result.status == 0 else { return nil }
        return result.output
    }

    /// Object id the working copy of `path` would have, without writing it.
    public func workingBlobID(_ path: String, in root: URL) -> String? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { return nil }
        return text(["hash-object", "--", path], in: root)
    }

    public func isAncestor(_ ancestor: String, of descendant: String, in root: URL) -> Bool {
        (try? run(["merge-base", "--is-ancestor", ancestor, descendant], in: root))?.status == 0
    }

    /// Creates a commit on top of `parentRef` whose only change is `path` set to `content`.
    public func commit(_ content: Data, at path: String, onto parentRef: String, message: String, in root: URL) throws -> String {
        guard let parent = text(["rev-parse", "--verify", "--quiet", parentRef + "^{commit}"], in: root) else {
            throw VaultError.localized("Origin's branch was not found in this repository. Check the connection and try again.")
        }
        guard let blob = text(["hash-object", "-w", "--stdin"], in: root, input: content) else {
            throw VaultError.localized("git could not store the encrypted file in the repository.")
        }
        var mode = "100644"
        if let entry = text(["ls-tree", parent, "--", path], in: root), let existing = entry.split(separator: " ").first {
            mode = String(existing)
        }
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("sops-vault-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        guard (try? run(["read-tree", parent], in: root, extra: env))?.status == 0,
              (try? run(["update-index", "--add", "--cacheinfo", "\(mode),\(blob),\(path)"], in: root, extra: env))?.status == 0,
              let tree = text(["write-tree"], in: root, extra: env) else {
            throw VaultError.localized("git could not prepare the commit.")
        }
        guard let commit = text(["commit-tree", tree, "-p", parent, "-F", "-"], in: root, input: Data(message.utf8)) else {
            throw VaultError.localized("git could not create the commit. Check that git has user.name and user.email set.")
        }
        return commit
    }

    /// Pushes without running local hooks: the commit only changes an encrypted data file.
    public func push(_ commit: String, to branch: String, in root: URL) -> PushResult {
        guard let result = try? run(["push", "--no-verify", "--porcelain", "origin", "\(commit):refs/heads/\(branch)"],
                                    in: root, timeout: 45) else { return .failed(String(localized: "Could not connect to origin.")) }
        if result.status == 0 { return .pushed }
        let text = result.combinedText.lowercased()
        if text.contains("protected branch") || text.contains("gh006") || text.contains("gh013")
            || text.contains("remote rejected") || text.contains("pull request") {
            return .rejected
        }
        if text.contains("non-fast-forward") || text.contains("fetch first") || text.contains("stale info") || text.contains("[rejected]") {
            return .outdated
        }
        if text.contains("permission") || text.contains("denied") || text.contains("403") {
            return .failed(String(localized: "You don't have permission to push to this repository."))
        }
        return .failed(String(localized: "git could not push the change. Check the connection and try again."))
    }

    /// Puts the committed version of `path` back in the working tree. Used only on a copy SOPS Vault wrote itself.
    public func restoreFromHEAD(_ path: String, in root: URL) {
        _ = try? run(["restore", "--worktree", "--", path], in: root)
    }

    /// GitHub owner/repo and web base URL parsed from the origin URL.
    public static func webRepository(remote: String) -> (web: URL, slug: String)? {
        var rest = remote.trimmingCharacters(in: .whitespaces)
        var host = ""
        if let range = rest.range(of: "://") {
            rest = String(rest[range.upperBound...])
            if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash]); rest = String(rest[rest.index(after: slash)...])
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon]); rest = String(rest[rest.index(after: colon)...])
            if let at = host.firstIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        } else { return nil }
        if rest.hasSuffix(".git") { rest = String(rest.dropLast(4)) }
        let parts = rest.split(separator: "/")
        guard !host.isEmpty, parts.count == 2, let web = URL(string: "https://\(host)/\(parts[0])/\(parts[1])") else { return nil }
        return (web, "\(parts[0])/\(parts[1])")
    }
}

/// Opens and inspects pull requests with the GitHub CLI when it is installed.
public struct PullRequestClient: Sendable {
    public let executable: URL?

    public init(path: String? = nil) {
        let candidates = path.map { [$0] } ?? ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func create(in root: URL, slug: String?, head: String, base: String, title: String, body: String) -> URL? {
        guard let executable else { return nil }
        var args = ["pr", "create", "--head", head, "--base", base, "--title", title, "--body-file", "-"]
        if let slug { args += ["--repo", slug] }
        guard let result = try? ProcessRunner.run(executable: executable, arguments: args, input: Data(body.utf8),
                                                  environment: GitClient.environment(), directory: root, timeout: 45,
                                                  captureErrors: true, tool: "gh"), result.status == 0 else { return nil }
        let lines = String(decoding: result.output, as: UTF8.self).split(separator: "\n")
        return lines.last(where: { $0.hasPrefix("https://") }).flatMap { URL(string: String($0)) }
    }

    /// "OPEN", "MERGED" or "CLOSED", or nil when it cannot be determined.
    public func state(of url: URL, in root: URL) -> String? {
        guard let executable,
              let result = try? ProcessRunner.run(executable: executable, arguments: ["pr", "view", url.absoluteString, "--json", "state", "--jq", ".state"],
                                                  environment: GitClient.environment(), directory: root, timeout: 20,
                                                  captureErrors: true, tool: "gh"), result.status == 0 else { return nil }
        let state = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty ? nil : state
    }
}
