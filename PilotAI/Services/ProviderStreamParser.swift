import Foundation

public struct ToolCallDelta {
    public let index: Int
    public let id: String?
    public let name: String?
    public let argumentsDelta: String

    public init(index: Int, id: String? = nil, name: String? = nil, argumentsDelta: String = "") {
        self.index = index
        self.id = id
        self.name = name
        self.argumentsDelta = argumentsDelta
    }
}

public struct StreamChunk {
    public let textDelta: String?
    public let reasoningDelta: String?
    public let toolCallDelta: ToolCallDelta?
    public let isFinished: Bool
    public let finishReason: String?
    /// True only on a verified terminal event with complete, valid client tool calls.
    /// Consumers must also wait for successful stream exhaustion before dispatching tools.
    public let toolsMayExecute: Bool

    public init(textDelta: String? = nil, reasoningDelta: String? = nil, toolCallDelta: ToolCallDelta? = nil,
                isFinished: Bool = false, finishReason: String? = nil, toolsMayExecute: Bool = false) {
        self.textDelta = textDelta
        self.reasoningDelta = reasoningDelta
        self.toolCallDelta = toolCallDelta
        self.isFinished = isFinished
        self.finishReason = finishReason
        self.toolsMayExecute = isFinished && toolsMayExecute
    }
}

public struct ProviderSSEEvent: Equatable {
    public let event: String?
    public let data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Byte-oriented SSE framing. Preserves blank lines, split UTF-8, CR/LF/CRLF and multiline data.
/// An unterminated final event is never dispatched (the SSE EOF rule).
public struct ProviderSSEDecoder {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventName: String?
    private var skipLF = false
    private var firstLine = true
    private var frameBytes = 0
    public let maximumFrameBytes: Int

    public init(maximumFrameBytes: Int = 2 * 1024 * 1024) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    public mutating func append(_ bytes: Data) throws -> [ProviderSSEEvent] {
        var result: [ProviderSSEEvent] = []
        for byte in bytes {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try completeLine() { result.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
                guard line.count + frameBytes <= maximumFrameBytes else { throw ProviderServiceError.streamLimit }
            }
        }
        return result
    }

    private mutating func completeLine() throws -> ProviderSSEEvent? {
        guard var value = String(data: line, encoding: .utf8) else { throw ProviderServiceError.malformedStream }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        }
        if value.isEmpty {
            let result = dataLines.isEmpty ? nil : ProviderSSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            frameBytes = 0
            return result
        }
        if value.hasPrefix(":") { return nil }
        let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var payload = pieces.count > 1 ? String(pieces[1]) : ""
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if field == "data" {
            frameBytes += payload.utf8.count + 1
            guard frameBytes <= maximumFrameBytes else { throw ProviderServiceError.streamLimit }
            dataLines.append(payload)
        } else if field == "event" {
            eventName = payload.isEmpty ? nil : payload
            frameBytes += payload.utf8.count
            guard frameBytes <= maximumFrameBytes else { throw ProviderServiceError.streamLimit }
        }
        return nil
    }
}

/// Stateful, transport-independent wire parser. Invalid/truncated streams never get a safe terminal.
public struct ProviderStreamParser {
    public let api: ProviderAPI
    public private(set) var isFinished = false
    public private(set) var finishReason: String?
    private var decoder = ProviderSSEDecoder()
    private var calls: [Int: Call] = [:]
    private var itemIndices: [String: Int] = [:]
    private var textByPart: [String: String] = [:]
    private var openBlocks = Set<Int>()
    private var blockTypes: [Int: String] = [:]
    private var messageStarted = false
    private var refused = false
    private var totalBytes = 0

    private struct Call {
        var id = ""
        var name = ""
        var arguments = ""
        var itemID: String?
        var done = false
        var initialInput = "{}"
    }

    public init(api: ProviderAPI) { self.api = api }

    public mutating func append(_ data: Data) throws -> [StreamChunk] {
        totalBytes += data.count
        guard totalBytes <= 32 * 1024 * 1024 else { throw ProviderServiceError.streamLimit }
        var result: [StreamChunk] = []
        for event in try decoder.append(data) {
            result.append(contentsOf: try consume(event))
        }
        return result
    }

    public func finish() throws {
        guard isFinished else { throw ProviderServiceError.incompleteStream }
    }

    public mutating func consume(_ event: ProviderSSEEvent) throws -> [StreamChunk] {
        if event.event == "error" { throw ProviderServiceError.serverError }
        if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            if isFinished { return [] }
            guard api == .chatCompletions, let reason = finishReason else { throw ProviderServiceError.incompleteStream }
            return [try terminal(reason: reason, permitsTools: reason == "tool_calls")]
        }
        if event.data.isEmpty { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
            throw ProviderServiceError.malformedStream
        }
        if let error = json["error"], !(error is NSNull) { throw ProviderServiceError.serverError }
        let type = json["type"] as? String ?? event.event ?? ""
        if type == "error" { throw ProviderServiceError.serverError }
        guard !isFinished else { throw ProviderServiceError.malformedStream }
        switch api {
        case .chatCompletions: return try chat(json)
        case .responses: return try responses(json, type: type)
        case .anthropic: return try anthropic(json, type: type)
        }
    }

    private mutating func chat(_ json: [String: Any]) throws -> [StreamChunk] {
        guard let choices = json["choices"] as? [[String: Any]] else { throw ProviderServiceError.malformedStream }
        // Usage-only chunks are valid, including after finish_reason and before [DONE].
        if choices.isEmpty { return [] }
        guard choices.count == 1, let choice = choices.first,
              (choice["index"] as? Int ?? 0) == 0, finishReason == nil,
              let delta = choice["delta"] as? [String: Any] else { throw ProviderServiceError.malformedStream }
        var result: [StreamChunk] = []
        let text = delta["content"] as? String
        let reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String
        if text != nil || reasoning != nil { result.append(StreamChunk(textDelta: text, reasoningDelta: reasoning)) }
        if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
            refused = true
            result.append(StreamChunk(textDelta: refusal))
        }
        if delta["function_call"] != nil { throw ProviderServiceError.invalidToolCall }
        if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
            for tool in toolDeltas {
                guard let index = tool["index"] as? Int,
                      tool["type"] == nil || tool["type"] as? String == "function" else { throw ProviderServiceError.invalidToolCall }
                let function = tool["function"] as? [String: Any] ?? [:]
                result.append(try updateCall(index: index, id: tool["id"] as? String, name: function["name"] as? String,
                                             arguments: function["arguments"] as? String ?? "", fragmentedName: true))
            }
        }
        if let reason = choice["finish_reason"] as? String {
            guard ["stop", "tool_calls"].contains(reason) else { throw ProviderServiceError.rejectedCompletion }
            finishReason = reason
            result.append(StreamChunk(finishReason: reason))
        }
        return result
    }

    private mutating func responses(_ json: [String: Any], type: String) throws -> [StreamChunk] {
        switch type {
        case "response.failed", "response.incomplete", "response.cancelled":
            throw ProviderServiceError.rejectedCompletion
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = json["delta"] as? String else { throw ProviderServiceError.malformedStream }
            if type == "response.refusal.delta" { refused = true }
            let key = partKey(json)
            textByPart[key, default: ""] += delta
            return [StreamChunk(textDelta: delta)]
        case "response.output_text.done", "response.refusal.done":
            guard let full = json[type == "response.refusal.done" ? "refusal" : "text"] as? String else { throw ProviderServiceError.malformedStream }
            if type == "response.refusal.done" { refused = true }
            let key = partKey(json)
            let previous = textByPart[key] ?? ""
            guard full.hasPrefix(previous) else { throw ProviderServiceError.malformedStream }
            textByPart[key] = full
            let suffix = String(full.dropFirst(previous.count))
            return suffix.isEmpty ? [] : [StreamChunk(textDelta: suffix)]
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = json["delta"] as? String else { throw ProviderServiceError.malformedStream }
            return [StreamChunk(reasoningDelta: delta)]
        case "response.output_item.added", "response.output_item.done":
            guard let item = json["item"] as? [String: Any], let index = json["output_index"] as? Int else { throw ProviderServiceError.malformedStream }
            if let status = item["status"] as? String, ["incomplete", "failed", "cancelled"].contains(status) { throw ProviderServiceError.rejectedCompletion }
            if item["type"] as? String == "function_call" {
                return try responseCall(item, index: index, complete: type == "response.output_item.done")
            }
            return []
        case "response.function_call_arguments.delta":
            let index = try responseCallIndex(json)
            guard let delta = json["delta"] as? String, calls[index]?.done != true else { throw ProviderServiceError.invalidToolCall }
            // item_id is NOT call_id. The result linkage always comes from the function_call item.
            return [try updateCall(index: index, arguments: delta)]
        case "response.function_call_arguments.done":
            let index = try responseCallIndex(json)
            guard let full = json["arguments"] as? String else { throw ProviderServiceError.invalidToolCall }
            return try completeArguments(index: index, full: full)
        case "response.completed":
            guard let response = json["response"] as? [String: Any], response["status"] as? String == "completed",
                  response["error"] == nil || response["error"] is NSNull,
                  response["incomplete_details"] == nil || response["incomplete_details"] is NSNull,
                  let output = response["output"] as? [[String: Any]] else { throw ProviderServiceError.rejectedCompletion }
            var result: [StreamChunk] = []
            var finalCalls = Set<Int>()
            for (index, item) in output.enumerated() {
                if let status = item["status"] as? String, status != "completed" { throw ProviderServiceError.rejectedCompletion }
                if item["type"] as? String == "function_call" {
                    finalCalls.insert(index)
                    result.append(contentsOf: try responseCall(item, index: index, complete: true))
                }
                if let content = item["content"] as? [[String: Any]], content.contains(where: { $0["type"] as? String == "refusal" }) { refused = true }
            }
            guard finalCalls == Set(calls.keys) else { throw ProviderServiceError.invalidToolCall }
            result.append(try terminal(reason: "completed", permitsTools: true))
            return result
        default:
            // Created, usage, hosted-tool, annotation and future informational events are not client calls.
            return []
        }
    }

    private func partKey(_ json: [String: Any]) -> String {
        "\(json["output_index"] as? Int ?? 0):\(json["content_index"] as? Int ?? 0)"
    }

    private func responseCallIndex(_ json: [String: Any]) throws -> Int {
        guard let index = json["output_index"] as? Int, let call = calls[index] else { throw ProviderServiceError.invalidToolCall }
        if let itemID = json["item_id"] as? String {
            guard call.itemID == itemID, itemIndices[itemID] == index else { throw ProviderServiceError.invalidToolCall }
        }
        return index
    }

    private mutating func responseCall(_ item: [String: Any], index: Int, complete: Bool) throws -> [StreamChunk] {
        guard let id = item["call_id"] as? String, !id.isEmpty,
              let name = item["name"] as? String, !name.isEmpty else { throw ProviderServiceError.invalidToolCall }
        var result = [try updateCall(index: index, id: id, name: name)]
        if let itemID = item["id"] as? String {
            if let known = calls[index]?.itemID, known != itemID { throw ProviderServiceError.invalidToolCall }
            if let known = itemIndices[itemID], known != index { throw ProviderServiceError.invalidToolCall }
            itemIndices[itemID] = index
            calls[index]?.itemID = itemID
        }
        if complete {
            guard let arguments = item["arguments"] as? String else { throw ProviderServiceError.invalidToolCall }
            result.append(contentsOf: try completeArguments(index: index, full: arguments))
            calls[index]?.done = true
        } else if let arguments = item["arguments"] as? String, !arguments.isEmpty {
            result.append(try updateCall(index: index, arguments: arguments))
        }
        return result
    }

    private mutating func anthropic(_ json: [String: Any], type: String) throws -> [StreamChunk] {
        switch type {
        case "message_start":
            guard !messageStarted, json["message"] is [String: Any] else { throw ProviderServiceError.malformedStream }
            messageStarted = true
        case "content_block_start":
            guard messageStarted, finishReason == nil, let index = json["index"] as? Int,
                  index >= 0, index <= 1024, blockTypes[index] == nil,
                  let block = json["content_block"] as? [String: Any], let blockType = block["type"] as? String else { throw ProviderServiceError.malformedStream }
            openBlocks.insert(index)
            blockTypes[index] = blockType
            if blockType == "tool_use" {
                guard let id = block["id"] as? String, !id.isEmpty, let name = block["name"] as? String, !name.isEmpty,
                      let input = block["input"] as? [String: Any], JSONSerialization.isValidJSONObject(input) else { throw ProviderServiceError.invalidToolCall }
                let delta = try updateCall(index: index, id: id, name: name)
                calls[index]?.initialInput = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
                return [delta]
            } else if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                return [StreamChunk(textDelta: text)]
            } else if blockType == "thinking", let text = block["thinking"] as? String, !text.isEmpty {
                return [StreamChunk(reasoningDelta: text)]
            }
        case "content_block_delta":
            guard messageStarted, finishReason == nil, let index = json["index"] as? Int, openBlocks.contains(index),
                  let delta = json["delta"] as? [String: Any] else { throw ProviderServiceError.malformedStream }
            switch delta["type"] as? String {
            case "text_delta":
                guard blockTypes[index] == "text", let text = delta["text"] as? String else { throw ProviderServiceError.malformedStream }
                return [StreamChunk(textDelta: text)]
            case "thinking_delta":
                guard blockTypes[index] == "thinking", let text = delta["thinking"] as? String else { throw ProviderServiceError.malformedStream }
                return [StreamChunk(reasoningDelta: text)]
            case "input_json_delta":
                if blockTypes[index] == "server_tool_use" { return [] }
                guard blockTypes[index] == "tool_use", let arguments = delta["partial_json"] as? String else { throw ProviderServiceError.invalidToolCall }
                return [try updateCall(index: index, arguments: arguments)]
            default: break
            }
        case "content_block_stop":
            guard let index = json["index"] as? Int, openBlocks.remove(index) != nil else { throw ProviderServiceError.malformedStream }
            if let call = calls[index] {
                var result: [StreamChunk] = []
                if call.arguments.isEmpty { result = [try updateCall(index: index, arguments: call.initialInput)] }
                try validateCall(calls[index]!)
                calls[index]?.done = true
                return result
            }
        case "message_delta":
            guard messageStarted, let delta = json["delta"] as? [String: Any] else { throw ProviderServiceError.malformedStream }
            if let reason = delta["stop_reason"] as? String {
                guard openBlocks.isEmpty, finishReason == nil, ["end_turn", "stop_sequence", "tool_use", "refusal"].contains(reason) else { throw ProviderServiceError.rejectedCompletion }
                if reason == "refusal" { refused = true }
                finishReason = reason
                return [StreamChunk(finishReason: reason)]
            }
        case "message_stop":
            guard messageStarted, openBlocks.isEmpty, let reason = finishReason else { throw ProviderServiceError.incompleteStream }
            return [try terminal(reason: reason, permitsTools: reason == "tool_use")]
        default: break
        }
        return []
    }

    private mutating func updateCall(index: Int, id: String? = nil, name: String? = nil, arguments: String = "", fragmentedName: Bool = false) throws -> StreamChunk {
        guard index >= 0, index <= 1024, calls[index] != nil || calls.count < 128 else { throw ProviderServiceError.invalidToolCall }
        var call = calls[index] ?? Call()
        if let id, !id.isEmpty {
            guard call.id.isEmpty || call.id == id else { throw ProviderServiceError.invalidToolCall }
            call.id = id
        }
        if let name, !name.isEmpty, name != call.name {
            guard fragmentedName || call.name.isEmpty else { throw ProviderServiceError.invalidToolCall }
            call.name += name
        }
        guard call.id.utf8.count <= 256, call.name.utf8.count <= 128,
              call.arguments.utf8.count + arguments.utf8.count <= 256 * 1024,
              !call.done || arguments.isEmpty else { throw ProviderServiceError.invalidToolCall }
        call.arguments += arguments
        calls[index] = call
        return StreamChunk(toolCallDelta: ToolCallDelta(index: index, id: id, name: name, argumentsDelta: arguments))
    }

    private mutating func completeArguments(index: Int, full: String) throws -> [StreamChunk] {
        guard let call = calls[index], full.hasPrefix(call.arguments) else { throw ProviderServiceError.invalidToolCall }
        let suffix = String(full.dropFirst(call.arguments.count))
        let result = suffix.isEmpty ? [] : [try updateCall(index: index, arguments: suffix)]
        try validateCall(calls[index]!)
        return result
    }

    private func validateCall(_ call: Call) throws {
        guard !call.id.isEmpty, !call.name.isEmpty,
              !call.id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let arguments = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)), arguments is [String: Any] else { throw ProviderServiceError.invalidToolCall }
    }

    private mutating func terminal(reason: String, permitsTools: Bool) throws -> StreamChunk {
        guard !isFinished else { throw ProviderServiceError.malformedStream }
        if !calls.isEmpty {
            guard permitsTools, !refused else { throw ProviderServiceError.invalidToolCall }
            var ids = Set<String>()
            for call in calls.values {
                try validateCall(call)
                guard ids.insert(call.id).inserted, api == .chatCompletions || call.done else { throw ProviderServiceError.invalidToolCall }
            }
        } else if reason == "tool_calls" || reason == "tool_use" { throw ProviderServiceError.invalidToolCall }
        isFinished = true
        finishReason = reason
        return StreamChunk(isFinished: true, finishReason: reason, toolsMayExecute: permitsTools && !calls.isEmpty && !refused)
    }
}
