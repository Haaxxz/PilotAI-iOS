import XCTest
@testable import PilotAI

final class DataParityTests: XCTestCase {
    func testLegacyCharacterDecodingDefaultsOptionalFields() throws {
        let data = Data(#"{"id":"legacy","name":"Old","description":"d"}"#.utf8)
        let character = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertEqual(character.id, "legacy")
        XCTAssertEqual(character.alternateGreetings, [])
        XCTAssertNil(character.cardJSON)
    }

    func testEtaBackupRoundTripPreservesOptionalCollections() throws {
        let skill = Skill(id: "s", name: "Skill", description: "d", promptInstructions: "body", compatibility: "ios")
        let payload = PilotAIBackupPayload(selectedProviderId: "provider", selectedModelId: "model", memoryMd: "# memory", skills: [skill], roleplay: .object(["future": .string("kept")]))
        let data = try JSONEncoder().encode(payload)
        let decoded = try BackupService.shared.importBackup(data: data)
        XCTAssertEqual(decoded.skills, [skill])
        XCTAssertEqual(decoded.roleplay?.objectValue?["future"]?.stringValue, "kept")
    }

    func testCharacterCardV2ImportAndExport() throws {
        let source: [String: Any] = ["spec": "chara_card_v2", "spec_version": "2.0", "data": ["name": "Card", "first_mes": "Hi", "alternate_greetings": ["Hello again"], "tags": ["test"]]]
        let input = try JSONSerialization.data(withJSONObject: source)
        let card = try XCTUnwrap(CharacterCardParser.parseJSON(input))
        XCTAssertEqual(card.name, "Card")
        let output = try CharacterCardParser.exportJSON(for: card, version: 2)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    func testMessageToolResultKeepsCallIdentifier() throws {
        let message = Message(role: .tool, content: "result", toolCallId: "call-1")
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: encoded)
        XCTAssertEqual(decoded.toolCallId, "call-1")
    }

    func testLegacySettingsDecodeUsesNewDefaults() throws {
        let data = Data(#"{"theme":"dark","defaultProviderId":"provider"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(settings.defaultProviderId, "provider")
        XCTAssertTrue(settings.sendOnEnter)
        XCTAssertTrue(settings.enableMemoryTool)
    }

    func testRuntimeToolSchemasRespectSettings() {
        var settings = AppSettings()
        settings.enableTerminalTool = true
        settings.enableUnsandboxedGateway = true
        let schemas = IOSRuntimeToolService.availableToolSchemas(settings: settings, webSearchEnabled: true)
        let names = schemas.compactMap { schema -> String? in
            (schema["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["memory_get", "memory_write", "conversation_history", "web_search", "terminal"])

        settings.enableMemoryTool = false
        settings.enableUnsandboxedGateway = false
        let restricted = IOSRuntimeToolService.availableToolSchemas(settings: settings, webSearchEnabled: true)
        let restrictedNames = restricted.compactMap { schema -> String? in
            (schema["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(restrictedNames, ["conversation_history", "web_search"])
    }

    func testBuiltInProvidersDoNotShipCredentials() {
        let openRouter = ModelProvider.defaults.first { $0.type == .openrouter }
        XCTAssertEqual(openRouter?.apiKey ?? "missing", "")
    }
}

/// Kept in an existing test source so runtime coverage needs no project-file changes.
final class IOSRuntimeToolTests: XCTestCase {
    private func temporaryStore() throws -> (URL, IOSRuntimeToolService.MemoryStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.json")
        return (url, IOSRuntimeToolService.MemoryStore(fileURL: url))
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testMemoryWritesPersistAndRejectStaleRevisionsAcrossStoreInstances() throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument(markdown: "first", isAutoInjectEnabled: false)
        let revision = try store.read(fallback: initial).revision
        let saved = try store.write(markdown: "second", mode: "append", expectedRevision: revision, fallback: initial)
        XCTAssertEqual(saved.document.markdown, "first\n\nsecond")
        XCTAssertFalse(saved.document.isAutoInjectEnabled)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MemoryDocument.self, from: data), saved.document)

        let reopened = IOSRuntimeToolService.MemoryStore(fileURL: url)
        XCTAssertEqual(try reopened.read(fallback: initial).revision, saved.revision)
        XCTAssertThrowsError(try reopened.write(markdown: "stale replacement", mode: "replace", expectedRevision: revision, fallback: initial)) {
            XCTAssertEqual($0 as? IOSRuntimeToolService.RuntimeToolError, .memoryConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), data)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try reopened.write(markdown: "resurrected", mode: "replace", expectedRevision: saved.revision, fallback: saved.document)) {
            XCTAssertEqual($0 as? IOSRuntimeToolService.RuntimeToolError, .memoryConflict)
        }
    }

    func testMemoryNoOpCreatesMissingFileAndOversizeWritePreservesIt() throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument(markdown: "existing")
        let revision = try store.read(fallback: initial).revision
        let saved = try store.write(markdown: initial.markdown, mode: "replace", expectedRevision: revision, fallback: initial)
        let data = try Data(contentsOf: url)
        XCTAssertNotEqual(saved.revision, revision)
        XCTAssertThrowsError(try store.write(markdown: String(repeating: "🙂", count: 8_001), mode: "replace", expectedRevision: saved.revision, fallback: initial))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testCorruptMemoryAndPersistenceErrorsNeverReportSuccess() throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument(markdown: "fallback")
        let revision = try store.read(fallback: initial).revision
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.write(markdown: "overwrite", mode: "replace", expectedRevision: revision, fallback: initial))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        let missingParent = IOSRuntimeToolService.MemoryStore(fileURL: url.deletingLastPathComponent().appendingPathComponent("missing/memory.json"))
        let missingRevision = try missingParent.read(fallback: initial).revision
        XCTAssertThrowsError(try missingParent.write(markdown: "new", mode: "replace", expectedRevision: missingRevision, fallback: initial))
    }

    func testConcurrentMemoryWritersHaveOneWinner() async throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument(markdown: "initial")
        let revision = try store.read(fallback: initial).revision
        let other = IOSRuntimeToolService.MemoryStore(fileURL: url)
        let first = Task.detached { try store.write(markdown: "first", mode: "replace", expectedRevision: revision, fallback: initial) }
        let second = Task.detached { try other.write(markdown: "second", mode: "replace", expectedRevision: revision, fallback: initial) }
        let outcomes = [await first.result, await second.result]
        XCTAssertEqual(outcomes.compactMap { try? $0.get() }.count, 1)
        let errors = outcomes.compactMap { result -> IOSRuntimeToolService.RuntimeToolError? in
            if case .failure(let error) = result { return error as? IOSRuntimeToolService.RuntimeToolError }
            return nil
        }
        XCTAssertEqual(errors, [.memoryConflict])
    }

    func testRuntimeRejectsMalformedArgumentsAndRunDisabledTools() async throws {
        let (_, store) = try temporaryStore()
        let initial = MemoryDocument()
        for arguments in ["not JSON", "[]", #"{"query":true}"#, #"{"path":"/etc/passwd"}"#] {
            let output = await IOSRuntimeToolService.execute(toolName: "memory_get", arguments: arguments, settings: AppSettings(), memory: initial, memoryStore: store)
            XCTAssertTrue(output.hasPrefix("TOOL_INVALID_ARGUMENTS:"), output)
        }
        let search = await IOSRuntimeToolService.execute(toolName: "web_search", arguments: #"{"query":"test"}"#, settings: AppSettings(), memory: initial, memoryStore: store)
        XCTAssertTrue(search.contains("TOOL_UNAVAILABLE"))
        let disabled = await IOSRuntimeToolService.execute(toolName: "memory_write", arguments: "{}", settings: AppSettings(enableMemoryTool: false), memory: initial, memoryStore: store)
        XCTAssertTrue(disabled.contains("TOOL_UNAVAILABLE"))
        do {
            _ = try await IOSRuntimeToolService.executeGatewayCommand(String(repeating: "x", count: 8_193), settings: AppSettings(enableUnsandboxedGateway: true, remoteGatewayURL: "https://example.invalid/command"))
            XCTFail("Oversized commands must be rejected before networking, never truncated")
        } catch {
            guard case IOSRuntimeToolService.RuntimeToolError.invalidArguments = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testHistoryUsesCurrentSnapshotPaginatesAndOmitsPrivatePayloads() async throws {
        let current = Conversation(id: "current", messages: [
            Message(id: "system", role: .system, content: "system-private-sentinel"),
            Message(id: "one", role: .user, content: "first", attachments: [MessageAttachment(name: "file", mimeType: "text/plain", dataBase64: "attachment-private-sentinel")]),
            Message(id: "tool", role: .tool, content: "tool-private-sentinel"),
            Message(id: "two", role: .assistant, content: "second", reasoningContent: "reasoning-private-sentinel",
                    toolCalls: [ToolCall(name: "test", arguments: "argument-private-sentinel", output: "output-private-sentinel")]),
            Message(id: "three", role: .user, content: "third")
        ])
        let stale = Conversation(id: current.id, messages: [Message(role: .user, content: "stale")])
        let result = try await IOSRuntimeToolService.executeTool(toolName: "conversation_history", arguments: #"{"limit":2}"#, settings: AppSettings(), memory: MemoryDocument(), conversation: current, conversations: [stale])
        let page = try object(result.output)
        let messages = try XCTUnwrap(page["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["id"] as? String }, ["two", "three"])
        XCTAssertEqual(page["next_before_message_id"] as? String, "two")
        XCTAssertFalse(result.output.contains("private-sentinel"))
        XCTAssertFalse(result.output.contains("stale"))
        let older = try await IOSRuntimeToolService.executeTool(toolName: "conversation_history", arguments: #"{"limit":2,"before_message_id":"two"}"#, settings: AppSettings(), memory: MemoryDocument(), conversation: current)
        XCTAssertEqual((try object(older.output)["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["one"])
        XCTAssertFalse(older.output.contains("private-sentinel"))
    }

    func testHistoryHasUTF8AndScanBoundsAndValidatesNumericLimits() async throws {
        let content = String(repeating: "🙂", count: 2_001)
        let messages = (0..<1_100).map { Message(id: "m\($0)", role: .user, content: content) }
        let conversation = Conversation(messages: messages)
        let result = try await IOSRuntimeToolService.executeTool(toolName: "conversation_history", arguments: #"{"limit":50}"#, settings: AppSettings(), memory: MemoryDocument(), conversation: conversation)
        let page = try object(result.output)
        let rows = try XCTUnwrap(page["messages"] as? [[String: Any]])
        let text = rows.compactMap { $0["content"] as? String }
        XCTAssertLessThanOrEqual(text.map { $0.utf8.count }.reduce(0, +), 32_000)
        XCTAssertTrue(text.allSatisfy { $0.utf8.count <= 4_000 && !$0.contains("�") })
        XCTAssertEqual(page["truncated"] as? Bool, true)
        for limit in ["true", "0", "51", "1.5"] {
            let output = await IOSRuntimeToolService.execute(toolName: "conversation_history", arguments: "{\"limit\":\(limit)}", settings: AppSettings(), memory: MemoryDocument(), conversation: conversation)
            XCTAssertTrue(output.hasPrefix("TOOL_INVALID_ARGUMENTS:"))
        }
        let noMatches = try await IOSRuntimeToolService.executeTool(toolName: "conversation_history", arguments: #"{"query":"absent"}"#, settings: AppSettings(), memory: MemoryDocument(), conversation: conversation)
        XCTAssertEqual(try object(noMatches.output)["next_before_message_id"] as? String, "m100")
    }

    func testCancelledMemoryExecutionDoesNotCreateFile() async throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument()
        let revision = try store.read(fallback: initial).revision
        let arguments = try json(["markdown": "not saved", "mode": "replace", "expected_revision": revision])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await IOSRuntimeToolService.executeTool(toolName: "memory_write", arguments: arguments, settings: AppSettings(), memory: initial, memoryStore: store)
                XCTFail("Cancelled tools must not execute")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testEnginePersistsMemoryPublishesHookAndUsesNewMemoryNextRound() async throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument(markdown: "first")
        let revision = try store.read(fallback: initial).revision
        let arguments = try json(["markdown": "remembered-preference", "mode": "append", "expected_revision": revision])
        var round = 0
        var adopted: MemoryDocument?
        let completed = expectation(description: "completed")
        let engine = AgentEngine(streamChat: { _, _, history, prompt, _ in
            defer { round += 1 }
            return AsyncThrowingStream { stream in
                if round == 0 {
                    stream.yield(StreamChunk(toolCallDelta: ToolCallDelta(index: 0, id: "save", name: "memory_write", argumentsDelta: arguments)))
                    stream.yield(StreamChunk(isFinished: true, finishReason: "tool_calls", toolsMayExecute: true))
                } else {
                    XCTAssertTrue(prompt.contains("remembered-preference"))
                    XCTAssertEqual(history.filter { $0.role == .tool }.map(\.toolCallId), ["save"])
                    XCTAssertEqual(history.filter { $0.role == .user }.count, 1)
                    stream.yield(StreamChunk(textDelta: "Saved."))
                    stream.yield(StreamChunk(isFinished: true, finishReason: "stop"))
                }
                stream.finish()
            }
        }, memoryStore: store)
        engine.send(prompt: "Remember this", conversation: Conversation(messages: [Message(role: .user, content: "Remember this")]), provider: ModelProvider.defaults[0], memory: initial,
                    onMemoryUpdate: { adopted = $0 }, onUpdate: { _ in }, onCompletion: { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(adopted?.markdown, "first\n\nremembered-preference")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testEngineCancellationFromUpdatePreventsDispatchAndClearsExecutingState() async throws {
        let (url, store) = try temporaryStore()
        let initial = MemoryDocument()
        let arguments = try json(["markdown": "not saved", "mode": "replace", "expected_revision": store.read(fallback: initial).revision])
        let cancelled = expectation(description: "cancelled")
        var last: Message?
        let engine = AgentEngine(streamChat: { _, _, _, _, _ in
            AsyncThrowingStream { stream in
                stream.yield(StreamChunk(toolCallDelta: ToolCallDelta(index: 0, id: "save", name: "memory_write", argumentsDelta: arguments)))
                stream.yield(StreamChunk(isFinished: true, finishReason: "tool_calls", toolsMayExecute: true))
                stream.finish()
            }
        }, memoryStore: store)
        engine.send(prompt: "test", conversation: Conversation(), provider: ModelProvider.defaults[0], memory: initial, onUpdate: { message in
            last = message
            if message.toolCalls?.first?.isExecuting == true {
                engine.stop()
                cancelled.fulfill()
            }
        }, onCompletion: { _ in XCTFail("Cancelled runs must not publish a completion for another run") })
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(last?.isStreaming, false)
        XCTAssertEqual(last?.toolCalls?.first?.isExecuting, false)
        XCTAssertNotNil(last?.toolCalls?.first?.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testEngineProvidesToolFreeFinalRoundAndKeepsWireCallID() async throws {
        var round = 0
        var finalToolsWereEmpty = false
        let completed = expectation(description: "completed")
        let engine = AgentEngine(streamChat: { _, _, history, _, tools in
            defer { round += 1 }
            return AsyncThrowingStream { stream in
                if round < 6 {
                    stream.yield(StreamChunk(toolCallDelta: ToolCallDelta(index: 0, id: "call-\(round)", name: "conversation_history")))
                    stream.yield(StreamChunk(toolCallDelta: ToolCallDelta(index: 0, id: "item-\(round)", argumentsDelta: "{}")))
                    stream.yield(StreamChunk(isFinished: true, finishReason: "tool_calls", toolsMayExecute: true))
                } else {
                    finalToolsWereEmpty = tools.isEmpty
                    XCTAssertEqual(history.filter { $0.role == .tool }.compactMap(\.toolCallId), (0..<6).map { "call-\($0)" })
                    stream.yield(StreamChunk(textDelta: "<thi"))
                    stream.yield(StreamChunk(textDelta: "nk>private</think>Done."))
                    stream.yield(StreamChunk(isFinished: true, finishReason: "stop"))
                }
                stream.finish()
            }
        })
        engine.send(prompt: "test", conversation: Conversation(), provider: ModelProvider.defaults[0], memory: MemoryDocument(), settings: AppSettings(enableMemoryTool: false), onUpdate: { _ in }, onCompletion: { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, "Done.")
                XCTAssertEqual(message.reasoningContent, "private")
            case .failure(let error): XCTFail("\(error)")
            }
            completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(round, 7)
        XCTAssertTrue(finalToolsWereEmpty)
    }
}
