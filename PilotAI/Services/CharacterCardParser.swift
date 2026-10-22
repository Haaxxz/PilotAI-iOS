import Foundation
import CoreFoundation
#if canImport(zlib)
import zlib
#endif

/// Bounded, lossless definition exchange. Local persona/memory are deliberately not serialized here.
public enum CharacterCardParser {
    public static let maximumJSONBytes = 16 * 1024 * 1024
    public static let maximumPNGBytes = 32 * 1024 * 1024
    public static let maximumWorldbookEntries = 2_048
    private static let maximumEncodedBytes = ((maximumJSONBytes + 2) / 3) * 4 + 4_096
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let textFields = ["name", "description", "personality", "scenario", "first_mes", "mes_example",
                                     "creator_notes", "system_prompt", "post_history_instructions", "creator", "character_version"]

    public enum CardError: LocalizedError, Equatable {
        case tooLarge(String), invalidJSON, invalidUTF8, invalidField(String), unsupportedVersion
        case invalidPNG(String), metadataMissing, invalidMetadata, invalidPreferredV3, compressedMetadataUnavailable

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let kind): return "\(kind) exceeds the supported size or complexity limit (JSON: 16 MiB; PNG: 32 MiB; worldbook: 2,048 entries)."
            case .invalidJSON: return "The character card must be a valid JSON object."
            case .invalidUTF8: return "Character card JSON must use valid UTF-8 encoding."
            case .invalidField(let field): return "Invalid character card field: \(field)."
            case .unsupportedVersion: return "Only Character Card V1, V2 and V3 are supported; exports use V2 or V3."
            case .invalidPNG(let reason): return "Invalid PNG character card: \(reason)."
            case .metadataMissing: return "This image has no character card data. Select an original character-card PNG or JSON file."
            case .invalidMetadata: return "The PNG character metadata is malformed or duplicated."
            case .invalidPreferredV3: return "The preferred ccv3 block is corrupted. The older chara block was not substituted."
            case .compressedMetadataUnavailable: return "Compressed PNG text cannot be decoded on this platform. Use an uncompressed character card or JSON."
            }
        }
    }

    // Optional-return adapters are kept for existing callers; UI uses the throwing APIs below.
    public static func parseCharacter(from url: URL) -> Character? { try? importCharacter(from: url) }
    public static func parseJSON(_ data: Data, id: String = UUID().uuidString) -> Character? { try? importJSON(data, id: id) }
    public static func character(from json: [String: Any], id: String = UUID().uuidString) -> Character? {
        guard JSONSerialization.isValidJSONObject(json),
              let bytes = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return parseJSON(bytes, id: id)
    }

    public static func importCharacter(from url: URL) throws -> Character {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read at most the cap plus one, even if a provider reports a misleading file size.
        var bytes = Data()
        while true {
            let chunk = try handle.read(upToCount: min(1_048_576, maximumPNGBytes + 1 - bytes.count)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
            guard bytes.count <= maximumPNGBytes else { throw CardError.tooLarge("Character file") }
        }
        if bytes.starts(with: signature) || url.pathExtension.lowercased() == "png" { return try importPNG(bytes) }
        return try importJSON(bytes)
    }

    public static func importJSON(_ bytes: Data, id: String = UUID().uuidString) throws -> Character {
        let root = try jsonObject(bytes)
        let fields = try validatedFields(root)
        return Character(id: id, name: fields["name"] as? String ?? "", avatarEmoji: "🎭",
                         description: fields["description"] as? String ?? "",
                         greeting: fields["first_mes"] as? String ?? fields["greeting"] as? String ?? "",
                         persona: fields["personality"] as? String ?? "",
                         systemPrompt: fields["system_prompt"] as? String ?? "",
                         alternateGreetings: fields["alternate_greetings"] as? [String] ?? [],
                         exampleMessages: fields["mes_example"] as? String ?? "",
                         scenario: fields["scenario"] as? String ?? "",
                         postHistoryInstructions: fields["post_history_instructions"] as? String ?? "",
                         creatorNotes: fields["creator_notes"] as? String ?? fields["creatorcomment"] as? String ?? "",
                         tags: fields["tags"] as? [String] ?? [], creator: fields["creator"] as? String ?? "",
                         version: fields["character_version"] as? String ?? "",
                         cardJSON: String(decoding: bytes, as: UTF8.self))
    }

    /// The default preserves V2/V3. V1 is upgraded to V2; an explicit version creates a compatible view.
    public static func exportJSON(for character: Character, version: Int? = nil) throws -> Data {
        var root = try retainedRoot(for: character)
        var fields = root.isEmpty ? [:] : try validatedFields(root)
        let originalVersion = root["spec"] as? String == "chara_card_v3" ? 3 : 2
        let target = version ?? originalVersion
        guard target == 2 || target == 3 else { throw CardError.unsupportedVersion }
        fields["name"] = character.name; fields["description"] = character.description
        fields["personality"] = character.persona; fields["scenario"] = character.scenario
        fields["first_mes"] = character.greeting; fields["alternate_greetings"] = character.alternateGreetings
        fields["mes_example"] = character.exampleMessages; fields["system_prompt"] = character.systemPrompt
        fields["post_history_instructions"] = character.postHistoryInstructions; fields["creator_notes"] = character.creatorNotes
        fields["tags"] = character.tags; fields["creator"] = character.creator; fields["character_version"] = character.version
        fields["extensions"] = fields["extensions"] ?? [String: Any]()
        if let draft = character.worldbookJSON {
            fields["character_book"] = try validatedWorldbookJSON(draft)
        }
        if target == 3 { fields["group_only_greetings"] = fields["group_only_greetings"] ?? [String]() }
        // Update legacy mirrors too, including aliases, rather than exporting a stale second definition.
        for key in Self.textFields + ["alternate_greetings", "tags", "character_book"] where root[key] != nil {
            root[key] = fields[key]
        }
        if root["greeting"] != nil { root["greeting"] = character.greeting }
        if root["creatorcomment"] != nil { root["creatorcomment"] = character.creatorNotes }
        if fields["greeting"] != nil { fields["greeting"] = character.greeting }
        if fields["creatorcomment"] != nil { fields["creatorcomment"] = character.creatorNotes }
        let legacy = (root["spec"] as? String ?? "").isEmpty
        root["spec"] = "chara_card_v\(target)"
        if version != nil || root["spec_version"] == nil || target != originalVersion || legacy { root["spec_version"] = "\(target).0" }
        root["data"] = fields
        _ = try validatedFields(root)
        return try serialized(root)
    }

    /// Editable JSON has exactly the same validation as imported books. Blank removes the book.
    public static func validatedWorldbookJSON(_ source: String) throws -> [String: Any]? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let book = try jsonObject(Data(source.utf8))
        try validateBook(book)
        return book
    }

    public static func worldbook(for character: Character) throws -> [String: Any]? {
        if let draft = character.worldbookJSON { return try validatedWorldbookJSON(draft) }
        let root = try retainedRoot(for: character)
        guard !root.isEmpty else { return nil }
        return try validatedFields(root)["character_book"] as? [String: Any]
    }

    public static func worldbookText(for character: Character) throws -> String {
        guard let book = try worldbook(for: character) else { return "" }
        return String(decoding: try serialized(book), as: UTF8.self)
    }

    public static func validatedAlternateGreetingsJSON(_ source: String) throws -> [String] {
        let bytes = Data(source.utf8)
        try validateJSONEnvelope(bytes)
        guard let values = try? JSONSerialization.jsonObject(with: bytes) as? [String] else {
            throw CardError.invalidField("alternate_greetings must be a JSON array of strings")
        }
        return values
    }

    /// For projection/compatibility only; callers never interpret retained extensions as executable code.
    static func retainedFields(for character: Character) -> [String: Any] {
        guard let root = try? retainedRoot(for: character), !root.isEmpty else { return [:] }
        return (try? validatedFields(root)) ?? [:]
    }

    private static func retainedRoot(for character: Character) throws -> [String: Any] {
        guard let raw = character.cardJSON else { return [:] }
        return try jsonObject(Data(raw.utf8))
    }

    private static func jsonObject(_ bytes: Data) throws -> [String: Any] {
        try validateJSONEnvelope(bytes)
        // JSONSerialization accepts UTF-16; card definitions intentionally require UTF-8.
        guard var text = String(data: bytes, encoding: .utf8) else { throw CardError.invalidUTF8 }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CardError.invalidJSON
        }
        return root
    }

    private static func validateJSONEnvelope(_ bytes: Data) throws {
        guard bytes.count <= maximumJSONBytes else { throw CardError.tooLarge("Character JSON") }
        var depth = 0, containers = 0, values = 0
        var quoted = false, escaped = false
        // Bound nesting before Foundation's recursive parser; punctuation inside strings is ignored.
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; containers += 1 }
            else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == 44 || byte == 58 { values += 1 }
            guard depth <= 64, containers <= 100_000, values <= 200_000 else { throw CardError.tooLarge("JSON nesting or field count") }
        }
    }

    private static func serialized(_ object: [String: Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try validateJSONEnvelope(bytes)
        return bytes
    }

    private static func validatedFields(_ root: [String: Any]) throws -> [String: Any] {
        let spec: String
        if let value = root["spec"] {
            guard let text = value as? String else { throw CardError.invalidField("spec must be text") }
            spec = text
        } else { spec = "" }
        guard spec.isEmpty || spec == "chara_card_v2" || spec == "chara_card_v3" else { throw CardError.unsupportedVersion }
        let fields: [String: Any]
        if spec.isEmpty { fields = root }
        else {
            guard let data = root["data"] as? [String: Any] else { throw CardError.invalidField("data must be an object") }
            fields = data
        }
        if let version = root["spec_version"], !(version is String) { throw CardError.invalidField("spec_version must be text") }
        guard let name = fields["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CardError.invalidField("name must be nonempty text")
        }
        for field in textFields + ["greeting", "creatorcomment", "nickname"] {
            if let value = fields[field], !(value is String) { throw CardError.invalidField("\(field) must be text") }
        }
        for field in ["tags", "alternate_greetings", "group_only_greetings"] {
            if let value = fields[field], !(value is [String]) { throw CardError.invalidField("\(field) must be an array of strings") }
        }
        if let ext = fields["extensions"], !(ext is [String: Any]) { throw CardError.invalidField("extensions must be an object") }
        if let value = fields["character_book"] {
            guard let book = value as? [String: Any] else { throw CardError.invalidField("character_book must be an object") }
            try validateBook(book)
        }
        return fields
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func flag(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func validateBook(_ book: [String: Any]) throws {
        for field in ["scan_depth", "token_budget"] {
            if let value = book[field] {
                guard let number = number(value), number >= 0, number.rounded() == number, number <= Double(Int32.max) else {
                    throw CardError.invalidField("worldbook \(field) must be a nonnegative integer")
                }
            }
        }
        for field in ["recursive_scanning", "enabled"] where book[field] != nil {
            guard flag(book[field]) != nil else { throw CardError.invalidField("worldbook \(field) must be a boolean") }
        }
        if let ext = book["extensions"], !(ext is [String: Any]) { throw CardError.invalidField("worldbook extensions must be an object") }
        guard let rawEntries = book["entries"] else { return }
        guard let entries = rawEntries as? [[String: Any]] else { throw CardError.invalidField("worldbook entries must be an array of objects") }
        guard entries.count <= maximumWorldbookEntries else { throw CardError.tooLarge("Worldbook") }
        for (index, entry) in entries.enumerated() {
            let label = "worldbook entry \(index + 1)"
            for field in ["keys", "secondary_keys"] {
                if let value = entry[field], !(value is [String]) { throw CardError.invalidField("\(label) \(field) must be an array of strings") }
            }
            for field in ["content", "position"] {
                if let value = entry[field], !(value is String) { throw CardError.invalidField("\(label) \(field) must be text") }
            }
            for field in ["enabled", "constant", "selective", "case_sensitive", "use_regex"] where entry[field] != nil {
                guard flag(entry[field]) != nil else { throw CardError.invalidField("\(label) \(field) must be a boolean") }
            }
            for field in ["insertion_order", "priority"] where entry[field] != nil {
                guard number(entry[field]) != nil else { throw CardError.invalidField("\(label) \(field) must be a finite number") }
            }
            if let ext = entry["extensions"], !(ext is [String: Any]) { throw CardError.invalidField("\(label) extensions must be an object") }
        }
    }

    private struct PNGChunk { let type: String; let data: Data }

    public static func importPNG(_ bytes: Data, id: String = UUID().uuidString) throws -> Character {
        let chunks = try pngChunks(bytes)
        let metadata = chunks.filter { ["tEXt", "iTXt", "zTXt"].contains($0.type) }
        let v3 = metadata.filter { keyword($0) == "ccv3" }
        let chosen = v3.isEmpty ? metadata.filter { keyword($0) == "chara" } : v3
        guard !chosen.isEmpty else { throw CardError.metadataMissing }
        do {
            guard chosen.count == 1 else { throw CardError.invalidMetadata }
            let encoded = try textPayload(chosen[0])
            guard encoded.count <= maximumEncodedBytes else { throw CardError.tooLarge("PNG metadata") }
            guard let text = String(data: encoded, encoding: .utf8),
                  let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CardError.invalidMetadata }
            var character = try importJSON(decoded, id: id)
            if !v3.isEmpty, retainedFields(for: character).isEmpty { throw CardError.invalidMetadata }
            // ccv3 must actually describe V3, not a mismatched or obsolete fallback definition.
            if !v3.isEmpty, try jsonObject(decoded)["spec"] as? String != "chara_card_v3" { throw CardError.invalidMetadata }
            character.originalPNG = bytes
            return character
        } catch let error as CardError {
            if case .tooLarge = error { throw error }
            if case .compressedMetadataUnavailable = error { throw error }
            throw v3.isEmpty ? error : CardError.invalidPreferredV3
        } catch { throw v3.isEmpty ? CardError.invalidMetadata : CardError.invalidPreferredV3 }
    }

    /// Keeps every non-card chunk and the original image data; writes consistent V2 and V3 definitions.
    public static func exportPNG(for character: Character) throws -> Data {
        let chunks = try pngChunks(character.originalPNG ?? defaultPNG())
        let v2 = try exportJSON(for: character, version: 2).base64EncodedData()
        let v3 = try exportJSON(for: character, version: 3).base64EncodedData()
        var result = signature
        for chunk in chunks {
            if ["tEXt", "iTXt", "zTXt"].contains(chunk.type), ["chara", "ccv3"].contains(keyword(chunk)) { continue }
            if chunk.type == "IEND" {
                for (key, bytes) in [("chara", v2), ("ccv3", v3)] {
                    try appendChunk(PNGChunk(type: "tEXt", data: Data((key + "\0").utf8) + bytes), to: &result)
                }
            }
            try appendChunk(chunk, to: &result)
        }
        return result
    }

    private static func keyword(_ chunk: PNGChunk) -> String {
        let bytes = chunk.data.prefix(while: { $0 != 0 })
        guard bytes.count <= 79 else { return "" }
        return String(bytes: bytes, encoding: .isoLatin1)?.lowercased() ?? ""
    }

    private static func textPayload(_ chunk: PNGChunk) throws -> Data {
        let bytes = chunk.data
        guard let keyEnd = bytes.firstIndex(of: 0), keyEnd > 0, keyEnd <= 79 else { throw CardError.invalidMetadata }
        var offset = keyEnd + 1
        if chunk.type == "tEXt" { return Data(bytes.dropFirst(offset)) }
        if chunk.type == "zTXt" {
            guard offset < bytes.count, bytes[offset] == 0 else { throw CardError.invalidMetadata }
            return try inflateText(Data(bytes.dropFirst(offset + 1)))
        }
        guard offset + 2 <= bytes.count, bytes[offset] <= 1, bytes[offset + 1] == 0 else { throw CardError.invalidMetadata }
        let compressed = bytes[offset] == 1
        offset += 2
        for _ in 0..<2 {
            guard let end = bytes[offset...].firstIndex(of: 0) else { throw CardError.invalidMetadata }
            offset = end + 1
        }
        let payload = Data(bytes.dropFirst(offset))
        return compressed ? try inflateText(payload) : payload
    }

    private static func inflateText(_ data: Data) throws -> Data {
        #if canImport(zlib)
        guard !data.isEmpty else { throw CardError.invalidMetadata }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CardError.invalidMetadata }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard result.count + count <= maximumEncodedBytes else { throw CardError.tooLarge("Decompressed PNG metadata") }
                result.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw CardError.invalidMetadata }
                    return result
                }
                guard status == Z_OK, count > 0 else { throw CardError.invalidMetadata }
            }
        }
        #else
        throw CardError.compressedMetadataUnavailable
        #endif
    }

    private static func pngChunks(_ data: Data) throws -> [PNGChunk] {
        guard data.count <= maximumPNGBytes else { throw CardError.tooLarge("PNG") }
        guard data.starts(with: signature) else { throw CardError.invalidPNG("signature") }
        // Rebase slices so all binary offsets below are relative to zero.
        let bytes = [UInt8](data)
        var offset = 8, chunks: [PNGChunk] = []
        while offset < bytes.count {
            guard chunks.count < 8_192 else { throw CardError.tooLarge("PNG chunk count") }
            guard bytes.count - offset >= 12 else { throw CardError.invalidPNG("truncated chunk") }
            let length = Int(uint32(bytes, offset))
            guard length <= bytes.count - offset - 12 else { throw CardError.invalidPNG("chunk length") }
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  let type = String(bytes: typeBytes, encoding: .ascii) else { throw CardError.invalidPNG("chunk type") }
            let end = offset + 8 + length
            guard crc32(bytes[(offset + 4)..<end]) == uint32(bytes, end) else { throw CardError.invalidPNG("checksum") }
            chunks.append(PNGChunk(type: type, data: Data(bytes[(offset + 8)..<end])))
            offset = end + 4
            if type == "IEND" { break }
        }
        guard offset == bytes.count, let header = chunks.first, header.type == "IHDR", header.data.count == 13,
              chunks.filter({ $0.type == "IHDR" }).count == 1,
              chunks.last?.type == "IEND", chunks.last?.data.isEmpty == true,
              chunks.contains(where: { $0.type == "IDAT" }) else { throw CardError.invalidPNG("incomplete image structure") }
        let h = [UInt8](header.data), width = UInt64(uint32([UInt8](header.data), 0)), height = UInt64(uint32([UInt8](header.data), 4))
        let depths: [UInt8: [UInt8]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard width > 0, height > 0, width * height <= 64_000_000,
              depths[h[9]]?.contains(h[8]) == true, h[10] == 0, h[11] == 0, h[12] <= 1 else { throw CardError.invalidPNG("image dimensions or header") }
        return chunks
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }

    private static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }

    private static func appendChunk(_ chunk: PNGChunk, to output: inout Data) throws {
        guard output.count + chunk.data.count + 12 <= maximumPNGBytes else { throw CardError.tooLarge("PNG export; try JSON export") }
        func appendInteger(_ value: UInt32) {
            output.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
        }
        let typeAndData = Data(chunk.type.utf8) + chunk.data
        appendInteger(UInt32(chunk.data.count))
        output.append(typeAndData)
        appendInteger(crc32(typeAndData))
    }

    private static func defaultPNG() throws -> Data {
        var png = signature
        try appendChunk(PNGChunk(type: "IHDR", data: Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])), to: &png)
        // A zlib stored block containing one transparent RGBA scanline (filter byte + 4 channels).
        try appendChunk(PNGChunk(type: "IDAT", data: Data([0x78, 0x01, 0x01, 5, 0, 250, 255, 0, 0, 0, 0, 0, 0, 5, 0, 1])), to: &png)
        try appendChunk(PNGChunk(type: "IEND", data: Data()), to: &png)
        return png
    }
}
