import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PilotAI

final class ProviderProtocolTests: XCTestCase {
    private func provider(_ api: ProviderAPI = .chatCompletions) -> ModelProvider {
        ModelProvider(name: "Fixture", type: api == .anthropic ? .anthropic : .custom,
                      baseURL: "https://fixture.invalid/v1", apiKey: "draft-fixture-key", defaultModelId: "real-model-id",
                      endpointMode: api == .responses ? "responses" : "chat_completions")
    }

    private func event(_ json: [String: Any]) throws -> ProviderSSEEvent {
        ProviderSSEEvent(data: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }

    private func chat(_ delta: [String: Any], reason: String? = nil) throws -> ProviderSSEEvent {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let reason { choice["finish_reason"] = reason }
        return try event(["choices": [choice]])
    }

    private func tool(_ index: Int = 0, id: String? = "call_1", name: String? = "lookup", arguments: String = "{}") -> [String: Any] {
        var result: [String: Any] = ["index": index, "type": "function"]
        var function: [String: Any] = ["arguments": arguments]
        if let id { result["id"] = id }
        if let name { function["name"] = name }
        result["function"] = function
        return result
    }

    private func functionItem(arguments: String = "{}", status: String = "completed") -> [String: Any] {
        ["type": "function_call", "id": "fc_item", "call_id": "call_real", "name": "lookup", "arguments": arguments, "status": status]
    }

    private func completed(_ output: [[String: Any]] = []) throws -> ProviderSSEEvent {
        try event(["type": "response.completed", "response": ["status": "completed", "output": output]])
    }

    private func assertFailure(_ expected: ProviderServiceError, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ProviderServiceError, expected, file: file, line: line)
        }
    }

    func testSSEMultilineBOMCommentsAndSplitUnicode() throws {
        let source = "\u{FEFF}: heartbeat\r\nevent: output\r\ndata:{\r\ndata: \"text\":\"Hi 🌍\"}\r\n\r\n"
        var decoder = ProviderSSEDecoder()
        var frames: [ProviderSSEEvent] = []
        for byte in Data(source.utf8) { frames += try decoder.append(Data([byte])) }
        XCTAssertEqual(frames, [ProviderSSEEvent(event: "output", data: "{\n\"text\":\"Hi 🌍\"}")])
    }

    func testSSESupportsBareCRAndEmptyDataAndIgnoresUnknownFields() throws {
        var decoder = ProviderSSEDecoder()
        let frames = try decoder.append(Data("id: 10\rretry: 200\rdata:one\rdata\r\r: ping\n\nevent: ping\n\ndata:two\n\n".utf8))
        XCTAssertEqual(frames.map(\.data), ["one\n", "two"])
        XCTAssertNil(frames.last?.event)
    }

    func testSSEDoesNotDispatchAnUnterminatedEvent() throws {
        var decoder = ProviderSSEDecoder()
        XCTAssertTrue(try decoder.append(Data("data: [DONE]\n".utf8)).isEmpty)
        var parser = ProviderStreamParser(api: .chatCompletions)
        _ = try parser.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata:[DONE]\n".utf8))
        assertFailure(.incompleteStream) { try parser.finish() }
    }

    func testSSERejectsOversizedFramesAndInvalidUTF8() throws {
        var decoder = ProviderSSEDecoder(maximumFrameBytes: 10)
        assertFailure(.streamLimit) { _ = try decoder.append(Data("data: 123456789012345".utf8)) }
        var utf8 = ProviderSSEDecoder()
        assertFailure(.malformedStream) { _ = try utf8.append(Data([100, 97, 116, 97, 58, 255, 10, 10])) }
    }

    func testChatRequiresFinishReasonAndDoneAndPreservesReasoning() throws {
        var parser = ProviderStreamParser(api: .chatCompletions)
        let content = try parser.consume(chat(["content": "hello", "reasoning_content": "summary"]))
        XCTAssertEqual(content.first?.textDelta, "hello")
        XCTAssertEqual(content.first?.reasoningDelta, "summary")
        let reason = try parser.consume(chat([:], reason: "stop"))
        XCTAssertEqual(reason.last?.finishReason, "stop")
        XCTAssertFalse(reason.last!.isFinished)
        _ = try parser.consume(event(["choices": [], "usage": ["total_tokens": 3]]))
        let end = try parser.consume(ProviderSSEEvent(data: "[DONE]"))
        XCTAssertTrue(end.last!.isFinished)
        XCTAssertFalse(end.last!.toolsMayExecute)
        XCTAssertEqual(end.last?.finishReason, "stop")
        try parser.finish()
    }

    func testChatParallelFragmentedCallsGetSingleSafeTerminal() throws {
        var parser = ProviderStreamParser(api: .chatCompletions)
        _ = try parser.consume(chat(["tool_calls": [tool(0, id: "a", arguments: "{\"city\":"), tool(1, id: "b", arguments: "{}")]]))
        let delta = try parser.consume(chat(["tool_calls": [tool(0, id: nil, name: nil, arguments: "\"Paris\"}")]]))
        XCTAssertNil(delta[0].toolCallDelta?.id)
        XCTAssertFalse(delta[0].toolsMayExecute)
        _ = try parser.consume(chat([:], reason: "tool_calls"))
        let terminal = try parser.consume(ProviderSSEEvent(data: "[DONE]"))
        XCTAssertEqual(terminal.filter(\.isFinished).count, 1)
        XCTAssertTrue(terminal[0].toolsMayExecute)
        try parser.finish()
    }

    func testTruncationAndMissingFinishNeverAuthorizeTools() throws {
        var parser = ProviderStreamParser(api: .chatCompletions)
        _ = try parser.consume(chat(["tool_calls": [tool()]]))
        assertFailure(.incompleteStream) { try parser.finish() }
        assertFailure(.incompleteStream) { _ = try parser.consume(ProviderSSEEvent(data: "[DONE]")) }
        XCTAssertFalse(StreamChunk(isFinished: true).toolsMayExecute)
        XCTAssertFalse(StreamChunk(toolsMayExecute: true).toolsMayExecute)
    }

    func testChatRejectsTruncationFilteringAndDeprecatedFunctionCalls() throws {
        for reason in ["length", "content_filter", "function_call", "future_reason"] {
            var parser = ProviderStreamParser(api: .chatCompletions)
            assertFailure(.rejectedCompletion) { _ = try parser.consume(chat([:], reason: reason)) }
        }
        var parser = ProviderStreamParser(api: .chatCompletions)
        assertFailure(.invalidToolCall) { _ = try parser.consume(chat(["function_call": ["name": "old"]])) }
    }

    func testChatRejectsChangedOrDuplicateIDsAndInvalidArguments() throws {
        var changed = ProviderStreamParser(api: .chatCompletions)
        _ = try changed.consume(chat(["tool_calls": [tool(arguments: "")]]))
        assertFailure(.invalidToolCall) { _ = try changed.consume(chat(["tool_calls": [tool(id: "changed")]])) }
        for tools in [[tool(arguments: "{broken")], [tool(arguments: "[]")], [tool(id: nil)], [tool(0), tool(1)]] {
            var parser = ProviderStreamParser(api: .chatCompletions)
            _ = try parser.consume(chat(["tool_calls": tools], reason: "tool_calls"))
            assertFailure(.invalidToolCall) { _ = try parser.consume(ProviderSSEEvent(data: "[DONE]")) }
        }
    }

    func testCallsWithStopReasonOrRefusalAreNotExecutable() throws {
        for delta in [["tool_calls": [tool()]], ["tool_calls": [tool()], "refusal": "Cannot"]] as [[String: Any]] {
            var parser = ProviderStreamParser(api: .chatCompletions)
            _ = try parser.consume(chat(delta, reason: "stop"))
            assertFailure(.invalidToolCall) { _ = try parser.consume(ProviderSSEEvent(data: "[DONE]")) }
        }
    }

    func testResponsesUsesCallIDNeverItemIDAndDoesNotRepeatArguments() throws {
        var parser = ProviderStreamParser(api: .responses)
        let start = try parser.consume(event(["type": "response.output_item.added", "output_index": 0,
                                             "item": functionItem(arguments: "", status: "in_progress")]))
        XCTAssertEqual(start[0].toolCallDelta?.id, "call_real")
        let delta = try parser.consume(event(["type": "response.function_call_arguments.delta", "output_index": 0,
                                             "item_id": "fc_item", "delta": "{}"] ))
        XCTAssertNil(delta[0].toolCallDelta?.id)
        let done = try parser.consume(event(["type": "response.function_call_arguments.done", "output_index": 0,
                                            "item_id": "fc_item", "arguments": "{}"] ))
        XCTAssertTrue(done.isEmpty)
        let item = try parser.consume(event(["type": "response.output_item.done", "output_index": 0, "item": functionItem()]))
        XCTAssertEqual(item.compactMap { $0.toolCallDelta?.argumentsDelta }.joined(), "")
        let end = try parser.consume(completed([functionItem()]))
        XCTAssertTrue(end.last!.toolsMayExecute)
        XCTAssertEqual(end.last?.finishReason, "completed")
        try parser.finish()
    }

    func testResponsesFinalSnapshotSuppliesMissingToolDeltas() throws {
        var parser = ProviderStreamParser(api: .responses)
        let chunks = try parser.consume(completed([functionItem(arguments: "{\"q\":1}")]))
        XCTAssertEqual(chunks.compactMap { $0.toolCallDelta?.argumentsDelta }.joined(), "{\"q\":1}")
        XCTAssertTrue(chunks.last!.toolsMayExecute)
    }

    func testResponsesRejectsMismatchedItemIDAndArguments() throws {
        var parser = ProviderStreamParser(api: .responses)
        _ = try parser.consume(event(["type": "response.output_item.added", "output_index": 0, "item": functionItem(arguments: "", status: "in_progress")]))
        assertFailure(.invalidToolCall) {
            _ = try parser.consume(event(["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "wrong", "delta": "{} "]))
        }
        _ = try parser.consume(event(["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "fc_item", "delta": "{\"x\":1}"]))
        assertFailure(.invalidToolCall) { _ = try parser.consume(completed([functionItem(arguments: "{\"x\":2}")])) }
    }

    func testResponsesRejectsIncompleteFailureMissingAndUnfinishedOutput() throws {
        for type in ["response.failed", "response.incomplete", "response.cancelled"] {
            var parser = ProviderStreamParser(api: .responses)
            assertFailure(.rejectedCompletion) { _ = try parser.consume(event(["type": type])) }
        }
        var parser = ProviderStreamParser(api: .responses)
        assertFailure(.rejectedCompletion) { _ = try parser.consume(event(["type": "response.completed", "response": ["status": "incomplete", "output": []]])) }
        assertFailure(.rejectedCompletion) { _ = try parser.consume(completed([functionItem(status: "in_progress")])) }
        assertFailure(.incompleteStream) { _ = try parser.consume(ProviderSSEEvent(data: "[DONE]")) }
    }

    func testResponsesTextDoneAddsOnlyMissingSuffixAndHostedSearchNeverBecomesClientTool() throws {
        var parser = ProviderStreamParser(api: .responses)
        _ = try parser.consume(event(["type": "response.web_search_call.completed", "output_index": 0]))
        _ = try parser.consume(event(["type": "response.output_text.delta", "output_index": 1, "content_index": 0, "delta": "Hello "]))
        let done = try parser.consume(event(["type": "response.output_text.done", "output_index": 1, "content_index": 0, "text": "Hello 🌍"]))
        XCTAssertEqual(done.first?.textDelta, "🌍")
        let end = try parser.consume(completed([["type": "web_search_call", "status": "completed"], ["type": "message", "status": "completed"]]))
        XCTAssertFalse(end.last!.toolsMayExecute)
    }

    private func startAnthropic(_ parser: inout ProviderStreamParser, input: [String: Any] = [:]) throws {
        _ = try parser.consume(event(["type": "message_start", "message": ["role": "assistant"]]))
        _ = try parser.consume(event(["type": "content_block_start", "index": 0,
                                      "content_block": ["type": "tool_use", "id": "toolu_1", "name": "lookup", "input": input]]))
    }

    func testAnthropicEmptyObjectCallAndTerminalStopReason() throws {
        var parser = ProviderStreamParser(api: .anthropic)
        try startAnthropic(&parser)
        let stop = try parser.consume(event(["type": "content_block_stop", "index": 0]))
        XCTAssertEqual(stop.first?.toolCallDelta?.argumentsDelta, "{}")
        let reason = try parser.consume(event(["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        XCTAssertFalse(reason.first!.isFinished)
        let end = try parser.consume(event(["type": "message_stop"]))
        XCTAssertEqual(end.last?.finishReason, "tool_use")
        XCTAssertTrue(end.last!.toolsMayExecute)
        try parser.finish()
    }

    func testAnthropicInitialInputAndFragmentedArguments() throws {
        var initial = ProviderStreamParser(api: .anthropic)
        try startAnthropic(&initial, input: ["a": 1])
        let stop = try initial.consume(event(["type": "content_block_stop", "index": 0]))
        XCTAssertEqual(stop.first?.toolCallDelta?.argumentsDelta, "{\"a\":1}")
        var streamed = ProviderStreamParser(api: .anthropic)
        try startAnthropic(&streamed)
        for fragment in ["{\"a\":", "1}"] {
            _ = try streamed.consume(event(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": fragment]]))
        }
        XCTAssertTrue(try streamed.consume(event(["type": "content_block_stop", "index": 0])).isEmpty)
        _ = try streamed.consume(event(["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        XCTAssertTrue(try streamed.consume(event(["type": "message_stop"])).last!.toolsMayExecute)
    }

    func testAnthropicRejectsOpenBlocksMissingReasonAndTokenLimit() throws {
        var parser = ProviderStreamParser(api: .anthropic)
        try startAnthropic(&parser)
        assertFailure(.incompleteStream) { _ = try parser.consume(event(["type": "message_stop"])) }
        _ = try parser.consume(event(["type": "content_block_stop", "index": 0]))
        assertFailure(.incompleteStream) { _ = try parser.consume(event(["type": "message_stop"])) }
        assertFailure(.rejectedCompletion) { _ = try parser.consume(event(["type": "message_delta", "delta": ["stop_reason": "max_tokens"]])) }
    }

    func testAllAPIsRejectErrorsWithoutEchoingProviderBody() throws {
        for api in [ProviderAPI.chatCompletions, .responses, .anthropic] {
            var parser = ProviderStreamParser(api: api)
            XCTAssertThrowsError(try parser.consume(event(["type": "error", "error": ["message": "Authorization Bearer secret", "type": "secret"]]))) { error in
                XCTAssertEqual(error as? ProviderServiceError, .serverError)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        let wrapped = NSError(domain: "network", code: 0, userInfo: [NSLocalizedDescriptionKey: "secret"])
        XCTAssertFalse(ProviderServiceError.sanitized(wrapped).localizedDescription.contains("secret"))
    }

    func testEndpointNormalizationAndQueryPreservation() throws {
        for base in ["https://fixture.invalid", "https://fixture.invalid/", "https://fixture.invalid/v1", "https://fixture.invalid/v1/", "https://fixture.invalid/v1/messages/"] {
            var p = provider(.anthropic)
            p.baseURL = base
            XCTAssertEqual(try ProviderRequestBuilder.endpoint(for: p).absoluteString, "https://fixture.invalid/v1/messages")
            XCTAssertEqual(try ProviderRequestBuilder.endpoint(for: p, models: true).absoluteString, "https://fixture.invalid/v1/models")
        }
        var p = provider(.responses)
        p.baseURL = "https://fixture.invalid/prefix/v1/chat/completions/?api-version=2025-01-01"
        XCTAssertEqual(try ProviderRequestBuilder.endpoint(for: p).absoluteString, "https://fixture.invalid/prefix/v1/responses?api-version=2025-01-01")
        p.endpointMode = "chat_completions"
        p.baseURL = "https://fixture.invalid/v1/responses/"
        XCTAssertEqual(ProviderRequestBuilder.api(for: p), .responses)
        XCTAssertEqual(try ProviderRequestBuilder.endpoint(for: p, models: true).path, "/v1/models")
        p.baseURL = "https://fixture.invalid/chat/completions/"
        XCTAssertEqual(try ProviderRequestBuilder.endpoint(for: p).path, "/chat/completions")
        XCTAssertEqual(try ProviderRequestBuilder.endpoint(for: p, models: true).path, "/models")
    }

    func testRejectsEmbeddedURLCredentialsAndUnsafeHeaders() throws {
        var p = provider()
        for base in ["file:///tmp/api", "https://user:password@fixture.invalid/v1", "https://fixture.invalid/v1#fragment"] {
            p.baseURL = base
            XCTAssertThrowsError(try ProviderRequestBuilder.modelsRequest(provider: p))
        }
        p = provider()
        for header in [CustomHeader(key: "X-Key", value: "secret\r\nHost: evil"), CustomHeader(key: "Bad Name", value: "secret"), CustomHeader(key: "Host", value: "evil"), CustomHeader(key: "Authorization", value: "secret")] {
            p.customHeaders = [header]
            XCTAssertThrowsError(try ProviderRequestBuilder.modelsRequest(provider: p)) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        p.customHeaders = [CustomHeader(key: "X-Region", value: "one"), CustomHeader(key: "x-region", value: "two")]
        XCTAssertThrowsError(try ProviderRequestBuilder.modelsRequest(provider: p))
    }

    func testDraftAuthUsedForModelsAndGenerationIncludingAnthropic() throws {
        for api in [ProviderAPI.chatCompletions, .responses, .anthropic] {
            var p = provider(api)
            p.customHeaders = [CustomHeader(key: "X-Organization", value: "draft-org")]
            let models = try ProviderRequestBuilder.modelsRequest(provider: p)
            let generate = try ProviderRequestBuilder.request(provider: p, modelId: "model", messages: [])
            for request in [models, generate] {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Organization"), "draft-org")
                if api == .anthropic {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "draft-fixture-key")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer draft-fixture-key") }
            }
        }
        var anonymous = provider()
        anonymous.apiKey = ""
        XCTAssertNil(try ProviderRequestBuilder.modelsRequest(provider: anonymous).value(forHTTPHeaderField: "Authorization"))
        anonymous.customHeaders = [CustomHeader(key: "Authorization", value: "Bearer custom-token")]
        XCTAssertEqual(try ProviderRequestBuilder.modelsRequest(provider: anonymous).value(forHTTPHeaderField: "Authorization"), "Bearer custom-token")
    }

    func testSystemRolesAndAssistantContentAcrossProtocols() throws {
        let messages = [Message(role: .system, content: "system history"), Message(role: .assistant, content: "assistant history"), Message(role: .user, content: "question")]
        for api in [ProviderAPI.chatCompletions, .responses, .anthropic] {
            var p = provider(api)
            p.systemPrompt = "provider prompt"
            let body = try ProviderRequestBuilder.body(provider: p, modelId: "model", messages: messages)
            if api == .anthropic {
                XCTAssertEqual(body["system"] as? String, "provider prompt\n\nsystem history")
                let rows = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertEqual(rows.first?["role"] as? String, "assistant")
                XCTAssertEqual(rows.count, 2)
            } else if api == .responses {
                XCTAssertEqual(body["instructions"] as? String, "provider prompt")
                let rows = try XCTUnwrap(body["input"] as? [[String: Any]])
                XCTAssertEqual(rows.first?["role"] as? String, "system")
                XCTAssertEqual(rows[1]["content"] as? String, "assistant history")
            } else {
                let rows = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertEqual(rows[0]["content"] as? String, "provider prompt")
                XCTAssertEqual(rows[1]["role"] as? String, "system")
            }
        }
    }

    func testHistoryReplaysCorrectCallIDsAndDeduplicatesExplicitResults() throws {
        let calls = [ToolCall(id: "call_a", name: "lookup", arguments: "{}", output: "stored a"), ToolCall(id: "call_b", name: "lookup", arguments: "{}", output: "stored b")]
        let messages = [Message(role: .assistant, content: "", toolCalls: calls), Message(role: .tool, content: "explicit a", toolCallId: "call_a")]
        for api in [ProviderAPI.chatCompletions, .responses, .anthropic] {
            let body = try ProviderRequestBuilder.body(provider: provider(api), modelId: "model", messages: messages)
            let data = try JSONSerialization.data(withJSONObject: body)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("stored a"))
            XCTAssertTrue(text.contains("explicit a"))
            XCTAssertTrue(text.contains("stored b"))
            if api == .anthropic {
                let rows = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertEqual(rows.count, 2)
                let results = try XCTUnwrap(rows[1]["content"] as? [[String: Any]])
                XCTAssertEqual(Set(results.compactMap { $0["tool_use_id"] as? String }), ["call_a", "call_b"])
            } else if api == .responses {
                let rows = try XCTUnwrap(body["input"] as? [[String: Any]])
                XCTAssertEqual(rows.filter { $0["type"] as? String == "function_call_output" }.count, 2)
            }
        }
    }

    func testRejectsMissingOrUnmatchedHistoricalToolResults() throws {
        for messages in [[Message(role: .tool, content: "result")], [Message(role: .assistant, content: "", toolCalls: [ToolCall(id: "a", name: "lookup", arguments: "{}")])]] {
            assertFailure(.invalidHistory) { _ = try ProviderRequestBuilder.body(provider: provider(), modelId: "model", messages: messages) }
        }
    }

    func testPDFImageAndTextAttachmentsHaveNativeWireParts() throws {
        let attachments = [MessageAttachment(name: "a.pdf", mimeType: "application/pdf", dataBase64: Data("%PDF fixture".utf8).base64EncodedString()),
                           MessageAttachment(name: "a.png", mimeType: "image/png", dataBase64: Data([1, 2, 3]).base64EncodedString()),
                           MessageAttachment(name: "a.txt", mimeType: "text/plain", dataBase64: Data("file content".utf8).base64EncodedString())]
        for api in [ProviderAPI.chatCompletions, .responses, .anthropic] {
            let body = try ProviderRequestBuilder.body(provider: provider(api), modelId: "model", messages: [Message(role: .user, content: "Read", attachments: attachments)])
            let rows = try XCTUnwrap(body[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(rows[0]["content"] as? [[String: Any]])
            let types = parts.compactMap { $0["type"] as? String }
            XCTAssertEqual(types, api == .responses ? ["input_text", "input_file", "input_image", "input_text"] : (api == .anthropic ? ["text", "document", "image", "text"] : ["text", "file", "image_url", "text"]))
        }
    }

    func testUnsupportedOrInvalidAttachmentsFailRatherThanInventingAFileSummary() throws {
        for (mime, base64, expected) in [("application/zip", "YWJj", ProviderServiceError.unsupportedAttachment), ("image/png", "invalid", .invalidAttachment), ("text/plain", "/w==", .invalidAttachment)] {
            let message = Message(role: .user, content: "", attachments: [MessageAttachment(name: "file", mimeType: mime, dataBase64: base64)])
            assertFailure(expected) { _ = try ProviderRequestBuilder.body(provider: provider(), modelId: "model", messages: [message]) }
        }
    }

    func testResponsesStoreFalseHostedSearchSwitchAndReasoningOptions() throws {
        var p = provider(.responses)
        p.hostedWebSearchEnabled = true
        p.reasoningEffort = "high"
        p.maxOutputTokens = 2000
        p.customRequestBodyJSON = "{\"temperature\":0.3,\"reasoning\":{\"summary\":\"auto\"}}"
        let enabled = try ProviderRequestBuilder.body(provider: p, modelId: "model", messages: [])
        XCTAssertEqual(enabled["store"] as? Bool, false)
        XCTAssertEqual(enabled["max_output_tokens"] as? Int, 2000)
        XCTAssertEqual((enabled["reasoning"] as? [String: String])?["effort"], "high")
        XCTAssertEqual((enabled["reasoning"] as? [String: String])?["summary"], "auto")
        XCTAssertEqual((enabled["tools"] as? [[String: String]])?.first?["type"], "web_search")
        let disabled = try ProviderRequestBuilder.body(provider: p, modelId: "model", messages: [], hostedWebSearchEnabled: false)
        XCTAssertNil(disabled["tools"])
        for json in ["[]", "{invalid", "{\"store\":true}", "{\"tools\":[]}", "{\"stream\":false}", "{\"n\":2}"] {
            XCTAssertThrowsError(try ProviderRequestBuilder.additionalBody(json))
        }
    }

    func testResponsesToolConversionPreservesOptionalSchemaAndAnthropicUsesInputSchema() throws {
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "lookup", "parameters": ["type": "object", "properties": [:]]]]]
        for api in [ProviderAPI.responses, .anthropic] {
            let body = try ProviderRequestBuilder.body(provider: provider(api), modelId: "model", messages: [], tools: tools)
            let converted = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
            XCTAssertEqual(converted["name"] as? String, "lookup")
            XCTAssertNotNil(converted[api == .responses ? "parameters" : "input_schema"])
            if api == .responses { XCTAssertEqual(converted["strict"] as? Bool, false) }
        }
    }

    func testLegacyCodableDefaultsAndNewSettingsRoundTrip() throws {
        let legacy = try JSONDecoder().decode(ModelProvider.self, from: Data(#"{"id":"p","name":"Old","type":"anthropic","models":[{"id":"real-id"}],"customHeaders":[{"key":"X-Test","value":"1"}]}"#.utf8))
        XCTAssertEqual(legacy.defaultModelId, "real-id")
        XCTAssertEqual(legacy.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(legacy.anthropicVersion, "2023-06-01")
        XCTAssertEqual(legacy.customRequestBodyJSON, "")
        XCTAssertEqual(legacy.reasoningEffort, "")
        XCTAssertNil(legacy.maxOutputTokens)
        XCTAssertTrue(legacy.isEnabled)
        XCTAssertEqual(legacy.models[0].name, "real-id")
        XCTAssertFalse(legacy.models[0].supportsVision)
        var p = provider(.responses)
        p.customRequestBodyJSON = "{\"temperature\":0.7}"
        p.maxOutputTokens = 500
        p.reasoningEffort = "low"
        XCTAssertEqual(try JSONDecoder().decode(ModelProvider.self, from: JSONEncoder().encode(p)), p)
        XCTAssertEqual(try ProviderRequestBuilder.validateModelID("  actual/model-id \n"), "actual/model-id")
        XCTAssertThrowsError(try ProviderRequestBuilder.validateModelID("bad id"))
    }

    func testModelDiscoveryParsesDisplayNamesPaginationAndFailsVisibly() throws {
        let page = try ProviderRequestBuilder.parseModels(Data(#"{"data":[{"id":"claude-model","display_name":"Claude"},{"id":"claude-model"}],"has_more":true,"last_id":"claude-model"}"#.utf8), anthropic: true)
        XCTAssertEqual(page.models.count, 1)
        XCTAssertEqual(page.models.first?.name, "Claude")
        XCTAssertEqual(page.nextID, "claude-model")
        for json in [#"{"error":{"message":"secret"}}"#, #"{"data":[{}]}"#, #"{"data":[],"has_more":true}"#] {
            assertFailure(.invalidResponse) { _ = try ProviderRequestBuilder.parseModels(Data(json.utf8), anthropic: true) }
        }
    }
}

/// End-to-end transport fixtures use no live endpoints or credentials.
final class ProviderTransportTests: XCTestCase {
    private func service() -> OpenAIService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderFixtureURLProtocol.self]
        return OpenAIService(configuration: config)
    }

    private func provider(path: String = "ok") -> ModelProvider {
        ModelProvider(name: "Fixture", type: .custom, baseURL: "https://fixture.invalid/\(path)/v1",
                      apiKey: "draft-key", defaultModelId: "actual-model")
    }

    func testStreamThroughURLSessionRetainsMultilineFrames() async throws {
        var text = ""
        var terminal = false
        for try await chunk in service().streamChat(provider: provider(), modelId: "actual-model", messages: [Message(role: .user, content: "Hi")]) {
            text += chunk.textDelta ?? ""
            terminal = terminal || chunk.isFinished
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(terminal)
    }

    func testHTTPErrorNeverReturnsCredentialBearingBody() async {
        do {
            for try await _ in service().streamChat(provider: provider(path: "denied"), modelId: "actual-model", messages: []) {}
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? ProviderServiceError, .http(401))
            XCTAssertFalse(error.localizedDescription.contains("credential-body"))
        }
    }

    func testHTTP200JSONIsNotAcceptedAsACompletedStream() async {
        do {
            for try await _ in service().streamChat(provider: provider(path: "json"), modelId: "actual-model", messages: []) {}
            XCTFail("Expected a format error")
        } catch { XCTAssertEqual(error as? ProviderServiceError, .invalidResponse) }
    }

    func testEOFWithoutTerminalFails() async {
        do {
            for try await _ in service().streamChat(provider: provider(path: "truncated"), modelId: "actual-model", messages: []) {}
            XCTFail("Expected a truncation error")
        } catch { XCTAssertEqual(error as? ProviderServiceError, .incompleteStream) }
    }

    func testDiscoveryAndRealModelTestUseDraftRequests() async throws {
        let client = service()
        let models = try await client.fetchModels(provider: provider())
        XCTAssertEqual(models.map(\.id), ["actual-model"])
        try await client.testModel(provider: provider(), modelId: "actual-model")
    }

    func testCancellationStopsAWaitingStreamWithoutSuccessfulTerminal() async throws {
        let client = service()
        let p = provider(path: "stall")
        let task = Task {
            var sawTerminal = false
            for try await chunk in client.streamChat(provider: p, modelId: "actual-model", messages: []) {
                sawTerminal = sawTerminal || chunk.isFinished
            }
            return sawTerminal
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            let completed = try await task.value
            XCTAssertFalse(completed, "A cancelled consumer must never observe a successful terminal")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAnthropicDiscoveryFollowsPaginationWithDraftHeaders() async throws {
        var p = provider(path: "anthropic")
        p.type = .anthropic
        let models = try await service().fetchModels(provider: p)
        XCTAssertEqual(models.map(\.id), ["model-one", "model-two"])
    }
}

private final class ProviderFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        var status = 200
        var contentType = "text/event-stream"
        var body = "data: {\n\ndata: invalid\n\n"
        let correctAuth = path.contains("anthropic")
            ? request.value(forHTTPHeaderField: "x-api-key") == "draft-key" && request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01" && request.value(forHTTPHeaderField: "Authorization") == nil
            : request.value(forHTTPHeaderField: "Authorization") == "Bearer draft-key"
        if !correctAuth {
            status = 403
            body = "wrong draft auth"
        } else if path.contains("denied") {
            status = 401
            body = "credential-body Authorization Bearer draft-key"
        } else if path.contains("json") {
            contentType = "application/json"
            body = "{}"
        } else if path.contains("anthropic"), path.hasSuffix("/models") {
            contentType = "application/json"
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after_id" }?.value
            body = cursor == nil
                ? #"{"data":[{"id":"model-one"}],"has_more":true,"last_id":"model-one"}"#
                : #"{"data":[{"id":"model-two"}],"has_more":false,"last_id":"model-two"}"#
        } else if path.hasSuffix("/models") {
            contentType = "application/json"
            body = #"{"data":[{"id":"actual-model"}]}"#
        } else {
            body = "data: {\r\ndata: \"choices\":[{\"delta\":{\"content\":\"Hello\"},\"index\":0}]}\r\n\r\n"
            if !path.contains("truncated") {
                body += "data:{\"choices\":[{\"delta\":{},\"index\":0,\"finish_reason\":\"stop\"}]}\n\ndata:[DONE]\n\n"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path.contains("stall") { return }
        for byte in Data(body.utf8) { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
