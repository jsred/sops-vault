import Foundation

public enum VaultError: LocalizedError, Equatable {
    case message(String)
    /// A user-facing message looked up in the app's Localizable.strings (English is the key).
    public static func localized(_ value: String.LocalizationValue) -> VaultError { .message(String(localized: value)) }
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum JSONValue: Equatable, Sendable, Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var data: Data { encoded(using: JSONEncoder().encode) }
    // Keep encoding failures contained; the encoder can be supplied in failure tests.
    func encoded(using encode: (JSONValue) throws -> Data) -> Data { (try? encode(self)) ?? Data() }
    public var json: String { String(decoding: data, as: UTF8.self) }
    public var display: String { if case .string(let v) = self { return v }; return json }
    public var typeName: String {
        switch self {
        case .object: return String(localized: "Object")
        case .array: return String(localized: "List")
        case .string: return String(localized: "Text")
        case .number: return String(localized: "Number")
        case .bool: return String(localized: "Boolean")
        case .null: return String(localized: "Null")
        }
    }
    public subscript(path: [PathPart]) -> JSONValue? {
        guard let first = path.first else { return self }
        switch (self, first) {
        case (.object(let v), .key(let key)): return v[key]?[Array(path.dropFirst())]
        case (.array(let v), .index(let i)) where v.indices.contains(i): return v[i][Array(path.dropFirst())]
        default: return nil
        }
    }

    public func updating(path: [PathPart], value: JSONValue?) throws -> JSONValue {
        guard let first = path.first else {
            guard let value else { throw VaultError.localized("The document root cannot be deleted.") }
            return value
        }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var object), .key(let key)):
            if rest.isEmpty { object[key] = value }
            else {
                guard let child = object[key] else { throw VaultError.localized("The key no longer exists. Reload the file.") }
                object[key] = try child.updating(path: rest, value: value)
            }
            return .object(object)
        case (.array(var array), .index(let index)) where array.indices.contains(index):
            if rest.isEmpty && value == nil { array.remove(at: index) }
            else { array[index] = try array[index].updating(path: rest, value: value) }
            return .array(array)
        default: throw VaultError.localized("The path does not match a valid key.")
        }
    }
}

public enum PathPart: Hashable, Sendable {
    case key(String), index(Int)
    public var sops: String {
        switch self {
        case .key(let k): return "[\(JSONValue.string(k).json)]"
        case .index(let i): return "[\(i)]"
        }
    }
}

public struct SecretEntry: Identifiable, Equatable, Sendable {
    public let path: [PathPart]
    public let value: JSONValue
    public var id: String { path.map(\.sops).joined() }
    public var name: String {
        path.map { switch $0 { case .key(let k): return k; case .index(let i): return "[\(i)]" } }.joined(separator: " › ")
    }
    public init(path: [PathPart], value: JSONValue) { self.path = path; self.value = value }
}

public struct VaultDocument: Sendable {
    public let root: JSONValue
    public let ciphertext: Data
    public let entries: [SecretEntry]
    public init(root: JSONValue, ciphertext: Data) {
        self.root = root
        self.ciphertext = ciphertext
        func flatten(_ v: JSONValue, _ path: [PathPart]) -> [SecretEntry] {
            switch v {
            case .object(let keys) where !keys.isEmpty:
                return keys.keys.sorted().flatMap { flatten(keys[$0]!, path + [.key($0)]) }
            case .array(let items) where !items.isEmpty:
                return items.enumerated().flatMap { flatten($0.element, path + [.index($0.offset)]) }
            default: return path.isEmpty ? [] : [SecretEntry(path: path, value: v)]
            }
        }
        entries = flatten(root, [])
    }
}

public enum FileFormat: String, Sendable {
    case json, yaml, dotenv
    public static func detect(url: URL, data: Data) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "env": return .dotenv
        case "yaml", "yml": return .yaml
        case "json": return .json
        default:
            let prefix = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("{") { return .json }
            if String(decoding: data, as: UTF8.self).contains("sops_age__") { return .dotenv }
            return .yaml
        }
    }
}
