import Foundation
import XCTest
@testable import PilotAI

final class StorageBackupSkillTests: XCTestCase {
    private final class Credentials: StorageCredentialStore {
        var records: [String: Data] = [:]
        var failWrites = false
        var failReads = false
        var corruptReadback = false
        func read(account: String) throws -> Data? {
            if failReads { throw StorageService.StorageError.credentials("locked") }
            if corruptReadback { return Data("corrupt".utf8) }
            return records[account]
        }
        func write(_ data: Data, account: String) throws {
            if failWrites { throw StorageService.StorageError.credentials("full") }
            records[account] = data
        }
    }

    private final class FailingFileManager: FileManager, @unchecked Sendable {
        var failDirectoryCreation = false
        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
            if failDirectoryCreation { throw CocoaError(.fileWriteOutOfSpace) }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilotai-data-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func provider() -> ModelProvider {
        ModelProvider(id: "p", name: "Provider", type: .custom, apiKey: "secret-key", defaultModelId: "api-model",
                      models: [ModelDefinition(id: "api-model", name: "API model", supportsVision: true, supportsReasoning: true, contextWindow: 100_000)],
                      customHeaders: [CustomHeader(id: "h", key: "Authorization", value: "secret-header")])
    }

    /// Field names/defaults copied from Android ProviderEntities.kt, ConversationEntities.kt,
    /// CharacterEntities.kt, CharacterBackupData.kt and EtaBackupRepository.kt (schema 2).
    private func androidFixture() throws -> [String: Any] {
        let card: [String: Any] = ["spec": "chara_card_v2", "spec_version": "2.0", "data": [
            "name": "Ada", "description": "description", "first_mes": "Hello", "personality": "Precise",
            "scenario": "A lab", "alternate_greetings": ["Hi"], "extensions": ["future": "kept"]
        ]]
        let cardJSON = String(decoding: try json(card), as: UTF8.self)
        let binding = String(decoding: try json(["characterId": "ada", "characterName": "Ada", "cardSnapshotJson": cardJSON, "userName": "Human", "userDescription": "persona"]), as: UTF8.self)
        let provider: [String: Any] = [
            "id": "p", "type": "openai_compatible", "name": "Endpoint", "baseUrl": "https://example.invalid/v1",
            "apiKey": "android-key", "isEnabled": true, "isBuiltIn": false, "sortOrder": 0,
            "systemPrompt": "system", "customHeadersJson": "[{\"name\":\"X-Token\",\"value\":\"header-secret\"}]",
            "customBodyJson": "[{\"key\":\"temperature\",\"value\":0.2}]", "createdAt": 1_700_000_000_000 as Int64,
            "endpointMode": "responses", "hostedWebSearchEnabled": true, "anthropicVersion": "2023-06-01",
            "futureProviderField": ["nested": true]
        ]
        let model: [String: Any] = [
            "id": "android-row-uuid", "providerId": "p", "modelId": "api-model", "displayName": "API Model",
            "isEnabled": true, "isBuiltIn": false, "sortOrder": 0, "ownedBy": NSNull(), "contextWindow": 150_000,
            "contextWindowOverride": 42_000, "inputModalitiesJson": "[\"text\",\"image\"]", "outputModalitiesJson": "[\"text\"]",
            "attachment": true, "toolCall": true, "reasoning": true, "reasoningOverride": NSNull(),
            "reasoningCapabilitiesJson": "null", "reasoningCapabilitiesOverrideJson": "null", "structuredOutput": true,
            "supportsTemperature": false, "customHeadersJson": "[]", "customBodyJson": "[]", "source": "manual",
            "createdAt": 1_700_000_000_000 as Int64, "futureModelField": "kept"
        ]
        let conversation: [String: Any] = [
            "id": "c", "title": "Android chat", "thinkingEnabled": true, "reasoningEffort": "high", "historyJson": "[]",
            "appliedRuntimeRunIdsJson": "[]", "roleplayJson": binding, "revisionsJson": "", "createdAt": 1_700_000_000_123 as Int64,
            "updatedAt": 1_700_000_002_456 as Int64, "futureConversationField": "kept"
        ]
        return [
            "format": "eta-backup", "schemaVersion": 2, "exportedAt": 1_700_000_010_000 as Int64,
            "providers": [["provider": provider, "models": [model], "futureRowField": "kept"]],
            "selectedProviderId": "p", "selectedModelId": "android-row-uuid", "conversations": [conversation],
            "messages": [
                ["id": "m2", "conversationId": "c", "sortIndex": 1, "type": "assistant", "content": "answer", "inputTokens": 200, "imagesJson": "[]", "futureMessageField": "kept"],
                ["id": "m1", "conversationId": "c", "sortIndex": 0, "type": "user", "content": "question", "imagesJson": "[]"],
                ["id": "summary", "conversationId": "c", "sortIndex": 2, "type": "tool_summary", "content": "", "toolsJson": "[\"search\"]"]
            ],
            "contextCheckpoints": [["conversationId": "c", "historyJson": "[]", "journalJson": "archival"]],
            "conversationState": ["id": "main", "selectedConversationId": "c"], "memoryMd": "# Android memory",
            "roleplay": ["characters": [["id": "ada", "name": "Ada", "cardJson": cardJSON, "archived": false, "createdAt": 1_700_000_000_000 as Int64, "updatedAt": 1_700_000_000_000 as Int64]],
                         "persona": ["id": "main", "name": "Human", "description": "persona"], "assets": [["characterId": "ada", "memoryMd": "character memory"]], "futureRoleplay": true],
            "futureRoot": ["value": "kept"], "largeInteger": Int64.max
        ]
    }

    func testSkillDecodingAliasesStillEncodesStoredFields() throws {
        let data = Data(#"{"id":"s","name":"skill","description":"d","bodyMarkdown":"body","enabled":false,"skillFilePath":"skills/s/SKILL.md"}"#.utf8)
        let skill = try JSONDecoder().decode(Skill.self, from: data)
        XCTAssertFalse(skill.isEnabled)
        XCTAssertEqual(skill.promptInstructions, "body")
        XCTAssertEqual(try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(skill)), skill)
    }

    func testPayloadInitializerRetainsConversations() {
        let conversation = Conversation(id: "retained")
        XCTAssertEqual(PilotAIBackupPayload(conversations: [conversation]).conversations, [conversation])
    }

    func testRealAndroidRowsMapSelectionsDatesMessagesAndCharacterBinding() throws {
        let p = try BackupService.shared.importBackup(data: json(androidFixture()))
        let provider = try XCTUnwrap(p.providers?.first)
        XCTAssertEqual(provider.id, "p"); XCTAssertEqual(provider.models.first?.id, "api-model")
        XCTAssertEqual(p.selectedModelId, "api-model")
        XCTAssertEqual(provider.defaultModelId, "api-model")
        XCTAssertEqual(provider.customHeaders.first?.key, "X-Token")
        XCTAssertEqual(provider.models.first?.contextWindowOverride, 42_000)
        XCTAssertEqual(provider.endpointMode, "responses")
        XCTAssertEqual(try object(Data(provider.customRequestBodyJSON.utf8))["temperature"] as? Double, 0.2)
        let conversation = try XCTUnwrap(p.conversations?.first)
        XCTAssertEqual(conversation.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(conversation.messages.map(\.content), ["question", "answer"])
        XCTAssertEqual(conversation.createdAt.timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.001)
        XCTAssertEqual(conversation.mode, .roleplay); XCTAssertEqual(conversation.characterId, "ada")
        XCTAssertEqual(p.characters?.first?.greeting, "Hello")
        XCTAssertEqual(p.characters?.first?.alternateGreetings, ["Hi"])
        XCTAssertEqual(p.characters?.first?.storyMemory, "character memory")
        XCTAssertEqual(p.characters?.first?.userPersonaName, "Human")
        XCTAssertFalse(p.importWarnings.isEmpty)
        XCTAssertNotNil(p.rawMessages)
    }

    func testAndroidRoundTripPreservesNestedUnknownsAndIntegerPrecision() throws {
        let original = try BackupService.shared.importBackup(data: json(androidFixture()))
        var conversations = try XCTUnwrap(original.conversations)
        conversations[0].title = "Edited title"
        let data = try BackupService.shared.exportBackup(providers: original.providers!, conversations: conversations,
            memory: MemoryDocument(markdown: original.memoryMd!), characters: original.characters!,
            selectedProviderId: "p", selectedModelId: "api-model", preserving: original)
        let root = try object(data)
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        let provider = try XCTUnwrap(providers[0]["provider"] as? [String: Any])
        XCTAssertNotNil(provider["futureProviderField"])
        XCTAssertNotNil(provider["customBodyJson"])
        XCTAssertEqual(root["selectedModelId"] as? String, "android-row-uuid")
        XCTAssertEqual(providers[0]["futureRowField"] as? String, "kept")
        let models = try XCTUnwrap(providers[0]["models"] as? [[String: Any]])
        XCTAssertEqual(models[0]["futureModelField"] as? String, "kept")
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["id"] as? String }, ["m1", "m2", "summary"])
        XCTAssertEqual(messages[1]["futureMessageField"] as? String, "kept")
        let parsed = try JSONDecoder().decode(BackupJSONValue.self, from: data)
        XCTAssertEqual(parsed.objectValue?["largeInteger"], .integer(Int64.max))
        XCTAssertEqual(try BackupService.shared.importBackup(data: data).conversations?.first?.title, "Edited title")
    }

    func testNewExportUsesActualAndroidRequiredProviderModelFieldsAndUniqueIDs() throws {
        let first = provider()
        var second = first; second.id = "p2"
        let data = try BackupService.shared.exportBackup(providers: [first, second], conversations: [], memory: MemoryDocument(), characters: [], selectedProviderId: "p2", selectedModelId: "api-model")
        let root = try object(data)
        let rows = try XCTUnwrap(root["providers"] as? [[String: Any]])
        let models = try rows.flatMap { try XCTUnwrap($0["models"] as? [[String: Any]]) }
        XCTAssertEqual(Set(models.compactMap { $0["id"] as? String }).count, 2)
        XCTAssertEqual(root["selectedModelId"] as? String, models[1]["id"] as? String)
        let requiredProvider = ["id", "type", "name", "baseUrl", "apiKey", "isEnabled", "isBuiltIn", "sortOrder", "systemPrompt", "customHeadersJson", "customBodyJson", "createdAt", "endpointMode", "hostedWebSearchEnabled", "anthropicVersion"]
        for row in rows {
            let source = try XCTUnwrap(row["provider"] as? [String: Any])
            for key in requiredProvider { XCTAssertNotNil(source[key], key) }
        }
        let requiredModel = ["id", "providerId", "modelId", "displayName", "isEnabled", "isBuiltIn", "sortOrder", "ownedBy", "contextWindow", "contextWindowOverride", "inputModalitiesJson", "outputModalitiesJson", "attachment", "toolCall", "reasoning", "reasoningOverride", "structuredOutput", "supportsTemperature", "customHeadersJson", "customBodyJson", "source", "createdAt"]
        for model in models { for key in requiredModel { XCTAssertNotNil(model[key], key) } }
    }

    func testRichIOSRoundTripIncludesMCPSettingsSkillsAndMillisecondDates() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let message = Message(id: "m", role: .assistant, content: "body", reasoningContent: "reason",
            toolCalls: [ToolCall(id: "call", name: "tool", arguments: "{}", output: "result")], timestamp: date,
            attachments: [MessageAttachment(id: "attachment", name: "a", mimeType: "text/plain", dataBase64: "YQ==")])
        let conversation = Conversation(id: "c", messages: [message], providerId: "p", modelId: "api-model", mode: .chat, createdAt: date, updatedAt: date)
        let memory = MemoryDocument(markdown: "memory", isAutoInjectEnabled: false, lastModified: date)
        let server = McpServer(id: "server", name: "Remote", urlOrCommand: "https://example.invalid", bearerToken: "token", lastRefreshedAt: date)
        let settings = AppSettings(theme: .dark, defaultProviderId: "p", defaultModelId: "api-model")
        let skill = Skill(id: "s", name: "Skill", description: "d", promptInstructions: "body")
        let data = try BackupService.shared.exportBackup(providers: [provider()], conversations: [conversation], memory: memory, characters: [], selectedProviderId: "p", selectedModelId: "api-model", skills: [skill], mcpServers: [server], settings: settings)
        let restored = try BackupService.shared.importBackup(data: data)
        XCTAssertEqual(restored.conversations, [conversation]); XCTAssertEqual(restored.memory, memory)
        XCTAssertEqual(restored.mcpServers, [server]); XCTAssertEqual(restored.settings, settings); XCTAssertEqual(restored.skills, [skill])
        let root = try object(data)
        XCTAssertNotNil((root["ios"] as? [String: Any])?["settings"])
        XCTAssertEqual(((root["conversations"] as? [[String: Any]])?.first?["createdAt"] as? NSNumber)?.int64Value, 1_700_000_000_125)
    }

    func testLegacyIOSBackupsDecodeReferenceDateAndISOStrings() throws {
        let conversation = Conversation(id: "c", messages: [Message(id: "m", role: .user, content: "old")])
        for iso in [false, true] {
            let encoder = JSONEncoder()
            if iso { encoder.dateEncodingStrategy = .iso8601 }
            let native = try JSONSerialization.jsonObject(with: encoder.encode([conversation]))
            let data = try json(["format": "eta-backup", "schemaVersion": 2, "conversations": native])
            let decoded = try BackupService.shared.importBackup(data: data)
            XCTAssertEqual(decoded.conversations?.first?.createdAt.timeIntervalSince1970 ?? 0, conversation.createdAt.timeIntervalSince1970, accuracy: iso ? 1 : 0.00001)
        }
    }

    func testMalformedAndroidReferencesAndUnsupportedVersionsFail() throws {
        var root = try androidFixture(); root["schemaVersion"] = 3
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
        root = try androidFixture(); root["selectedModelId"] = "missing-row"
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
        root = try androidFixture(); root["messages"] = [["id": "m", "conversationId": "missing", "sortIndex": 0, "type": "user", "content": "text"]]
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
        root = try androidFixture()
        var messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        messages[1]["sortIndex"] = 1; root["messages"] = messages
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: Data("{}".utf8)))
    }

    func testDeletedTranscriptInvalidatesAndroidCheckpoints() throws {
        let p = try BackupService.shared.importBackup(data: json(androidFixture()))
        var conversations = p.conversations!; conversations[0].messages.removeLast()
        let data = try BackupService.shared.exportBackup(providers: p.providers!, conversations: conversations, memory: MemoryDocument(), characters: p.characters!, selectedProviderId: "p", selectedModelId: "api-model", preserving: p)
        let root = try object(data)
        XCTAssertEqual((root["contextCheckpoints"] as? [Any])?.count, 0)
        XCTAssertEqual((root["conversations"] as? [[String: Any]])?.first?["revisionsJson"] as? String, "")
    }

    func testStorageDirectoryAndCorruptFileProtection() throws {
        let url = try directory(); let store = StorageService(directory: url, credentialStore: Credentials())
        let conversations = [Conversation(id: "saved")]
        XCTAssertTrue(store.saveConversations(conversations)); XCTAssertEqual(store.loadConversations().map(\.id), ["saved"])
        let corrupt = Data("{ damaged".utf8); let file = url.appendingPathComponent("conversations.json")
        try corrupt.write(to: file)
        XCTAssertTrue(store.loadConversations().isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.saveConversations([]))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertTrue(store.saveSettings(AppSettings()))
        XCTAssertNotNil(store.lastError, "A successful unrelated write must not conceal data loss")
    }

    func testUnloadedCorruptFilesAreNeverOverwritten() throws {
        let url = try directory(); let file = url.appendingPathComponent("skills.json")
        let corrupt = Data("oops".utf8); try corrupt.write(to: file)
        let store = StorageService(directory: url, credentialStore: Credentials())
        XCTAssertFalse(store.saveSkills([])); XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testCredentialsStoredOutsideProviderJSONAndLegacyMigrationIsVerified() throws {
        let url = try directory(); let credentials = Credentials()
        let file = url.appendingPathComponent("providers.json")
        try JSONEncoder().encode([provider()]).write(to: file)
        let store = StorageService(directory: url, credentialStore: credentials)
        XCTAssertEqual(store.loadProviders(), [provider()]); XCTAssertNil(store.lastError)
        let disk = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(disk.contains("secret-key")); XCTAssertFalse(disk.contains("secret-header"))
        XCTAssertTrue(disk.contains("credentialReference")); XCTAssertEqual(credentials.records.count, 1)
        let reopened = StorageService(directory: url, credentialStore: credentials)
        XCTAssertEqual(reopened.loadProviders(), [provider()])
    }

    func testFailedLegacyMigrationPreservesPlaintextKeyAndReportsError() throws {
        let url = try directory(); let credentials = Credentials(); credentials.failWrites = true
        let file = url.appendingPathComponent("providers.json")
        let original = try JSONEncoder().encode([provider()]); try original.write(to: file)
        let store = StorageService(directory: url, credentialStore: credentials)
        XCTAssertEqual(store.loadProviders().first?.apiKey, "secret-key")
        XCTAssertEqual(try Data(contentsOf: file), original); XCTAssertNotNil(store.lastError)
        credentials.failWrites = false; credentials.corruptReadback = true
        _ = store.loadProviders(); XCTAssertEqual(try Data(contentsOf: file), original)
        credentials.corruptReadback = false
        XCTAssertEqual(store.loadProviders().first?.apiKey, "secret-key")
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("secret-key"))
    }

    func testLockedCredentialStoreCannotEraseExistingKeyOrFile() throws {
        let url = try directory(); let credentials = Credentials(); let store = StorageService(directory: url, credentialStore: credentials)
        XCTAssertTrue(store.saveProviders([provider()]))
        let file = url.appendingPathComponent("providers.json"); let data = try Data(contentsOf: file)
        let originalSecrets = credentials.records
        credentials.failReads = true
        XCTAssertTrue(store.loadProviders().isEmpty); XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.saveProviders([]))
        XCTAssertEqual(try Data(contentsOf: file), data); XCTAssertEqual(credentials.records, originalSecrets)
        credentials.failReads = false
        XCTAssertEqual(store.loadProviders(), [provider()]); XCTAssertTrue(store.saveProviders([provider()]))
    }

    func testMCPHeadersTokensAndEnvironmentAreProtected() throws {
        let url = try directory(); let credentials = Credentials(); let store = StorageService(directory: url, credentialStore: credentials)
        let server = McpServer(id: "mcp", name: "Server", urlOrCommand: "https://example.invalid",
            envVars: ["SECRET": "secret-env"], headers: ["X-Key": "secret-header"], bearerToken: "secret-token")
        XCTAssertTrue(store.saveMcpServers([server]))
        let disk = String(decoding: try Data(contentsOf: url.appendingPathComponent("mcp_servers.json")), as: UTF8.self)
        for secret in ["secret-env", "secret-header", "secret-token"] { XCTAssertFalse(disk.contains(secret)) }
        XCTAssertEqual(store.loadMcpServers(), [server])
    }

    func testFileCommitFailureKeepsOldCredentialSnapshotAndAllowsRetry() throws {
        let url = try directory(); let credentials = Credentials(); let manager = FailingFileManager()
        let store = StorageService(directory: url, credentialStore: credentials, fileManager: manager)
        XCTAssertTrue(store.saveProviders([provider()]))
        let file = url.appendingPathComponent("providers.json"); let original = try Data(contentsOf: file)
        let originalCredentials = credentials.records
        manager.failDirectoryCreation = true
        var changed = provider(); changed.apiKey = "new-secret"
        XCTAssertFalse(store.saveProviders([changed]))
        XCTAssertEqual(try Data(contentsOf: file), original)
        for (key, value) in originalCredentials { XCTAssertEqual(credentials.records[key], value) }
        manager.failDirectoryCreation = false
        XCTAssertEqual(store.loadProviders().first?.apiKey, "secret-key")
        XCTAssertTrue(store.saveProviders([changed]))
        XCTAssertEqual(store.loadProviders().first?.apiKey, "new-secret")
    }

    func testDuplicateProviderIDsCannotOverwriteCredentialAssociation() throws {
        let url = try directory(); let credentials = Credentials(); let store = StorageService(directory: url, credentialStore: credentials)
        XCTAssertTrue(store.saveProviders([provider()]))
        let original = try Data(contentsOf: url.appendingPathComponent("providers.json"))
        var duplicate = provider(); duplicate.apiKey = "different-secret"
        XCTAssertFalse(store.saveProviders([provider(), duplicate]))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("providers.json")), original)
        XCTAssertEqual(store.loadProviders(), [provider()])
    }

    func testAvatarAndRevisionValidationAndNativeIdentityMismatch() throws {
        var root = try androidFixture()
        var roleplay = try XCTUnwrap(root["roleplay"] as? [String: Any])
        var assets = try XCTUnwrap(roleplay["assets"] as? [[String: Any]])
        assets[0]["avatarBase64"] = Data("not a PNG".utf8).base64EncodedString()
        roleplay["assets"] = assets; root["roleplay"] = roleplay
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
        root = try androidFixture()
        var conversations = try XCTUnwrap(root["conversations"] as? [[String: Any]])
        conversations[0]["revisionsJson"] = #"{"links":{"missing":{"transcriptMessageId":"t","blockOrder":0}}}"#
        root["conversations"] = conversations
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
        root = try androidFixture()
        root["ios"] = ["version": 1, "conversations": []]
        XCTAssertThrowsError(try BackupService.shared.importBackup(data: json(root)))
    }

    func testDisabledAndroidModelsRemainArchivalAcrossExport() throws {
        var root = try androidFixture()
        var providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        var models = try XCTUnwrap(providers[0]["models"] as? [[String: Any]])
        var disabled = models[0]; disabled["id"] = "disabled-row"; disabled["modelId"] = "disabled-model"; disabled["isEnabled"] = false
        models.append(disabled); providers[0]["models"] = models; root["providers"] = providers
        let p = try BackupService.shared.importBackup(data: json(root))
        XCTAssertEqual(p.providers?.first?.models.map(\.id), ["api-model"])
        let data = try BackupService.shared.exportBackup(providers: p.providers!, conversations: p.conversations!, memory: MemoryDocument(), characters: p.characters!, selectedProviderId: "p", selectedModelId: "api-model", preserving: p)
        let exported = try object(data)
        let exportedProviders = try XCTUnwrap(exported["providers"] as? [[String: Any]])
        let exportedModels = try XCTUnwrap(exportedProviders[0]["models"] as? [[String: Any]])
        XCTAssertEqual(exportedModels.count, 2)
        XCTAssertEqual(exportedModels.first { $0["id"] as? String == "disabled-row" }?["isEnabled"] as? Bool, false)
    }

    func testAndroidToolActivityIsNeverInstalledAsAnOrphanProtocolMessage() throws {
        var root = try androidFixture()
        var messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        messages.append(["id": "activity", "conversationId": "c", "sortIndex": 3, "type": "tool", "content": "command", "toolName": "terminal", "resultSummary": "display result"])
        messages.append(["id": "thinking", "conversationId": "c", "sortIndex": 4, "type": "thinking", "content": "reasoning"])
        root["messages"] = messages
        let p = try BackupService.shared.importBackup(data: json(root))
        XCTAssertEqual(p.conversations?.first?.messages.map(\.id), ["m1", "m2"])
        let data = try BackupService.shared.exportBackup(providers: p.providers!, conversations: p.conversations!, memory: MemoryDocument(), characters: p.characters!, selectedProviderId: "p", selectedModelId: "api-model", preserving: p)
        let exported = try object(data)
        XCTAssertEqual((exported["messages"] as? [[String: Any]])?.count, 5)
        var nativeConversations = p.conversations!
        nativeConversations[0].messages += [Message(id: "real-call", role: .assistant, content: "", toolCalls: [ToolCall(id: "call", name: "test", arguments: "{}")]), Message(id: "real-result", role: .tool, content: "result", toolCallId: "call")]
        let nativeData = try BackupService.shared.exportBackup(providers: p.providers!, conversations: nativeConversations, memory: MemoryDocument(), characters: p.characters!, selectedProviderId: "p", selectedModelId: "api-model", preserving: p)
        let reimported = try BackupService.shared.importBackup(data: nativeData)
        XCTAssertEqual(reimported.conversations?.first?.messages.last?.toolCallId, "call")
        XCTAssertNoThrow(try BackupService.shared.exportBackup(providers: p.providers!, conversations: nativeConversations, memory: MemoryDocument(), characters: p.characters!, selectedProviderId: "p", selectedModelId: "api-model", preserving: reimported))
    }

    func testBackupPreservationIsEncryptedOrFailsExplicitly() throws {
        let url = try directory(); let credentials = Credentials(); let store = StorageService(directory: url, credentialStore: credentials)
        let payload = try BackupService.shared.importBackup(data: json(androidFixture()))
        #if canImport(CryptoKit)
        XCTAssertTrue(store.saveBackupPreservation(payload))
        let disk = String(decoding: try Data(contentsOf: url.appendingPathComponent("backup_preservation.json")), as: UTF8.self)
        XCTAssertFalse(disk.contains("android-key")); XCTAssertFalse(disk.contains("header-secret"))
        XCTAssertEqual(store.loadBackupPreservation()?.rawDocument, payload.rawDocument)
        credentials.failReads = true
        XCTAssertNil(store.loadBackupPreservation())
        XCTAssertFalse(store.saveBackupPreservation(payload))
        #else
        XCTAssertFalse(store.saveBackupPreservation(payload)); XCTAssertNotNil(store.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("backup_preservation.json").path))
        #endif
    }

    func testMarkdownParserSupportsBOMCRLFQuotedColonsBlockScalarsAndMetadata() throws {
        let source = "\u{FEFF}---\r\nname: \"research: careful\"\r\ndescription: >-\r\n  Read first\r\n  then summarize.\r\nmetadata:\r\n  author: 'O''Brien'\r\ncompatibility: ios\r\n---\r\n# Instructions\r\nKeep a literal --- inside the body."
        let skill = try XCTUnwrap(SkillDocumentParser.parse(data: Data(source.utf8)).first)
        XCTAssertEqual(skill.name, "research: careful")
        XCTAssertEqual(skill.description, "Read first then summarize.")
        XCTAssertEqual(skill.metadata["author"], "O'Brien")
        XCTAssertTrue(skill.promptInstructions.contains("literal ---"))
    }

    func testMarkdownAndJSONExportsRoundTripResourceMetadata() throws {
        let skill = Skill(id: "s", name: "Useful", description: "line 1\nline 2", promptInstructions: "# Body\n\nKeep spacing.\n", isEnabled: false,
            compatibility: "ios", metadata: ["special:key": "quoted \"value\""], source: "imported", installed: true,
            hasScripts: true, hasReferences: true, resources: [SkillResource(path: "scripts/tool.py", kind: .script, byteCount: 100), SkillResource(path: "references/guide.md", kind: .reference)], skillFilePath: "source/SKILL.md")
        XCTAssertEqual(try SkillDocumentParser.parse(data: SkillDocumentParser.exportJSON([skill]), filename: "skills.json"), [skill])
        XCTAssertEqual(try SkillDocumentParser.parse(data: SkillDocumentParser.exportMarkdown(skill)), [skill])
    }

    func testMalformedSkillsFailInsteadOfBecomingPromptText() throws {
        for source in ["{broken JSON", "{}", "---\nname: sample\n---\n", "---\nname: one\nname: two\n---\nbody", "---\nname: *alias\n---\nbody", "---\nname: missing terminator\n---not-a-delimiter\nbody"] {
            XCTAssertThrowsError(try SkillDocumentParser.parse(data: Data(source.utf8)), source)
        }
        XCTAssertThrowsError(try SkillDocumentParser.parse(data: Data(repeating: 97, count: SkillDocumentParser.maximumBytes + 1)))
        XCTAssertThrowsError(try SkillDocumentParser.parse(data: Data("---\nname: valid\n---\nbody".utf8), filename: "package.zip"))
        let unsafe = Skill(name: "Unsafe path", description: "", promptInstructions: "body", resources: [SkillResource(path: "../run.sh", kind: .script)])
        XCTAssertThrowsError(try SkillDocumentParser.exportJSON([unsafe]))
    }

    func testGitHubURLsAreExplicitSingleHTTPSFiles() throws {
        let source = try XCTUnwrap(URL(string: "https://github.com/owner/repo/blob/main/path/SKILL.md"))
        XCTAssertEqual(try SkillDocumentParser.githubRawURL(for: source).absoluteString, "https://raw.githubusercontent.com/owner/repo/main/path/SKILL.md")
        for string in ["http://github.com/o/r/blob/main/SKILL.md", "https://github.com.evil.invalid/o/r/blob/main/SKILL.md", "https://user:pass@github.com/o/r/blob/main/SKILL.md", "https://github.com/o/r/archive/main.zip", "https://github.com/o/r/blob/main/SKILL.md?token=secret", "https://raw.githubusercontent.com/o/r/main/../SKILL.md", "https://github.com/o/r/tree/main"] {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertThrowsError(try SkillDocumentParser.githubRawURL(for: url), string)
        }
    }

    func testBoundedFileReadingRejectsOversizedFiles() throws {
        let url = try directory().appendingPathComponent("large.json")
        try Data(repeating: 0, count: 1025).write(to: url)
        XCTAssertThrowsError(try BoundedDataReader.read(url, limit: 1024))
        XCTAssertEqual(try BoundedDataReader.read(url, limit: 1025).count, 1025)
    }
}
