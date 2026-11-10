import Foundation

/// One pending edit. `original` is the value the user saw when the edit started (nil: the key did not
/// exist). `value` nil deletes the key. Comparing `original` with the latest remote value detects conflicts.
public struct SecretChange: Sendable, Equatable, Identifiable {
    public let path: [PathPart]
    public let original: JSONValue?
    public let value: JSONValue?
    public var id: String { path.map(\.sops).joined() }
    public var name: String { SecretEntry(path: path, value: .null).name }
    public init(path: [PathPart], original: JSONValue?, value: JSONValue?) {
        self.path = path; self.original = original; self.value = value
    }
}

public enum Merge {
    public static func applying(_ changes: [SecretChange], to root: JSONValue) throws -> JSONValue {
        try changes.reduce(root) { try $0.updating(path: $1.path, value: $1.value) }
    }

    /// Changes whose key was modified by someone else to a different value since the edit started.
    public static func conflicts(_ changes: [SecretChange], remote: JSONValue) -> [SecretChange] {
        changes.filter { change in
            let current = remote[change.path]
            return current != change.original && current != change.value
        }
    }

    /// Top-level differences from `base` to `local`, as changes that can be replayed on another version.
    public static func diff(from base: JSONValue, to local: JSONValue) -> [SecretChange] {
        guard case .object(let before) = base, case .object(let after) = local else { return [] }
        return Set(before.keys).union(after.keys)
            .filter { $0 != "sops" && !$0.hasPrefix("sops_") }
            .sorted()
            .compactMap { key in
                before[key] == after[key] ? nil : SecretChange(path: [.key(key)], original: before[key], value: after[key])
            }
    }
}

extension Array where Element == PathPart {
    public func isPrefix(of other: [PathPart]) -> Bool { count <= other.count && Array(other.prefix(count)) == self }
}
