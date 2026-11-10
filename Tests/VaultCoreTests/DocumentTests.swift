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
