import Foundation
import Testing

/// Keeps Localization/es.lproj in step with the source: every user-facing literal must have a Spanish
/// entry, and each translation must use the same format arguments as its key.
@Suite struct LocalizationTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Localization/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
    }

    /// Format arguments in order of position, e.g. "%1$@ %2$lld" and "%@ %lld" both give ["@", "lld"].
    private func arguments(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(@|lld|ld|d)"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let items = matches.enumerated().map { index, match -> (Int, String) in
            let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? index + 1
            return (position, String(text[Range(match.range(at: 2), in: text)!]))
        }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// String literals passed to localizing APIs, with `\(…)` interpolations kept intact.
    private func localizedLiterals(in source: String) -> [String] {
        let starts = try! NSRegularExpression(pattern:
            #"(?:\b(?:Text|Label|Button|Toggle|TextField|SecureField|Section|Link|CommandMenu|ContentUnavailableView|Picker|LocalizedStringKey)|\.(?:help|alert|confirmationDialog|accessibilityLabel|localized))\(\s*"|String\(localized:\s*"|\b(?:title|subtitle):\s*"|LocalizedStringKey\("[^"]*"\)\s*:\s*"|return \(""#)
        let characters = Array(source)
        var literals: [String] = []
        let utf16 = NSRange(source.startIndex..., in: source)
        for match in starts.matches(in: source, range: utf16) {
            guard let range = Range(match.range, in: source) else { continue }
            var i = source.distance(from: source.startIndex, to: range.upperBound)
            var literal = "", depth = 0, inNested = false
            while i < characters.count {
                let c = characters[i]
                if depth == 0 {
                    if c == "\\" && i + 1 < characters.count {
                        if characters[i + 1] == "(" { depth = 1; literal += "\\("; i += 2; continue }
                        literal += String([c, characters[i + 1]]); i += 2; continue
                    }
                    if c == "\"" { break }
                    literal.append(c)
                } else {
                    literal.append(c)
                    if c == "\"" { inNested.toggle() }
                    else if !inNested && c == "(" { depth += 1 }
                    else if !inNested && c == ")" { depth -= 1 }
                }
                i += 1
            }
            literals.append(literal)
        }
        return literals
    }

    /// Regex matching the localization key Swift generates for a literal (interpolations become %@ or %lld).
    private func keyPattern(_ literal: String) -> NSRegularExpression {
        var pattern = "^", i = literal.startIndex
        while i < literal.endIndex {
            if literal[i...].hasPrefix("\\(") {
                var depth = 0, j = literal.index(i, offsetBy: 1)
                repeat {
                    if literal[j] == "(" { depth += 1 } else if literal[j] == ")" { depth -= 1 }
                    j = literal.index(after: j)
                } while depth > 0 && j < literal.endIndex
                pattern += "%(?:@|lld)"; i = j; continue
            }
            if literal[i...].hasPrefix("\\n") { pattern += "\\n"; i = literal.index(i, offsetBy: 2); continue }
            if literal[i...].hasPrefix("\\\"") { pattern += "\""; i = literal.index(i, offsetBy: 2); continue }
            pattern += NSRegularExpression.escapedPattern(for: String(literal[i])); i = literal.index(after: i)
        }
        return try! NSRegularExpression(pattern: pattern + "$")
    }

    @Test func spanishTranslationsKeepFormatArguments() throws {
        let spanish = try table("es")
        #expect(spanish.count > 150)
        for (key, value) in spanish {
            #expect(arguments(key) == arguments(value), "Format arguments differ for \(key)")
            #expect(!value.isEmpty, "Empty translation for \(key)")
        }
        #expect(try table("en").isEmpty)
    }

    @Test func everyUserFacingLiteralHasASpanishEntry() throws {
        let keys = Array(try table("es").keys)
        let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var checked = 0, missing: [String] = []
        for file in sources {
            for literal in localizedLiterals(in: try String(contentsOf: file, encoding: .utf8)) where literal.contains(where: \.isLetter) {
                checked += 1
                let pattern = keyPattern(literal)
                if !keys.contains(where: { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                    missing.append("\(file.lastPathComponent): \(literal)")
                }
            }
        }
        #expect(checked > 150)
        #expect(missing.isEmpty, "Missing Spanish entries:\n\(missing.joined(separator: "\n"))")
    }
}
