import Foundation

/// Retained JSON is archival data, not a claim that iOS can execute Android-only features.
/// Keep integer tokens as integers (Android timestamps and IDs must not pass through Double).
public enum BackupJSONValue: Codable, Equatable {
    case string(String), number(Double), integer(Int64), unsignedInteger(UInt64)
    case bool(Bool), object([String: BackupJSONValue]), array([BackupJSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsignedInteger(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: BackupJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([BackupJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsignedInteger(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var objectValue: [String: BackupJSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [BackupJSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var intValue: Int? {
        switch self {
        case .integer(let v): return Int(exactly: v)
        case .unsignedInteger(let v): return Int(exactly: v)
        case .number(let v): return Int(exactly: v)
        default: return nil
        }
    }
}

public struct PilotAIBackupPayload: Codable, Equatable {
    public var format: String
    public var schemaVersion: Int
    public var exportedAt: Int64
    public var providers: [ModelProvider]?
    /// In-memory selections use API model IDs. Android wire selections use database row IDs.
    public var selectedProviderId: String?
    public var selectedModelId: String?
    public var conversations: [Conversation]?
    public var memoryMd: String?
    public var characters: [Character]?
    public var skills: [Skill]?
    public var memory: MemoryDocument?
    public var mcpServers: [McpServer]?
    public var settings: AppSettings?
    public var rawDocument: Data?
    public var roleplay: BackupJSONValue?
    public var rawProviders: BackupJSONValue?
    public var rawConversations: BackupJSONValue?
    public var rawMessages: BackupJSONValue?
    public var extraFields: [String: BackupJSONValue]
    public var importWarnings: [String]

    public init(format: String = "eta-backup", schemaVersion: Int = 2,
                exportedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                providers: [ModelProvider]? = nil, selectedProviderId: String? = nil,
                selectedModelId: String? = nil, conversations: [Conversation]? = nil,
                memoryMd: String? = nil, characters: [Character]? = nil,
                skills: [Skill]? = nil, memory: MemoryDocument? = nil,
                roleplay: BackupJSONValue? = nil, rawProviders: BackupJSONValue? = nil,
                rawConversations: BackupJSONValue? = nil, extraFields: [String: BackupJSONValue] = [:],
                rawDocument: Data? = nil, mcpServers: [McpServer]? = nil, settings: AppSettings? = nil,
                rawMessages: BackupJSONValue? = nil, importWarnings: [String] = []) {
        self.format = format; self.schemaVersion = schemaVersion; self.exportedAt = exportedAt
        self.providers = providers; self.selectedProviderId = selectedProviderId; self.selectedModelId = selectedModelId
        self.conversations = conversations; self.memoryMd = memoryMd; self.characters = characters
        self.skills = skills; self.memory = memory; self.roleplay = roleplay; self.rawProviders = rawProviders
        self.rawConversations = rawConversations; self.extraFields = extraFields; self.rawDocument = rawDocument
        self.mcpServers = mcpServers; self.settings = settings; self.rawMessages = rawMessages
        self.importWarnings = importWarnings
    }

    public init(from decoder: Decoder) throws {
        self = try AndroidBackupCodec.decode(BackupJSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try AndroidBackupCodec.encode(self).encode(to: encoder)
    }
}

public final class BackupService {
    public static let shared = BackupService()
    public static let maxBackupBytes = 64 * 1024 * 1024
    public init() {}

    /// `ios` is an optional, versioned extension; Android ignores it. Existing callers may omit it.
    public func exportBackup(providers: [ModelProvider], conversations: [Conversation], memory: MemoryDocument,
                             characters: [Character], selectedProviderId: String, selectedModelId: String,
                             skills: [Skill] = [], preserving: PilotAIBackupPayload? = nil,
                             mcpServers: [McpServer]? = nil, settings: AppSettings? = nil) throws -> Data {
        var payload = PilotAIBackupPayload(providers: providers, selectedProviderId: selectedProviderId,
            selectedModelId: selectedModelId, conversations: conversations, memoryMd: memory.markdown,
            characters: characters, skills: skills, memory: memory, mcpServers: mcpServers, settings: settings)
        if let preserving {
            payload.roleplay = preserving.roleplay; payload.extraFields = preserving.extraFields
            payload.rawProviders = preserving.rawProviders; payload.rawConversations = preserving.rawConversations
            payload.rawMessages = preserving.rawMessages
            // A checkpoint/revision describes a particular transcript. Do not replay stale context
            // after a locally edited transcript or character binding is exported back to Android.
            let old = Dictionary((preserving.conversations ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let changed = Set(conversations.filter { old[$0.id]?.messages != $0.messages || old[$0.id]?.characterId != $0.characterId }.map(\.id))
            if let rows = payload.extraFields["contextCheckpoints"]?.arrayValue {
                payload.extraFields["contextCheckpoints"] = .array(rows.filter { !changed.contains($0.objectValue?["conversationId"]?.stringValue ?? "") })
            }
            if let rows = payload.rawConversations?.arrayValue {
                payload.rawConversations = .array(rows.map { value in
                    guard var row = value.objectValue, changed.contains(row["id"]?.stringValue ?? "") else { return value }
                    row["historyJson"] = .string("[]"); row["revisionsJson"] = .string("")
                    return .object(row)
                })
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maxBackupBytes else { throw BackupError.tooLarge }
        _ = try importBackup(data: data) // Validate referential integrity and Android limits before sharing.
        return data
    }

    public func importBackup(from url: URL) throws -> PilotAIBackupPayload {
        try importBackup(data: BoundedDataReader.read(url, limit: Self.maxBackupBytes))
    }

    public func importBackup(data: Data) throws -> PilotAIBackupPayload {
        guard data.count <= Self.maxBackupBytes else { throw BackupError.tooLarge }
        do {
            var payload = try JSONDecoder().decode(PilotAIBackupPayload.self, from: data)
            payload.rawDocument = data
            return payload
        } catch let error as BackupError { throw error }
        catch { throw BackupError.invalid("Invalid backup: \(error.localizedDescription)") }
    }

    public enum BackupError: LocalizedError {
        case tooLarge, invalid(String)
        public var errorDescription: String? {
            switch self { case .tooLarge: return "Backup file exceeds 64 MiB"; case .invalid(let message): return message }
        }
    }
}

/// Bound allocation while reading, including files whose reported size changes during the read.
public enum BoundedDataReader {
    public static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, limit - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw BackupService.BackupError.invalid("File exceeds the \(limit)-byte limit") }
            data.append(chunk)
        }
        return data
    }
}

private enum AndroidBackupCodec {
    typealias Value = BackupJSONValue
    typealias Object = [String: Value]
    static func invalid(_ message: String) -> BackupService.BackupError { .invalid(message) }
    static func object(_ value: Value, _ label: String) throws -> Object {
        guard let object = value.objectValue else { throw invalid("\(label) must be an object") }; return object
    }
    static func rows(_ value: Value?, _ label: String) throws -> [Object] {
        guard let value, value != .null else { return [] }
        guard let values = value.arrayValue else { throw invalid("\(label) must be an array") }
        return try values.map { try object($0, label) }
    }
    static func text(_ row: Object, _ key: String) -> String { row[key]?.stringValue ?? "" }
    static func required(_ row: Object, _ key: String) throws -> String {
        let value = text(row, key)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Missing or blank \(key)") }
        return value
    }
    static func unique(_ values: [String], _ label: String) throws {
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(values).count == values.count else {
            throw invalid("Duplicate or blank \(label) IDs")
        }
    }
    static func jsonString(_ value: Value) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func json(_ text: String) throws -> Value { try JSONDecoder().decode(Value.self, from: Data(text.utf8)) }
    static func nativeValue<T: Encodable>(_ model: T) throws -> Value {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return try JSONDecoder().decode(Value.self, from: encoder.encode(model))
    }
    static func native<T: Decodable>(_ value: Value?, as: T.Type, milliseconds: Bool = true) throws -> T? {
        guard let value, value != .null else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let string = try? c.decode(String.self) {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: string) { return date }
                throw invalid("Invalid ISO-8601 date")
            }
            let number = try c.decode(Double.self)
            guard number.isFinite else { throw invalid("Invalid date") }
            if milliseconds || abs(number) >= 100_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            // Pre-extension iOS exports used JSONEncoder's seconds-since-2001 strategy.
            return Date(timeIntervalSinceReferenceDate: number)
        }
        return try decoder.decode(T.self, from: JSONEncoder().encode(value))
    }
    static func date(_ row: Object, _ key: String) throws -> Date {
        guard let number = row[key]?.intValue else { throw invalid("\(key) must be Unix milliseconds") }
        return Date(timeIntervalSince1970: Double(number) / 1000)
    }
    static func millis(_ date: Date) throws -> Value {
        guard let number = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.towardZero)) else { throw invalid("Date is outside the backup range") }
        return .integer(number)
    }

    static func decode(_ value: Value) throws -> PilotAIBackupPayload {
        try checkDepth(value, depth: 0)
        let root = try object(value, "Backup")
        let format = try required(root, "format")
        guard ["eta-backup", "pilotai-backup"].contains(format) else { throw invalid("Unsupported backup format") }
        guard root["schemaVersion"] == nil || root["schemaVersion"]?.intValue != nil,
              root["exportedAt"] == nil || root["exportedAt"]?.intValue != nil else { throw invalid("Backup version and timestamp must be integers") }
        let version = root["schemaVersion"]?.intValue ?? 1
        guard (1...2).contains(version) else { throw invalid("Unsupported backup schema version") }
        let exported = Int64(root["exportedAt"]?.intValue ?? 0)
        let ios = root["ios"]?.objectValue ?? [:]
        if let version = ios["version"]?.intValue, version != 1 { throw invalid("Unsupported iOS backup extension version") }
        var p = PilotAIBackupPayload(format: format, schemaVersion: version, exportedAt: exported,
            selectedProviderId: root["selectedProviderId"]?.stringValue, selectedModelId: root["selectedModelId"]?.stringValue)
        let known = Set(["format", "schemaVersion", "exportedAt", "providers", "selectedProviderId", "selectedModelId", "conversations", "messages", "memoryMd", "characters", "skills", "memory", "roleplay"])
        p.extraFields = root.filter { !known.contains($0.key) }
        p.memoryMd = root["memoryMd"]?.stringValue
        guard (p.memoryMd?.utf8.count ?? 0) <= 1024 * 1024 else { throw invalid("MEMORY.md exceeds 1 MiB") }
        p.memory = try native(ios["memory"] ?? root["memory"], as: MemoryDocument.self, milliseconds: ios["memory"] != nil)
        guard (p.memory?.markdown.utf8.count ?? 0) <= 1024 * 1024 else { throw invalid("iOS memory exceeds 1 MiB") }
        p.skills = try native(ios["skills"] ?? root["skills"], as: [Skill].self)
        p.mcpServers = try native(ios["mcpServers"], as: [McpServer].self)
        p.settings = try native(ios["settings"], as: AppSettings.self)
        if let skills = p.skills { try unique(skills.map(\.id), "skill"); try skills.forEach(SkillDocumentParser.validate) }
        if let servers = p.mcpServers { try unique(servers.map(\.id), "MCP server") }

        if let providerValue = root["providers"], providerValue != .null {
            let providerRows = try rows(providerValue, "providers")
            let isAndroid = providerRows.isEmpty || providerRows.first?["provider"] != nil
            if isAndroid {
                p.rawProviders = providerValue
                var allModelRowIDs: [String] = []
                p.providers = try providerRows.map { row in
                    let source = try object(row["provider"] ?? .null, "provider")
                    let id = try required(source, "id")
                    let models = try rows(row["models"], "models")
                    var mapped: [ModelDefinition] = []
                    for model in models {
                        let rowID = try required(model, "id"); allModelRowIDs.append(rowID)
                        guard text(model, "providerId") == id else { throw invalid("Model does not belong to its provider") }
                        let modelID = try required(model, "modelId")
                        if rowID == p.selectedModelId {
                            guard p.selectedProviderId == id else { throw invalid("Selected model does not belong to selected provider") }
                            // Do this after the loop below; two wire IDs must never be confused with API IDs.
                        }
                        if model["isEnabled"]?.boolValue == false {
                            p.importWarnings.append("Disabled Android model rows are retained for re-export and excluded from iOS model choices."); continue
                        }
                        guard !mapped.contains(where: { $0.id == modelID }) else {
                            p.importWarnings.append("Duplicate API model configurations are retained only for re-export."); continue
                        }
                        mapped.append(ModelDefinition(id: modelID, name: text(model, "displayName").isEmpty ? modelID : text(model, "displayName"),
                            supportsVision: model["attachment"]?.boolValue ?? false,
                            supportsReasoning: model["reasoningOverride"]?.boolValue ?? model["reasoning"]?.boolValue ?? false,
                            contextWindow: model["contextWindow"]?.intValue ?? 128_000,
                            contextWindowOverride: model["contextWindowOverride"]?.intValue, sortOrder: model["sortOrder"]?.intValue ?? 0))
                    }
                    mapped.sort { $0.sortOrder < $1.sortOrder }
                    let type = ProviderType(rawValue: text(source, "type")) ?? (text(source, "type") == "openai_compatible" ? .openai : .custom)
                    let headerRows = try rows(try json(source["customHeadersJson"]?.stringValue ?? "[]"), "custom headers")
                    let headers = headerRows.enumerated().map { offset, h in CustomHeader(id: "\(id)-header-\(offset)", key: text(h, "name"), value: text(h, "value")) }
                    var body: Object = [:]
                    for item in try rows(try json(source["customBodyJson"]?.stringValue ?? "[]"), "custom body") {
                        body[try required(item, "key")] = item["value"] ?? .null
                    }
                    let selected = models.first { text($0, "id") == p.selectedModelId }.map { text($0, "modelId") }
                    return ModelProvider(id: id, name: try required(source, "name"), type: type,
                        baseURL: source["baseUrl"]?.stringValue, apiKey: text(source, "apiKey"),
                        defaultModelId: selected ?? mapped.first?.id ?? "", models: mapped, customHeaders: headers,
                        isEnabled: source["isEnabled"]?.boolValue ?? true, isBuiltIn: source["isBuiltIn"]?.boolValue ?? false,
                        systemPrompt: text(source, "systemPrompt"), endpointMode: source["endpointMode"]?.stringValue ?? "chat_completions",
                        hostedWebSearchEnabled: source["hostedWebSearchEnabled"]?.boolValue ?? false,
                        anthropicVersion: source["anthropicVersion"]?.stringValue ?? "2023-06-01",
                        customRequestBodyJSON: body.isEmpty ? "" : try jsonString(.object(body)))
                }
                if providerRows.contains(where: { row in
                    (row["models"]?.arrayValue ?? []).contains { model in
                        let m = model.objectValue ?? [:]
                        return !["", "[]"].contains(text(m, "customHeadersJson")) || !["", "[]"].contains(text(m, "customBodyJson"))
                    }
                }) { p.importWarnings.append("Per-model Android request overrides are retained for re-export; iOS uses provider-level request settings.") }
                try unique(allModelRowIDs, "model row")
                if let selected = p.selectedModelId {
                    let models = try providerRows.flatMap { try rows($0["models"], "models") }
                    guard let model = models.first(where: { text($0, "id") == selected }) else { throw invalid("Selected model is absent") }
                    p.selectedModelId = text(model, "modelId")
                }
            } else { p.providers = try native(providerValue, as: [ModelProvider].self, milliseconds: false) }
            try unique((p.providers ?? []).map(\.id), "provider")
            if let selected = p.selectedProviderId, !(p.providers ?? []).contains(where: { $0.id == selected }) { throw invalid("Selected provider is absent") }
        }
        // Native snapshots retain iOS-only provider choices without changing Android's wire type.
        if let nativeProviders = try native(ios["providers"], as: [ModelProvider].self) {
            if let mapped = p.providers, Set(mapped.map(\.id)) != Set(nativeProviders.map(\.id)) { throw invalid("iOS provider IDs do not match Android rows") }
            p.providers = nativeProviders
        }
        try unique((p.providers ?? []).map(\.id), "provider")

        p.roleplay = root["roleplay"] == .null ? nil : root["roleplay"]
        if let roleplay = p.roleplay {
            let source = try object(roleplay, "roleplay")
            p.characters = try rows(source["characters"], "characters").map { row in
                try character(card: required(row, "cardJson"), id: required(row, "id"))
            }
            try unique((p.characters ?? []).map(\.id), "character")
            let assets = try rows(source["assets"], "assets")
            try unique(try assets.map { try required($0, "characterId") }, "character asset")
            for asset in assets {
                guard text(asset, "memoryMd").utf8.count <= 1024 * 1024 else { throw invalid("Character memory exceeds 1 MiB") }
                if let encoded = asset["avatarBase64"]?.stringValue { _ = try png(encoded) }
            }
            if let persona = source["persona"]?.objectValue {
                guard text(persona, "id") == "main", !text(persona, "name").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text(persona, "name").count <= 256, text(persona, "description").utf8.count <= 1024 * 1024 else { throw invalid("Invalid Android user persona") }
            }
        }
        if let nativeCharacters = try native(ios["characters"] ?? root["characters"], as: [Character].self) { p.characters = nativeCharacters }
        try unique((p.characters ?? []).map(\.id), "character")

        if let conversationValue = root["conversations"], conversationValue != .null {
            let conversationRows = try rows(conversationValue, "conversations")
            let android = conversationRows.isEmpty || conversationRows.first?["messages"] == nil
            if android {
                p.rawConversations = conversationValue; p.rawMessages = root["messages"] ?? .array([])
                let messages = try rows(p.rawMessages, "messages")
                try unique(try conversationRows.map { try required($0, "id") }, "conversation")
                try unique(try messages.map { try required($0, "id") }, "message")
                let ids = Set(conversationRows.map { text($0, "id") })
                var positions = Set<String>()
                for message in messages {
                    let owner = try required(message, "conversationId")
                    guard ids.contains(owner), let position = message["sortIndex"]?.intValue, position >= 0,
                          positions.insert("\(owner.utf8.count):\(owner):\(position)").inserted else { throw invalid("Invalid message owner or duplicate ordering") }
                }
                let grouped = Dictionary(grouping: messages, by: { text($0, "conversationId") })
                p.conversations = try conversationRows.map { row in
                    let id = try required(row, "id"); let created = try date(row, "createdAt")
                    let binding = try text(row, "roleplayJson").isEmpty ? nil : object(json(text(row, "roleplayJson")), "roleplay binding")
                    let characterID = binding?["characterId"]?.stringValue
                    if let binding {
                        _ = try character(card: required(binding, "cardSnapshotJson"), id: required(binding, "characterId"))
                        guard text(binding, "userName").count <= 256, text(binding, "userDescription").utf8.count <= 1024 * 1024 else { throw invalid("Roleplay persona exceeds Android limits") }
                        p.importWarnings.append("Session-specific character snapshots and personas are retained for Android re-export; iOS roleplay uses the character library.")
                    }
                    if let binding, let characterID, !(p.characters ?? []).contains(where: { $0.id == characterID }) {
                        let snapshot = try character(card: required(binding, "cardSnapshotJson"), id: characterID)
                        p.characters = (p.characters ?? []) + [snapshot]
                    }
                    var mapped: [Message] = []
                    try validateRevisions(text(row, "revisionsJson"), messages: grouped[id] ?? [])
                    for message in (grouped[id] ?? []).sorted(by: { ($0["sortIndex"]?.intValue ?? 0) < ($1["sortIndex"]?.intValue ?? 0) }) {
                        let type = try required(message, "type"); let content = text(message, "content")
                        let messageID = try required(message, "id")
                        switch type {
                        case "user", "assistant": mapped.append(Message(id: messageID, role: type == "user" ? .user : .assistant, content: content, timestamp: created))
                        // These are Android UI events, not valid protocol tool-result/system
                        // messages. Installing them as such would break future model requests.
                        default: p.importWarnings.append("Android message type '\(type.prefix(80))' is retained for re-export and is not shown in iOS.")
                        }
                    }
                    return Conversation(id: id, title: text(row, "title"), messages: mapped,
                        providerId: p.selectedProviderId ?? "", modelId: p.selectedModelId ?? "",
                        mode: characterID == nil ? .agent : .roleplay, characterId: characterID,
                        createdAt: created, updatedAt: try date(row, "updatedAt"))
                }
                let checkpoints = try rows(root["contextCheckpoints"], "context checkpoints")
                try unique(try checkpoints.map { try required($0, "conversationId") }, "checkpoint")
                guard checkpoints.allSatisfy({ ids.contains(text($0, "conversationId")) }) else { throw invalid("Checkpoint has no conversation") }
                if let state = root["conversationState"]?.objectValue {
                    guard text(state, "id") == "main", ids.contains(text(state, "selectedConversationId")) else { throw invalid("Invalid conversation selection") }
                }
                if !messages.isEmpty { p.importWarnings.append("Android messages have no timestamps; iOS uses the conversation creation date. Android image paths, tool summaries, revisions, and checkpoints remain archival only.") }
            } else { p.conversations = try native(conversationValue, as: [Conversation].self, milliseconds: false) }
        }
        if let nativeConversations = try native(ios["conversations"], as: [Conversation].self) {
            if let mapped = p.conversations, Set(mapped.map(\.id)) != Set(nativeConversations.map(\.id)) { throw invalid("iOS conversation IDs do not match Android rows") }
            p.conversations = nativeConversations
        }
        try unique((p.conversations ?? []).map(\.id), "conversation")
        try unique((p.conversations ?? []).flatMap { $0.messages.map(\.id) }, "message")
        if let roleplay = p.roleplay?.objectValue {
            let assets = try rows(roleplay["assets"], "assets")
            let characterIDs = Set((p.characters ?? []).map(\.id))
            guard assets.allSatisfy({ characterIDs.contains(text($0, "characterId")) }) else { throw invalid("Character asset has no character or snapshot") }
            // Native snapshots already contain current local story memory and persona edits.
            if ios["characters"] == nil, var characters = p.characters {
                let persona = roleplay["persona"]?.objectValue ?? [:]
                for index in characters.indices {
                    characters[index].userPersonaName = text(persona, "name")
                    characters[index].userPersonaDescription = text(persona, "description")
                    if let asset = assets.first(where: { text($0, "characterId") == characters[index].id }) {
                        characters[index].storyMemory = text(asset, "memoryMd")
                        characters[index].originalPNG = try asset["avatarBase64"]?.stringValue.map(png)
                    }
                }
                p.characters = characters
            }
        }
        p.importWarnings = Array(Set(p.importWarnings)).sorted()
        return p
    }

    static func encode(_ p: PilotAIBackupPayload) throws -> Value {
        var root = p.extraFields
        root["format"] = .string(p.format); root["schemaVersion"] = .integer(Int64(p.schemaVersion)); root["exportedAt"] = .integer(p.exportedAt)
        root["selectedProviderId"] = p.selectedProviderId.map(Value.string) ?? .null
        root["selectedModelId"] = .null
        root["memoryMd"] = .string(p.memoryMd ?? p.memory?.markdown ?? "")
        var ios = root["ios"]?.objectValue ?? [:]
        ios["version"] = .integer(1); ios["dateEncoding"] = .string("millisecondsSince1970")
        if let memory = p.memory { ios["memory"] = try nativeValue(memory) }
        if let skills = p.skills { ios["skills"] = try nativeValue(skills) }
        if let servers = p.mcpServers { ios["mcpServers"] = try nativeValue(servers) }
        if let settings = p.settings { ios["settings"] = try nativeValue(settings) }
        if let characters = p.characters { ios["characters"] = try nativeValue(characters) }
        if let providers = p.providers {
            ios["providers"] = try nativeValue(providers)
            let oldRows = try rows(p.rawProviders, "providers")
            var providerRows: [Value] = []
            for (index, provider) in providers.enumerated() {
                var row = oldRows.first { $0["provider"]?.objectValue?["id"]?.stringValue == provider.id } ?? [:]
                var source = row["provider"]?.objectValue ?? [:]
                source["id"] = .string(provider.id); source["name"] = .string(provider.name)
                source["type"] = source["type"] ?? .string(provider.type == .anthropic ? "anthropic" : provider.type == .custom ? "custom" : "openai_compatible")
                source["baseUrl"] = .string(provider.baseURL); source["apiKey"] = .string(provider.apiKey)
                source["isEnabled"] = .bool(provider.isEnabled); source["isBuiltIn"] = .bool(provider.isBuiltIn)
                source["sortOrder"] = .integer(Int64(index)); source["createdAt"] = source["createdAt"] ?? .integer(p.exportedAt)
                source["systemPrompt"] = .string(provider.systemPrompt); source["endpointMode"] = .string(provider.endpointMode)
                source["hostedWebSearchEnabled"] = .bool(provider.hostedWebSearchEnabled); source["anthropicVersion"] = .string(provider.anthropicVersion)
                let oldHeaders = try rows(try json(source["customHeadersJson"]?.stringValue ?? "[]"), "custom headers")
                source["customHeadersJson"] = .string(try jsonString(.array(provider.customHeaders.enumerated().map { index, header in
                    var item = oldHeaders.indices.contains(index) && text(oldHeaders[index], "name") == header.key ? oldHeaders[index] : oldHeaders.first { text($0, "name") == header.key } ?? [:]
                    item["name"] = .string(header.key); item["value"] = .string(header.value); return .object(item)
                })))
                let oldBody = try rows(try json(source["customBodyJson"]?.stringValue ?? "[]"), "custom body")
                let body = try provider.customRequestBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [:] : object(json(provider.customRequestBodyJSON), "custom request body")
                source["customBodyJson"] = .string(try jsonString(.array(body.keys.sorted().map { key in
                    var item = oldBody.first { text($0, "key") == key } ?? [:]
                    item["key"] = .string(key); item["value"] = body[key]; return .object(item)
                })))
                let previousModels = try rows(row["models"], "models")
                var models: [Object] = []
                for model in provider.models {
                    var m = previousModels.first { text($0, "modelId") == model.id && $0["isEnabled"]?.boolValue != false } ?? [:]
                    m["id"] = m["id"] ?? .string("ios-model:\(provider.id.utf8.count):\(provider.id):\(model.id)")
                    m["providerId"] = .string(provider.id); m["modelId"] = .string(model.id); m["displayName"] = .string(model.name)
                    m["isEnabled"] = .bool(true); m["isBuiltIn"] = m["isBuiltIn"] ?? .bool(provider.isBuiltIn)
                    m["sortOrder"] = .integer(Int64(model.sortOrder)); m["contextWindow"] = .integer(Int64(model.contextWindow))
                    m["contextWindowOverride"] = model.contextWindowOverride.map { .integer(Int64($0)) } ?? .null
                    m["attachment"] = .bool(model.supportsVision); m["reasoning"] = .bool(model.supportsReasoning)
                    for key in ["ownedBy", "toolCall", "reasoningOverride", "structuredOutput", "supportsTemperature"] { m[key] = m[key] ?? .null }
                    for key in ["customHeadersJson", "customBodyJson"] { m[key] = m[key] ?? .string("[]") }
                    for key in ["reasoningCapabilitiesJson", "reasoningCapabilitiesOverrideJson"] { m[key] = m[key] ?? .string("null") }
                    m["inputModalitiesJson"] = m["inputModalitiesJson"] ?? .string(model.supportsVision ? "[\"text\",\"image\"]" : "[\"text\"]")
                    m["outputModalitiesJson"] = m["outputModalitiesJson"] ?? .string("[\"text\"]")
                    m["source"] = m["source"] ?? .string("manual"); m["createdAt"] = m["createdAt"] ?? .integer(p.exportedAt)
                    if provider.id == p.selectedProviderId && model.id == p.selectedModelId { root["selectedModelId"] = m["id"] }
                    models.append(m)
                }
                // Disabled models and duplicate configurations are not editable in iOS; retain them.
                let emitted = Set(models.map { text($0, "id") })
                let mappedAPIIDs = Set(models.map { text($0, "modelId") })
                models += previousModels.filter { !emitted.contains(text($0, "id")) && ($0["isEnabled"]?.boolValue == false || mappedAPIIDs.contains(text($0, "modelId"))) }
                row["provider"] = .object(source); row["models"] = .array(models.map(Value.object)); providerRows.append(.object(row))
            }
            root["providers"] = .array(providerRows)
            if !providers.contains(where: { $0.id == p.selectedProviderId }) { root["selectedProviderId"] = .null }
        } else if let raw = p.rawProviders { root["providers"] = raw }

        var roleplay = p.roleplay?.objectValue ?? [:]
        if let characters = p.characters {
            let oldCharacters = try rows(roleplay["characters"], "characters")
            roleplay["characters"] = .array(try characters.map { character in
                guard character.id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw invalid("Character ID is not Android-compatible") }
                var row = oldCharacters.first { text($0, "id") == character.id } ?? [:]
                row["id"] = .string(character.id); row["name"] = .string(character.name); row["cardJson"] = .string(try card(character))
                row["avatarPath"] = .null; row["archived"] = row["archived"] ?? .bool(false)
                row["createdAt"] = row["createdAt"] ?? .integer(p.exportedAt); row["updatedAt"] = row["updatedAt"] ?? .integer(p.exportedAt)
                return .object(row)
            })
        }
        if let conversations = p.conversations {
            ios["conversations"] = try nativeValue(conversations)
            let oldConversations = try rows(p.rawConversations, "conversations")
            let oldMessages = try rows(p.rawMessages, "messages")
            let oldMessageMap = Dictionary(oldMessages.map { (text($0, "id"), $0) }, uniquingKeysWith: { a, _ in a })
            var messages: [Value] = []
            root["conversations"] = .array(try conversations.map { conversation in
                var row = oldConversations.first { text($0, "id") == conversation.id } ?? [:]
                row["id"] = .string(conversation.id); row["title"] = .string(conversation.title)
                row["createdAt"] = try millis(conversation.createdAt); row["updatedAt"] = try millis(conversation.updatedAt)
                row["thinkingEnabled"] = row["thinkingEnabled"] ?? .bool(false)
                row["reasoningEffort"] = row["reasoningEffort"] ?? .string("default")
                row["historyJson"] = row["historyJson"] ?? .string("[]"); row["appliedRuntimeRunIdsJson"] = row["appliedRuntimeRunIdsJson"] ?? .string("[]")
                row["revisionsJson"] = row["revisionsJson"] ?? .string("")
                if conversation.mode == .roleplay, let id = conversation.characterId {
                    var binding = try text(row, "roleplayJson").isEmpty ? [:] : object(json(text(row, "roleplayJson")), "binding")
                    if text(binding, "characterId") != id || text(binding, "cardSnapshotJson").isEmpty {
                        guard let character = p.characters?.first(where: { $0.id == id }) else { throw invalid("Roleplay conversation has no character card") }
                        binding = ["characterId": .string(id), "characterName": .string(character.name), "cardSnapshotJson": .string(try card(character)),
                            "userName": .string(character.userPersonaName.isEmpty ? "User" : character.userPersonaName), "userDescription": .string(character.userPersonaDescription)]
                    }
                    binding["avatarPath"] = .null; row["roleplayJson"] = .string(try jsonString(.object(binding)))
                } else { row["roleplayJson"] = .string("") }
                var mapped: [Object] = []
                for message in conversation.messages {
                    var m = oldMessageMap[message.id] ?? [:]
                    let oldType = text(m, "type")
                    m["id"] = .string(message.id); m["conversationId"] = .string(conversation.id)
                    if oldType == "thinking" { m["content"] = .string(message.reasoningContent ?? message.content) }
                    else if oldType == "tool" || oldType == "system_notice" { m["resultSummary"] = .string(message.content) }
                    else {
                        // Android has no arbitrary system-message row; iOS keeps the exact role in ios.conversations.
                        m["type"] = .string(message.role == .system ? "assistant" : message.role.rawValue)
                        m["content"] = .string(message.content)
                    }
                    m["imagesJson"] = m["imagesJson"] ?? .string("[]"); m["isEdited"] = m["isEdited"] ?? .bool(false)
                    m["toolsJson"] = m["toolsJson"] ?? .string("[]"); m["imageCount"] = m["imageCount"] ?? .integer(0)
                    mapped.append(m)
                }
                let supported = Set(["user", "assistant"])
                let mappedIDs = Set(mapped.map { text($0, "id") })
                for m in oldMessages.filter({ text($0, "conversationId") == conversation.id && !supported.contains(text($0, "type")) && !mappedIDs.contains(text($0, "id")) }).sorted(by: { ($0["sortIndex"]?.intValue ?? 0) < ($1["sortIndex"]?.intValue ?? 0) }) {
                    mapped.insert(m, at: min(max(0, m["sortIndex"]?.intValue ?? mapped.count), mapped.count))
                }
                messages += mapped.enumerated().map { index, value in var value = value; value["sortIndex"] = .integer(Int64(index)); return .object(value) }
                return .object(row)
            })
            root["messages"] = .array(messages)
            let ids = Set(conversations.map(\.id))
            root["contextCheckpoints"] = .array(try rows(root["contextCheckpoints"], "checkpoints").filter { ids.contains(text($0, "conversationId")) }.map(Value.object))
            if let state = root["conversationState"]?.objectValue, ids.contains(text(state, "selectedConversationId")) { }
            else { root["conversationState"] = conversations.first.map { .object(["id": .string("main"), "selectedConversationId": .string($0.id)]) } ?? .null }
        }
        if !roleplay.isEmpty {
            roleplay["characters"] = roleplay["characters"] ?? .array([])
            roleplay["persona"] = roleplay["persona"] ?? .null
            let ids = Set((p.characters ?? []).map(\.id) + (p.conversations ?? []).compactMap(\.characterId))
            if let characters = p.characters {
                var assets = try rows(roleplay["assets"], "assets").filter { ids.contains(text($0, "characterId")) }
                for character in characters {
                    var asset = assets.first { text($0, "characterId") == character.id } ?? [:]
                    asset["characterId"] = .string(character.id); asset["memoryMd"] = .string(character.storyMemory)
                    asset["avatarBase64"] = character.originalPNG.map { .string($0.base64EncodedString()) } ?? .null
                    assets.removeAll { text($0, "characterId") == character.id }; assets.append(asset)
                }
                roleplay["assets"] = .array(assets.map(Value.object))
            }
            roleplay["assets"] = roleplay["assets"] ?? .array([])
            root["roleplay"] = .object(roleplay)
        }
        root["ios"] = .object(ios)
        return .object(root)
    }

    static func character(card: String, id: String) throws -> Character {
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw invalid("Invalid Android character ID") }
        let character = try CharacterCardParser.importJSON(Data(card.utf8), id: id)
        guard character.name.count <= 512 else { throw invalid("Character name exceeds 512 characters") }
        return character
    }
    static func card(_ character: Character) throws -> String {
        String(decoding: try CharacterCardParser.exportJSON(for: character), as: UTF8.self)
    }
    static func validateRevisions(_ encoded: String, messages: [Object]) throws {
        guard !encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let state = try object(json(encoded), "roleplay revisions")
        let links = try object(state["links"] ?? .object([:]), "revision links")
        let revisions = try object(state["revisions"] ?? .object([:]), "revisions")
        let pending = try object(state["pendingRewrites"] ?? .object([:]), "pending rewrites")
        let types = Dictionary(messages.map { (text($0, "id"), text($0, "type")) }, uniquingKeysWith: { a, _ in a })
        for (id, value) in links {
            let link = try object(value, "revision link")
            guard ["user", "assistant"].contains(types[id] ?? ""), !text(link, "transcriptMessageId").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (link["blockOrder"]?.intValue ?? 0) >= 0 else { throw invalid("Invalid roleplay revision link") }
        }
        for (id, value) in revisions {
            let revision = try object(value, "revision")
            guard links[id] != nil, let candidates = revision["candidates"]?.arrayValue, !candidates.isEmpty,
                  candidates.allSatisfy({ $0.stringValue != nil }), let selected = revision["selected"]?.intValue,
                  candidates.indices.contains(selected) else { throw invalid("Invalid roleplay revision selection") }
        }
        for (runID, value) in pending {
            guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let target = value.stringValue,
                  links[target] != nil, types[target] == "assistant" else { throw invalid("Invalid pending roleplay rewrite") }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB88320 }
        return crc
    }
    /// Android assets may be ordinary PNG avatars with no card metadata. Validate the container
    /// without executing a codec or requiring a chara block (CharacterCardPng.validate parity).
    static func png(_ encoded: String) throws -> Data {
        guard let data = Data(base64Encoded: encoded), data.count <= 32 * 1024 * 1024,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw invalid("Invalid PNG avatar") }
        func number(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var offset = 8; var header = false; var image = false; var end = false
        while offset < data.count {
            guard data.count - offset >= 12 else { throw invalid("Truncated PNG avatar") }
            let size = Int(number(offset))
            guard size <= data.count - offset - 12 else { throw invalid("Invalid PNG avatar chunk length") }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data[(offset + 4)..<(offset + 8 + size)] { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
            guard crc ^ 0xFFFFFFFF == number(offset + 8 + size) else { throw invalid("PNG avatar checksum failed") }
            if type == "IHDR" {
                guard !header, offset == 8, size == 13 else { throw invalid("Invalid PNG avatar header") }
                let width = UInt64(number(offset + 8)); let height = UInt64(number(offset + 12))
                let depth = data[offset + 16]; let color = data[offset + 17]
                let depths: [UInt8] = color == 0 ? [1, 2, 4, 8, 16] : color == 3 ? [1, 2, 4, 8] : [2, 4, 6].contains(color) ? [8, 16] : []
                guard width > 0, height > 0, width <= 64_000_000, height <= 64_000_000, width * height <= 64_000_000,
                      depths.contains(depth), data[offset + 18] == 0, data[offset + 19] == 0, data[offset + 20] <= 1 else { throw invalid("Invalid PNG avatar dimensions or format") }
                header = true
            }
            if type == "IDAT" { image = true }
            offset += size + 12
            if type == "IEND" { guard size == 0 else { throw invalid("Invalid PNG avatar end") }; end = true; break }
        }
        guard header, image, end else { throw invalid("Incomplete PNG avatar") }
        return data
    }
    static func checkDepth(_ value: Value, depth: Int) throws {
        guard depth < 64 else { throw invalid("Backup JSON nesting exceeds 64 levels") }
        switch value {
        case .object(let v): for child in v.values { try checkDepth(child, depth: depth + 1) }
        case .array(let v): for child in v { try checkDepth(child, depth: depth + 1) }
        default: break
        }
    }
}
