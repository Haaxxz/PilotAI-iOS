import Foundation
import XCTest
#if canImport(PilotAI)
@testable import PilotAI
#endif
#if canImport(zlib)
import zlib
#endif

final class CharacterRoleplayTests: XCTestCase {
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func fields(_ data: Data) throws -> [String: Any] { try XCTUnwrap(object(data)["data"] as? [String: Any]) }
    private func card(version: Int = 3, extra: [String: Any] = [:]) throws -> Character {
        let data: [String: Any] = ["name": "Aria", "description": "A patient explorer.", "first_mes": "Hello {{user}}."]
        return try CharacterCardParser.importJSON(json(["spec": "chara_card_v\(version)", "spec_version": "\(version).0", "future_root": ["keep": true], "data": data.merging(extra) { _, new in new }]))
    }
    private func withBook(_ book: [String: Any]) throws -> Character { try card(extra: ["character_book": book]) }
    private func entry(_ content: String, keys: [String] = [], extra: [String: Any] = [:]) -> [String: Any] {
        ["content": content, "keys": keys, "enabled": true].merging(extra) { _, new in new }
    }

    func testLegacyDecodingAndLocalBackupFields() throws {
        var old = try JSONDecoder().decode(Character.self, from: Data(#"{"id":"old","name":"Old"}"#.utf8))
        XCTAssertNil(old.worldbookJSON); XCTAssertNil(old.originalPNG)
        XCTAssertEqual(old.userPersonaName, ""); XCTAssertEqual(old.storyMemory, "")
        old.userPersonaName = "Local"; old.userPersonaDescription = "Private"; old.storyMemory = "Fiction"
        old.originalPNG = try CharacterCardParser.exportPNG(for: old)
        XCTAssertEqual(try JSONDecoder().decode(Character.self, from: JSONEncoder().encode(old)), old)
    }

    func testV1ConvertsAndLegacyMirrorsStayConsistent() throws {
        var character = try CharacterCardParser.importJSON(json(["name": "Before", "spec_version": "1.0", "greeting": "Old", "creatorcomment": "Old notes", "custom": ["unknown": true]]))
        character.name = "After"; character.greeting = "New"; character.creatorNotes = "New notes"
        let exported = try object(CharacterCardParser.exportJSON(for: character))
        XCTAssertEqual(exported["spec"] as? String, "chara_card_v2")
        XCTAssertEqual(exported["spec_version"] as? String, "2.0")
        XCTAssertEqual(exported["name"] as? String, "After")
        XCTAssertEqual(exported["greeting"] as? String, "New")
        XCTAssertEqual(exported["creatorcomment"] as? String, "New notes")
        let data = try XCTUnwrap(exported["data"] as? [String: Any])
        XCTAssertEqual(data["first_mes"] as? String, "New")
        XCTAssertNotNil(data["custom"])
    }

    func testV2AndV3PreserveVersionsAndUnknownData() throws {
        for version in [2, 3] {
            var character = try card(version: version, extra: ["extensions": ["plugin": ["script": "opaque()", "future": 23]], "future_field": [1, 2, 3]])
            character.description = "Edited"
            let output = try CharacterCardParser.exportJSON(for: character)
            let root = try object(output), data = try fields(output)
            XCTAssertEqual(root["spec"] as? String, "chara_card_v\(version)")
            XCTAssertNotNil(root["future_root"])
            XCTAssertEqual(data["description"] as? String, "Edited")
            XCTAssertEqual(data["future_field"] as? [Int], [1, 2, 3])
            XCTAssertEqual(((data["extensions"] as? [String: Any])?["plugin"] as? [String: Any])?["script"] as? String, "opaque()")
            XCTAssertEqual(try CharacterCardParser.importJSON(output).description, "Edited")
        }
    }

    func testImportsCreateCopiesAndCopyResetsMemory() throws {
        let bytes = try CharacterCardParser.exportJSON(for: card())
        let first = try CharacterCardParser.importJSON(bytes), second = try CharacterCardParser.importJSON(bytes)
        XCTAssertNotEqual(first.id, second.id)
        var builtin = Character.defaults[0]
        builtin.storyMemory = "old plot"; builtin.userPersonaName = "Reader"
        builtin.originalPNG = try CharacterCardParser.exportPNG(for: builtin)
        let copy = builtin.copied()
        XCTAssertNotEqual(copy.id, builtin.id); XCTAssertFalse(copy.isBuiltin)
        XCTAssertEqual(copy.storyMemory, ""); XCTAssertEqual(copy.userPersonaName, "Reader")
        XCTAssertEqual(copy.originalPNG, builtin.originalPNG)
    }

    func testLocalPersonaAndMemoryNeverLeakIntoExports() throws {
        var character = try card(extra: ["extensions": ["keep": "extension"]])
        character.userPersonaName = "PRIVATE_PERSONA_NAME"
        character.userPersonaDescription = "PRIVATE_PERSONA_DESCRIPTION"
        character.storyMemory = "PRIVATE_STORY_MEMORY"
        for data in [try CharacterCardParser.exportJSON(for: character, version: 2), try CharacterCardParser.exportJSON(for: character, version: 3)] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_"))
        }
        let png = try CharacterCardParser.exportPNG(for: character)
        for (_, payload) in chunks(png).filter({ $0.0 == "tEXt" }) {
            let split = try XCTUnwrap(payload.firstIndex(of: 0))
            let decoded = try XCTUnwrap(Data(base64Encoded: Data(payload.dropFirst(split + 1))))
            XCTAssertFalse(String(decoding: decoded, as: UTF8.self).contains("PRIVATE_"))
        }
        let imported = try CharacterCardParser.importPNG(png)
        XCTAssertEqual(imported.storyMemory, ""); XCTAssertEqual(imported.userPersonaName, "")
    }

    func testTypedValidationAndBounds() throws {
        let invalid: [[String: Any]] = [
            ["name": ""], ["name": "Valid", "alternate_greetings": ["ok", 2]],
            ["name": "Valid", "description": NSNull()], ["name": "Valid", "extensions": []],
            ["spec": "chara_card_v4", "data": ["name": "Future"]],
            ["spec": "chara_card_v3", "name": "Missing data"], ["name": "Valid", "spec": 2]
        ]
        for source in invalid { XCTAssertThrowsError(try CharacterCardParser.importJSON(json(source))) }
        XCTAssertThrowsError(try CharacterCardParser.importJSON(Data([0xff, 0xfe, 0x7b, 0x00])))
        XCTAssertThrowsError(try CharacterCardParser.importJSON(Data(String(repeating: "[", count: 65).utf8)))
        XCTAssertThrowsError(try CharacterCardParser.importJSON(Data(repeating: 32, count: CharacterCardParser.maximumJSONBytes + 1)))
        XCTAssertThrowsError(try CharacterCardParser.importPNG(Data(repeating: 0, count: CharacterCardParser.maximumPNGBytes + 1)))
        let bom = Data([0xef, 0xbb, 0xbf]) + Data(#"{"name":"BOM"}"#.utf8)
        XCTAssertEqual(try CharacterCardParser.importJSON(bom).name, "BOM")
        XCTAssertThrowsError(try CharacterCardParser.exportJSON(for: card(), version: 1))
    }

    func testWorldbookAndGreetingDraftValidationAndRemoval() throws {
        XCTAssertEqual(try CharacterCardParser.validatedAlternateGreetingsJSON(#"["Hello", "Again"]"#), ["Hello", "Again"])
        for source in ["{}", "[1]", "null", "[\"unterminated]"] { XCTAssertThrowsError(try CharacterCardParser.validatedAlternateGreetingsJSON(source)) }
        for source in [#"{"scan_depth":true}"#, #"{"token_budget":-1}"#, #"{"recursive_scanning":1}"#,
                       #"{"entries":[{"enabled":"yes"}]}"#, #"{"entries":[{"keys":[2]}]}"#, #"{"entries":[{"content":1}]}"#] {
            XCTAssertThrowsError(try CharacterCardParser.validatedWorldbookJSON(source))
        }
        var character = try withBook(["entries": [entry("Retained")], "future_book_key": ["keep": 1]])
        character.worldbookJSON = try CharacterCardParser.worldbookText(for: character)
        XCTAssertNotNil((try fields(CharacterCardParser.exportJSON(for: character))["character_book"] as? [String: Any])?["future_book_key"])
        character.worldbookJSON = "  \n"
        XCTAssertNil(try fields(CharacterCardParser.exportJSON(for: character))["character_book"])
        XCTAssertNil(try CharacterCardParser.worldbook(for: character))
    }

    func testPNGPrefersV3AndFailsClosed() throws {
        let png = try CharacterCardParser.exportPNG(for: card(version: 2))
        let preferred = try CharacterCardParser.exportJSON(for: Character(name: "Preferred"), version: 3).base64EncodedData()
        let edited = replaceText(png, keyword: "ccv3", payload: preferred)
        XCTAssertEqual(try CharacterCardParser.importPNG(edited).name, "Preferred")
        XCTAssertEqual(try CharacterCardParser.importPNG(replaceText(edited, keyword: "chara", payload: Data("bad".utf8))).name, "Preferred")
        for bad in [Data("not base64".utf8), Data("not json".utf8).base64EncodedData(), try CharacterCardParser.exportJSON(for: card(), version: 2).base64EncodedData()] {
            XCTAssertThrowsError(try CharacterCardParser.importPNG(replaceText(png, keyword: "ccv3", payload: bad))) {
                XCTAssertEqual($0 as? CharacterCardParser.CardError, .invalidPreferredV3)
            }
        }
        let duplicate = inserting(png, type: "tEXt", payload: Data("ccv3\0".utf8) + preferred)
        XCTAssertThrowsError(try CharacterCardParser.importPNG(duplicate))
    }

    func testPNGImageAndAncillaryChunksSurviveEdits() throws {
        let original = inserting(try CharacterCardParser.exportPNG(for: card()), type: "tEXt", payload: Data("Software\0retained application metadata".utf8))
        var character = try CharacterCardParser.importPNG(original)
        XCTAssertEqual(character.originalPNG, original)
        character.name = "Revised"
        let output = try CharacterCardParser.exportPNG(for: character)
        XCTAssertEqual(chunks(original).filter { $0.0 == "IDAT" }.map(\.1), chunks(output).filter { $0.0 == "IDAT" }.map(\.1))
        XCTAssertTrue(chunks(output).contains { $0.0 == "tEXt" && $0.1 == Data("Software\0retained application metadata".utf8) })
        let imported = try CharacterCardParser.importPNG(output)
        XCTAssertEqual(imported.name, "Revised")
        XCTAssertEqual(chunks(output).filter { $0.0 == "tEXt" && ($0.1.starts(with: Data("chara\0".utf8)) || $0.1.starts(with: Data("ccv3\0".utf8))) }.count, 2)
    }

    func testOrdinaryAndMalformedPNGsAreRejected() throws {
        let png = try CharacterCardParser.exportPNG(for: card())
        XCTAssertThrowsError(try CharacterCardParser.importPNG(stripCardText(png))) { XCTAssertEqual($0 as? CharacterCardParser.CardError, .metadataMissing) }
        var corrupt = png; corrupt[29] ^= 1
        XCTAssertThrowsError(try CharacterCardParser.importPNG(corrupt))
        XCTAssertThrowsError(try CharacterCardParser.importPNG(Data(png.dropLast())))
        XCTAssertThrowsError(try CharacterCardParser.importPNG(png + Data([0])))
        let badLength = Data([137, 80, 78, 71, 13, 10, 26, 10, 255, 255, 255, 255, 73, 72, 68, 82, 0, 0, 0, 0])
        XCTAssertThrowsError(try CharacterCardParser.importPNG(badLength))
        var header = try XCTUnwrap(chunks(png).first?.1)
        header.replaceSubrange(0..<4, with: [127, 255, 255, 255])
        XCTAssertThrowsError(try CharacterCardParser.importPNG(rebuild(chunks(png).map { $0.0 == "IHDR" ? ($0.0, header) : $0 })))
    }

    func testITXtAndCompressedText() throws {
        let base = stripCardText(try CharacterCardParser.exportPNG(for: card()))
        let encoded = try CharacterCardParser.exportJSON(for: card()).base64EncodedData()
        let itxt = inserting(base, type: "iTXt", payload: Data("ccv3\0".utf8) + Data([0, 0, 0, 0]) + encoded)
        XCTAssertEqual(try CharacterCardParser.importPNG(itxt).name, "Aria")
        #if canImport(zlib)
        let compressed = try deflate(encoded)
        let ztxt = inserting(base, type: "zTXt", payload: Data("ccv3\0".utf8) + Data([0]) + compressed)
        XCTAssertEqual(try CharacterCardParser.importPNG(ztxt).name, "Aria")
        let compressedITXt = inserting(base, type: "iTXt", payload: Data("ccv3\0".utf8) + Data([1, 0, 0, 0]) + compressed)
        XCTAssertEqual(try CharacterCardParser.importPNG(compressedITXt).name, "Aria")
        XCTAssertThrowsError(try CharacterCardParser.importPNG(inserting(base, type: "zTXt", payload: Data("ccv3\0".utf8) + Data([0]) + compressed.dropLast())))
        let tooLarge = Data(repeating: 65, count: ((CharacterCardParser.maximumJSONBytes + 2) / 3) * 4 + 4_097)
        let bomb = inserting(base, type: "zTXt", payload: Data("ccv3\0".utf8) + Data([0]) + (try deflate(tooLarge)))
        XCTAssertThrowsError(try CharacterCardParser.importPNG(bomb)) {
            guard case CharacterCardParser.CardError.tooLarge = $0 else { return XCTFail("Expected bounded decompression: \($0)") }
        }
        #endif
    }

    func testCompleteContextAndMacros() throws {
        var character = try card(extra: ["nickname": "Ari", "extensions": ["depth_prompt": ["prompt": "depth-sentinel"]]])
        character.description = "Description: {{char}} knows {{user}}."
        character.persona = "personality-sentinel"; character.scenario = "scenario-sentinel"
        character.exampleMessages = "example-sentinel <USER>: hi <BOT>"
        character.systemPrompt = "{{original}}\n{{unknown_macro}}"
        character.postHistoryInstructions = "post-sentinel"
        character.creatorNotes = "NOT_CONTEXT_NOTES"; character.tags = ["NOT_CONTEXT_TAG"]
        character.userPersonaName = "Sam"; character.userPersonaDescription = "persona-sentinel"
        character.storyMemory = "memory-sentinel"
        let context = RoleplayContext.build(character: character, messages: [])
        for text in ["Ari knows Sam", "personality-sentinel", "scenario-sentinel", "example-sentinel Sam: hi Ari",
                     "persona-sentinel", "memory-sentinel", "depth-sentinel", "post-sentinel", "{{unknown_macro}}", "Keep real actions"] {
            XCTAssertTrue(context.contains(text), text)
        }
        XCTAssertFalse(context.contains("NOT_CONTEXT"))
        XCTAssertTrue(RoleplayContext.compatibilityNotes(for: character).joined().contains("unknown_macro"))
        XCTAssertEqual(RoleplayContext.expandMacros("{{ user }} <CHAR> {{// comment}} {{noop}}", character: character), "Sam Ari  ")
    }

    func testWorldbookMatchesOnlyDialogueBodies() throws {
        let character = try withBook(["entries": [entry("MATCHED_SENTINEL", keys: ["castle"])]] )
        let hidden: [Message] = [Message(role: .system, content: "castle"), Message(role: .tool, content: "castle"),
                                 Message(role: .assistant, content: "No trigger here", reasoningContent: "castle", toolCalls: [ToolCall(name: "castle", arguments: "castle", output: "castle")]),
                                 Message(role: .user, content: "Hello", attachments: [MessageAttachment(name: "castle", mimeType: "text/plain", dataBase64: "castle")])]
        XCTAssertFalse(RoleplayContext.build(character: character, messages: hidden).contains("MATCHED_SENTINEL"))
        XCTAssertTrue(RoleplayContext.build(character: character, messages: hidden + [Message(role: .user, content: "A CASTLE")]).contains("MATCHED_SENTINEL"))
        XCTAssertTrue(RoleplayContext.build(character: character, messages: [Message(role: .assistant, content: "castle")]).contains("MATCHED_SENTINEL"))
    }

    func testEngineCanDisableStoryMemoryProjection() {
        let character = Character(name: "Aria", userPersonaName: "Sam", storyMemory: "STORY_SENTINEL")
        XCTAssertTrue(RoleplayContext.build(character: character, messages: []).contains("STORY_SENTINEL"))
        let disabled = RoleplayContext.build(character: character, messages: [], includeStoryMemory: false)
        XCTAssertFalse(disabled.contains("STORY_SENTINEL"))
        XCTAssertTrue(disabled.contains("Sam"))
    }

    func testWorldbookDepthZeroAndDefaultTwoAreDistinct() throws {
        let entries = [entry("KEY_SENTINEL", keys: ["castle"]), entry("CONSTANT_SENTINEL", extra: ["constant": true])]
        let messages = [Message(role: .user, content: "castle"), Message(role: .assistant, content: "one"), Message(role: .user, content: "two")]
        let defaults = try withBook(["entries": entries])
        XCTAssertFalse(RoleplayContext.build(character: defaults, messages: messages).contains("KEY_SENTINEL"))
        let zero = try withBook(["scan_depth": 0, "entries": entries])
        let context = RoleplayContext.build(character: zero, messages: [Message(role: .user, content: "castle")])
        XCTAssertFalse(context.contains("KEY_SENTINEL")); XCTAssertTrue(context.contains("CONSTANT_SENTINEL"))
        let deeper = try withBook(["scan_depth": 3, "entries": entries])
        XCTAssertTrue(RoleplayContext.build(character: deeper, messages: messages).contains("KEY_SENTINEL"))
    }

    func testSelectiveCaseSensitiveAndPerEntryDepth() throws {
        let entries = [entry("SELECTED_SENTINEL", keys: ["Castle"], extra: ["case_sensitive": true, "selective": true, "secondary_keys": ["key"], "extensions": ["scan_depth": 3]])]
        let character = try withBook(["scan_depth": 0, "entries": entries])
        XCTAssertFalse(RoleplayContext.build(character: character, messages: [Message(role: .user, content: "castle key")]).contains("SELECTED_SENTINEL"))
        XCTAssertFalse(RoleplayContext.build(character: character, messages: [Message(role: .user, content: "Castle")]).contains("SELECTED_SENTINEL"))
        XCTAssertTrue(RoleplayContext.build(character: character, messages: [Message(role: .user, content: "Castle key")]).contains("SELECTED_SENTINEL"))
    }

    func testRecursiveScanningIsOptIn() throws {
        let entries = [entry("a secret harbor", keys: ["castle"]), entry("RECURSIVE_SENTINEL", keys: ["harbor"])]
        let messages = [Message(role: .user, content: "castle")]
        let nonrecursive = try withBook(["entries": entries])
        XCTAssertFalse(RoleplayContext.build(character: nonrecursive, messages: messages).contains("RECURSIVE_SENTINEL"))
        let recursive = try withBook(["entries": entries, "recursive_scanning": true])
        XCTAssertTrue(RoleplayContext.build(character: recursive, messages: messages).contains("RECURSIVE_SENTINEL"))
    }

    func testUnsupportedConditionsFailClosedEvenForConstantEntries() throws {
        let unsupported: [[String: Any]] = [
            ["use_regex": true], ["keys": ["/castle/i"]], ["extensions": ["probability": 50]],
            ["extensions": ["position": 4]], ["position": "at_depth"], ["extensions": ["group": "one"]],
            ["extensions": ["sticky": 2]], ["extensions": ["selectiveLogic": 1]], ["extensions": ["match_whole_words": true]],
            ["extensions": ["automation_id": "script"]], ["extensions": ["scan_depth": "2"]], ["extensions": ["triggers": ["normal"]]]
        ]
        let entries = unsupported.enumerated().map { entry("UNSUPPORTED_\($0.offset)", extra: $0.element.merging(["constant": true]) { _, new in new }) }
        let character = try withBook(["entries": entries + [entry("@@position\nUNSUPPORTED_DECORATOR", extra: ["constant": true])]])
        XCTAssertFalse(RoleplayContext.build(character: character, messages: [Message(role: .user, content: "castle")]).contains("UNSUPPORTED_"))
        XCTAssertTrue(RoleplayContext.compatibilityNotes(for: character).contains { $0.contains("skipped") })
        let literal = try withBook(["entries": [entry("LITERAL_SENTINEL", keys: ["/castle/i"], extra: ["use_regex": false])]])
        XCTAssertTrue(RoleplayContext.build(character: literal, messages: [Message(role: .user, content: "/castle/i")]).contains("LITERAL_SENTINEL"))
    }

    func testBudgetPriorityOrderingAndWholeEntrySelection() throws {
        let huge = "OVERSIZE_SENTINEL" + String(repeating: "x", count: 4_000)
        let entries = [entry("LOW_SENTINEL " + String(repeating: "l", count: 300), keys: ["go"], extra: ["priority": 1]),
                       entry("HIGH_SENTINEL", keys: ["go"], extra: ["priority": 10, "insertion_order": 2]),
                       entry("PERMANENT_SENTINEL", extra: ["constant": true, "insertion_order": 1, "position": "before_char"]),
                       entry(huge, extra: ["constant": true, "priority": 99])]
        let character = try withBook(["token_budget": 60, "entries": entries])
        let context = RoleplayContext.build(character: character, messages: [Message(role: .user, content: "go")])
        XCTAssertTrue(context.contains("PERMANENT_SENTINEL")); XCTAssertTrue(context.contains("HIGH_SENTINEL"))
        XCTAssertFalse(context.contains("LOW_SENTINEL")); XCTAssertFalse(context.contains("OVERSIZE_SENTINEL"))
        XCTAssertLessThan(try XCTUnwrap(context.range(of: "PERMANENT_SENTINEL")?.lowerBound), try XCTUnwrap(context.range(of: "## Character")?.lowerBound))
        let zero = try withBook(["token_budget": 0, "entries": entries])
        XCTAssertFalse(RoleplayContext.build(character: zero, messages: [Message(role: .user, content: "go")]).contains("SENTINEL"))
        let disabled = try withBook(["enabled": false, "entries": entries])
        XCTAssertFalse(RoleplayContext.build(character: disabled, messages: []).contains("SENTINEL"))
    }

    func testMacroCyclesAndContextSizeAreBoundedWithoutBrokenUnicode() throws {
        var character = Character(name: "{{char}}", description: String(repeating: "🙂", count: 10_000), systemPrompt: "{{description}}{{description}}{{description}}")
        XCTAssertEqual(RoleplayContext.expandMacros("{{char}}", character: character), "{{char}}")
        let context = RoleplayContext.build(character: character, messages: [], inputTokenBudget: 100)
        XCTAssertLessThanOrEqual(context.utf8.count, 400); XCTAssertFalse(context.contains("�"))
        XCTAssertEqual(RoleplayContext.build(character: character, messages: [], inputTokenBudget: 0), "")
        character.name = String(repeating: "{{description}}", count: 20_000)
        XCTAssertLessThanOrEqual(RoleplayContext.expandMacros("{{char}}", character: character).utf8.count, RoleplayContext.maximumExpandedBytes)
    }

    // Independent PNG fixture builder: CRC implementation deliberately differs from production's lookup table.
    private func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320) }
        }
        return crc ^ 0xffffffff
    }
    private func intBytes(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    private func chunks(_ png: Data) -> [(String, Data)] {
        let b = [UInt8](png)
        var offset = 8, result: [(String, Data)] = []
        while offset + 12 <= b.count {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(b[offset + $1]) }
            guard length <= b.count - offset - 12 else { break }
            result.append((String(decoding: b[(offset + 4)..<(offset + 8)], as: UTF8.self), Data(b[(offset + 8)..<(offset + 8 + length)])))
            offset += length + 12
        }
        return result
    }
    private func rebuild(_ chunks: [(String, Data)]) -> Data {
        var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
        for (type, payload) in chunks {
            let body = Data(type.utf8) + payload
            output += intBytes(UInt32(payload.count)) + body + intBytes(checksum(body))
        }
        return output
    }
    private func inserting(_ png: Data, type: String, payload: Data) -> Data {
        var source = chunks(png); source.insert((type, payload), at: source.count - 1); return rebuild(source)
    }
    private func replaceText(_ png: Data, keyword: String, payload: Data) -> Data {
        rebuild(chunks(png).map { type, bytes in
            (type, type == "tEXt" && bytes.starts(with: Data((keyword + "\0").utf8)) ? Data((keyword + "\0").utf8) + payload : bytes)
        })
    }
    private func stripCardText(_ png: Data) -> Data {
        rebuild(chunks(png).filter { $0.0 != "tEXt" || (!$0.1.starts(with: Data("chara\0".utf8)) && !$0.1.starts(with: Data("ccv3\0".utf8))) })
    }
    #if canImport(zlib)
    private func deflate(_ data: Data) throws -> Data {
        var count = compressBound(uLong(data.count))
        var output = Data(count: Int(count))
        let status = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compress2(target.bindMemory(to: Bytef.self).baseAddress, &count, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_SPEED)
            }
        }
        guard status == Z_OK else { throw CharacterCardParser.CardError.invalidMetadata }
        output.count = Int(count)
        return output
    }
    #endif
}

// Allows the focused suite to run with swiftc on Linux without an Xcode project or dependency changes.
#if CHARACTER_TEST_MAIN
@main
enum CharacterRoleplayTestRunner {
    static func main() {
        XCTMain([testCase([
            ("testLegacyDecodingAndLocalBackupFields", CharacterRoleplayTests.testLegacyDecodingAndLocalBackupFields),
            ("testV1ConvertsAndLegacyMirrorsStayConsistent", CharacterRoleplayTests.testV1ConvertsAndLegacyMirrorsStayConsistent),
            ("testV2AndV3PreserveVersionsAndUnknownData", CharacterRoleplayTests.testV2AndV3PreserveVersionsAndUnknownData),
            ("testImportsCreateCopiesAndCopyResetsMemory", CharacterRoleplayTests.testImportsCreateCopiesAndCopyResetsMemory),
            ("testLocalPersonaAndMemoryNeverLeakIntoExports", CharacterRoleplayTests.testLocalPersonaAndMemoryNeverLeakIntoExports),
            ("testTypedValidationAndBounds", CharacterRoleplayTests.testTypedValidationAndBounds),
            ("testWorldbookAndGreetingDraftValidationAndRemoval", CharacterRoleplayTests.testWorldbookAndGreetingDraftValidationAndRemoval),
            ("testPNGPrefersV3AndFailsClosed", CharacterRoleplayTests.testPNGPrefersV3AndFailsClosed),
            ("testPNGImageAndAncillaryChunksSurviveEdits", CharacterRoleplayTests.testPNGImageAndAncillaryChunksSurviveEdits),
            ("testOrdinaryAndMalformedPNGsAreRejected", CharacterRoleplayTests.testOrdinaryAndMalformedPNGsAreRejected),
            ("testITXtAndCompressedText", CharacterRoleplayTests.testITXtAndCompressedText),
            ("testCompleteContextAndMacros", CharacterRoleplayTests.testCompleteContextAndMacros),
            ("testWorldbookMatchesOnlyDialogueBodies", CharacterRoleplayTests.testWorldbookMatchesOnlyDialogueBodies),
            ("testEngineCanDisableStoryMemoryProjection", CharacterRoleplayTests.testEngineCanDisableStoryMemoryProjection),
            ("testWorldbookDepthZeroAndDefaultTwoAreDistinct", CharacterRoleplayTests.testWorldbookDepthZeroAndDefaultTwoAreDistinct),
            ("testSelectiveCaseSensitiveAndPerEntryDepth", CharacterRoleplayTests.testSelectiveCaseSensitiveAndPerEntryDepth),
            ("testRecursiveScanningIsOptIn", CharacterRoleplayTests.testRecursiveScanningIsOptIn),
            ("testUnsupportedConditionsFailClosedEvenForConstantEntries", CharacterRoleplayTests.testUnsupportedConditionsFailClosedEvenForConstantEntries),
            ("testBudgetPriorityOrderingAndWholeEntrySelection", CharacterRoleplayTests.testBudgetPriorityOrderingAndWholeEntrySelection),
            ("testMacroCyclesAndContextSizeAreBoundedWithoutBrokenUnicode", CharacterRoleplayTests.testMacroCyclesAndContextSizeAreBoundedWithoutBrokenUnicode)
        ])])
    }
}
#endif
