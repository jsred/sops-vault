import Foundation
import Testing
@testable import VaultCore

@Suite(.timeLimit(.minutes(1))) struct DocumentTests {
    @Test func testTypedJSONRoundTripAndPaths() throws {
        let bytes = Data(#"{"text":"fake","large":9007199254740993,"flag":true,"nil":null,"array":[1,"two"],"empty":{}}"#.utf8)
        let root = try JSONDecoder().decode(JSONValue.self, from: bytes)
        #expect(try JSONDecoder().decode(JSONValue.self, from: root.data) == root)
        #expect(root[[.key("large")]] == .number(Decimal(string: "9007199254740993")!))
        let document = VaultDocument(root: root, ciphertext: Data())
        #expect(document.entries.count == 7)
        #expect(document.entries.first { $0.name == "array › [1]" }?.value == .string("two"))
        #expect(PathPart.key("a\"b\\c").sops == #"["a\"b\\c"]"#)
    }
    @Test func testDeleteArrayIndexShiftsAndRetainsOtherItems() throws {
        let root = JSONValue.object(["a": .array([.string("one"), .string("two")])])
        let changed = try root.updating(path: [.key("a"), .index(0)], value: nil)
        #expect(changed == .object(["a": .array([.string("two")])]))
    }
    @Test func testEmptyAndLiteralDotKeys() throws {
        let root = JSONValue.object(["literal.dot": .string("")])
        #expect(root[[.key("literal.dot")]] == .string(""))
        #expect(root[[.key("literal"), .key("dot")]] == nil)
        #expect(try root.updating(path: [.key("new")], value: .null)[[.key("new")]] == .null)
    }
    @Test func testConfigErrorsDoNotReadIdentity() throws {
        #expect(throws: (any Error).self) { try SOPSConfiguration(executablePath: "/nonexistent/sops").executable() }
        #expect(throws: (any Error).self) { try SOPSConfiguration(ageKeyPath: "/nonexistent/test-key").environment() }
    }
}

@Suite struct MergeTests {
    @Test func conflictsOnlyWhenRemoteMovedToADifferentValue() {
        let remote: JSONValue = .object(["A": .string("theirs"), "B": .string("same"), "C": .string("mine")])
        let changes = [
            SecretChange(path: [.key("A")], original: .string("old"), value: .string("mine")),
            SecretChange(path: [.key("B")], original: .string("same"), value: .string("new")),
            SecretChange(path: [.key("C")], original: .string("old"), value: .string("mine")),
            SecretChange(path: [.key("D")], original: .string("old"), value: nil),
        ]
        #expect(Merge.conflicts(changes, remote: remote).map(\.name) == ["A"])
    }
    @Test func diffProducesReplayableTopLevelChanges() throws {
        let base: JSONValue = .object(["A": .string("1"), "B": .object(["x": .bool(true)]), "C": .string("gone")])
        let local: JSONValue = .object(["A": .string("1"), "B": .object(["x": .bool(false)]), "D": .string("new")])
        let diff = Merge.diff(from: base, to: local)
        #expect(diff.map(\.name) == ["B", "C", "D"])
        #expect(try Merge.applying(diff, to: base) == local)
    }
}
