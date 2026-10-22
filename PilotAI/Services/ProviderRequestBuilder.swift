import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderAPI: Equatable {
    case chatCompletions, responses, anthropic
}

/// Deliberately excludes response bodies, URLs, credentials and arbitrary server error messages.
public enum ProviderServiceError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidHistory
    case invalidAttachment
    case unsupportedAttachment
    case http(Int)
    case transport(Int)
    case invalidResponse
    case malformedStream
    case streamLimit
    case incompleteStream
    case rejectedCompletion
    case serverError
    case invalidToolCall

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let description): return description
        case .invalidHistory: return "Tool history is incomplete or contains invalid call identifiers. Start a new conversation or remove the incomplete turn."
        case .invalidAttachment: return "An attachment is invalid, is not UTF-8 text, or exceeds the attachment limit."
        case .unsupportedAttachment: return "This attachment type or message role is not supported by the selected provider API."
        case .http(let code):
            switch code {
            case 401, 403: return "Provider authentication failed (HTTP \(code)). Check the draft API key, headers and account access."
            case 404: return "Provider endpoint or model was not found (HTTP 404). Check the base URL, API mode and model ID."
            case 429: return "Provider rate or quota limit reached (HTTP 429)."
            case 300...399: return "Provider redirected the request (HTTP \(code)). Enter the final API base URL."
            default: return "Provider request failed (HTTP \(code))."
            }
        case .transport(let code): return "The provider connection failed (network code \(code)). Check connectivity and the API base URL."
        case .invalidResponse: return "The provider returned an unexpected response format. Check the API endpoint and mode."
        case .malformedStream: return "The provider returned a malformed event stream. No tools were executed."
        case .streamLimit: return "The provider response exceeded the supported streaming limit."
        case .incompleteStream: return "The provider stream ended before a verified completion. No tools were executed."
        case .rejectedCompletion: return "The provider stopped with an incomplete, filtered or unsupported completion. No tools were executed."
        case .serverError: return "The provider reported an error while generating the response. No tools were executed."
        case .invalidToolCall: return "The provider returned an incomplete or inconsistent tool call. No tools were executed."
        }
    }

    public static func sanitized(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? ProviderServiceError { return error }
        if let error = error as? URLError {
            return error.code == .cancelled ? CancellationError() : ProviderServiceError.transport(error.code.rawValue)
        }
        return ProviderServiceError.invalidResponse
    }
}

/// Pure request construction, shared by generation, discovery and draft connection tests.
public enum ProviderRequestBuilder {
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    public static let maxTextAttachmentCharacters = 120_000
    public static let maxTotalAttachmentBytes = 20 * 1024 * 1024

    public static func api(for provider: ModelProvider) -> ProviderAPI {
        if provider.type == .anthropic { return .anthropic }
        let path = URLComponents(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() ?? ""
        return provider.endpointMode.lowercased() == "responses" || path.hasSuffix("/responses") || path == "responses"
            ? .responses : .chatCompletions
    }

    public static func endpoint(for provider: ModelProvider, models: Bool = false) throws -> URL {
        guard var components = URLComponents(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw ProviderServiceError.invalidConfiguration("Enter an HTTP(S) API base URL without embedded credentials or a fragment.")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        var suppliedEndpoint = false
        for suffix in ["/chat/completions", "/responses", "/messages", "/models"] {
            if path.lowercased().hasSuffix(suffix) {
                path.removeLast(suffix.count)
                suppliedEndpoint = true
                break
            }
        }
        // Root URLs and Anthropic's documented /v1 base must not become /v1/v1/messages.
        if path.isEmpty, !suppliedEndpoint || provider.type == .anthropic { path = "/v1" }
        if provider.type == .anthropic, !path.lowercased().hasSuffix("/v1") { path += "/v1" }
        let route = models ? "/models" : (api(for: provider) == .anthropic ? "/messages" : (api(for: provider) == .responses ? "/responses" : "/chat/completions"))
        components.path = path + route
        guard let url = components.url else { throw ProviderServiceError.invalidConfiguration("The API base URL is invalid.") }
        return url
    }

    public static func validateModelID(_ value: String) throws -> String {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 512,
              !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderServiceError.invalidConfiguration("Enter the provider's exact model ID without spaces.")
        }
        return id
    }

    public static func validateHeader(_ header: CustomHeader) throws {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !header.key.isEmpty, header.key.unicodeScalars.allSatisfy({ token.contains($0) }),
              !header.value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ProviderServiceError.invalidConfiguration("Custom headers must have valid names and single-line values.")
        }
        let reserved: Set<String> = ["host", "content-length", "content-type", "accept", "connection", "transfer-encoding", "cookie", "proxy-authorization", "proxy-connection", "trailer", "upgrade", "te"]
        guard !reserved.contains(header.key.lowercased()) else {
            throw ProviderServiceError.invalidConfiguration("A custom header conflicts with an HTTP transport header.")
        }
    }

    public static func modelsRequest(provider: ModelProvider, afterID: String? = nil) throws -> URLRequest {
        var url = try endpoint(for: provider, models: true)
        if provider.type == .anthropic {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = (components.queryItems ?? []).filter { !["after_id", "limit"].contains($0.name) }
            items.append(URLQueryItem(name: "limit", value: "100"))
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = items
            url = components.url!
        }
        return try request(provider: provider, url: url, streaming: false)
    }

    public static func request(
        provider: ModelProvider, modelId: String, messages: [Message], systemPrompt: String? = nil,
        tools: [[String: Any]]? = nil, hostedWebSearchEnabled: Bool? = nil
    ) throws -> URLRequest {
        var result = try request(provider: provider, url: endpoint(for: provider), streaming: true)
        result.httpMethod = "POST"
        let body = try body(provider: provider, modelId: modelId, messages: messages, systemPrompt: systemPrompt,
                            tools: tools, hostedWebSearchEnabled: hostedWebSearchEnabled)
        guard JSONSerialization.isValidJSONObject(body) else { throw ProviderServiceError.invalidConfiguration("The request parameters are not valid JSON.") }
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return result
    }

    private static func request(provider: ModelProvider, url: URL, streaming: Bool) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderServiceError.invalidConfiguration("The API key must be a single token without whitespace.")
        }
        if !key.isEmpty {
            request.setValue(provider.type == .anthropic ? key : "Bearer \(key)",
                             forHTTPHeaderField: provider.type == .anthropic ? "x-api-key" : "Authorization")
        }
        if provider.type == .anthropic {
            let version = provider.anthropicVersion.isEmpty ? "2023-06-01" : provider.anthropicVersion
            try validateHeader(CustomHeader(key: "anthropic-version", value: version))
            request.setValue(version, forHTTPHeaderField: "anthropic-version")
        }
        var keys = Set<String>()
        for header in provider.customHeaders {
            try validateHeader(header)
            let name = header.key.lowercased()
            guard keys.insert(name).inserted else { throw ProviderServiceError.invalidConfiguration("Duplicate custom header names are not allowed.") }
            if !key.isEmpty, ["authorization", "x-api-key"].contains(name) {
                throw ProviderServiceError.invalidConfiguration("Use either the API Key field or a custom authentication header, not both.")
            }
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        return request
    }

    public static func additionalBody(_ json: String) throws -> [String: Any] {
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard json.utf8.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let body = object as? [String: Any] else {
            throw ProviderServiceError.invalidConfiguration("Custom request parameters must be a JSON object smaller than 256 KB.")
        }
        let reserved: Set<String> = ["model", "messages", "input", "system", "instructions", "stream", "tools", "store", "previous_response_id", "conversation", "background", "n"]
        guard reserved.isDisjoint(with: body.keys) else {
            throw ProviderServiceError.invalidConfiguration("Custom JSON cannot replace model, messages, tools, streaming, storage or conversation fields.")
        }
        return body
    }

    public static func body(
        provider: ModelProvider, modelId: String, messages: [Message], systemPrompt: String? = nil,
        tools: [[String: Any]]? = nil, hostedWebSearchEnabled: Bool? = nil
    ) throws -> [String: Any] {
        let mode = api(for: provider)
        let model = try validateModelID(modelId)
        var body = try additionalBody(provider.customRequestBodyJSON)
        let history = try completeHistory(messages)
        var totalBytes = 0
        for message in history {
            for attachment in message.attachments ?? [] {
                guard attachment.dataBase64.utf8.count <= (maxAttachmentBytes + 2) / 3 * 4,
                      let data = Data(base64Encoded: attachment.dataBase64), !data.isEmpty,
                      data.count <= maxAttachmentBytes else { throw ProviderServiceError.invalidAttachment }
                totalBytes += data.count
                guard totalBytes <= maxTotalAttachmentBytes else { throw ProviderServiceError.invalidAttachment }
            }
        }
        let prompt = systemPrompt ?? provider.systemPrompt
        body["model"] = model
        body["stream"] = true
        if let maximum = provider.maxOutputTokens {
            guard maximum > 0 else { throw ProviderServiceError.invalidConfiguration("Maximum output tokens must be positive.") }
            body[mode == .responses ? "max_output_tokens" : (mode == .anthropic ? "max_tokens" : "max_completion_tokens")] = maximum
        }
        if !provider.reasoningEffort.isEmpty {
            guard mode != .anthropic, ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(provider.reasoningEffort) else {
                throw ProviderServiceError.invalidConfiguration("Select a reasoning effort supported by the provider API.")
            }
            if mode == .responses {
                var reasoning = body["reasoning"] as? [String: Any] ?? [:]
                reasoning["effort"] = provider.reasoningEffort
                body["reasoning"] = reasoning
            } else { body["reasoning_effort"] = provider.reasoningEffort }
        }
        switch mode {
        case .chatCompletions:
            var result: [[String: Any]] = []
            if !prompt.isEmpty { result.append(["role": "system", "content": prompt]) }
            for message in history {
                if message.role == .tool {
                    result.append(["role": "tool", "tool_call_id": message.toolCallId!, "content": message.content])
                } else {
                    var item: [String: Any] = ["role": message.role.rawValue]
                    let parts = try content(for: message, mode: mode, provider: provider)
                    item["content"] = message.attachments?.isEmpty != false ? message.content : parts
                    if let calls = message.toolCalls, !calls.isEmpty {
                        item["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any] }
                    }
                    result.append(item)
                }
            }
            body["messages"] = result
            if let tools, !tools.isEmpty { body["tools"] = tools }
        case .responses:
            var input: [[String: Any]] = []
            for message in history {
                if message.role == .tool {
                    input.append(["type": "function_call_output", "call_id": message.toolCallId!, "output": message.content])
                } else {
                    if !message.content.isEmpty || message.attachments?.isEmpty == false || message.toolCalls?.isEmpty != false {
                        // Assistant history uses easy-input string content, never invalid input_text output blocks.
                        let parts = try content(for: message, mode: mode, provider: provider)
                        input.append(["role": message.role.rawValue, "content": message.role == .assistant ? message.content as Any : parts as Any])
                    }
                    for call in message.toolCalls ?? [] {
                        input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments])
                    }
                }
            }
            body["input"] = input
            body["store"] = false
            if !prompt.isEmpty { body["instructions"] = prompt }
            var converted = try convertTools(tools ?? [], mode: mode)
            if hostedWebSearchEnabled ?? provider.hostedWebSearchEnabled { converted.append(["type": "web_search"]) }
            if !converted.isEmpty { body["tools"] = converted }
        case .anthropic:
            var result: [[String: Any]] = []
            var system = prompt.isEmpty ? [] : [prompt]
            func append(_ role: String, _ parts: [[String: Any]]) {
                // All parallel tool results must be in the same following user message.
                if result.last?["role"] as? String == role, let previous = result.last?["content"] as? [[String: Any]] {
                    result[result.count - 1]["content"] = previous + parts
                } else { result.append(["role": role, "content": parts]) }
            }
            for message in history {
                if message.role == .system {
                    let parts = try content(for: message, mode: mode, provider: provider)
                    system.append(contentsOf: parts.compactMap { $0["text"] as? String })
                } else if message.role == .tool {
                    append("user", [["type": "tool_result", "tool_use_id": message.toolCallId!, "content": message.content]])
                } else {
                    var parts = try content(for: message, mode: mode, provider: provider)
                    for call in message.toolCalls ?? [] {
                        let arguments = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8))
                        parts.append(["type": "tool_use", "id": call.id, "name": call.name, "input": arguments])
                    }
                    append(message.role.rawValue, parts)
                }
            }
            body["messages"] = result
            if body["max_tokens"] == nil { body["max_tokens"] = 4096 }
            if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
            if let tools, !tools.isEmpty {
                if let thinking = body["thinking"] as? [String: Any], thinking["type"] as? String != "disabled" {
                    throw ProviderServiceError.invalidConfiguration("Anthropic thinking with client tools requires signed-thinking replay, which this client does not yet support.")
                }
                body["tools"] = try convertTools(tools, mode: mode)
            }
        }
        return body
    }

    private static func completeHistory(_ messages: [Message]) throws -> [Message] {
        var result: [Message] = []
        var pending = Set<String>()
        var seen = Set<String>()
        for (index, message) in messages.enumerated() {
            if message.role == .tool {
                guard message.attachments?.isEmpty != false, let id = message.toolCallId, pending.remove(id) != nil else { throw ProviderServiceError.invalidHistory }
                result.append(message)
                continue
            }
            if message.role != .system, !pending.isEmpty { throw ProviderServiceError.invalidHistory }
            let calls = message.toolCalls ?? []
            if !calls.isEmpty, message.role != .assistant { throw ProviderServiceError.invalidHistory }
            for call in calls {
                guard !call.id.isEmpty, !call.name.isEmpty, seen.insert(call.id).inserted,
                      let value = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)), value is [String: Any] else {
                    throw ProviderServiceError.invalidHistory
                }
                pending.insert(call.id)
            }
            result.append(message)
            for call in calls {
                if let output = call.output, !messages.dropFirst(index + 1).contains(where: { $0.role == .tool && $0.toolCallId == call.id }) {
                    result.append(Message(role: .tool, content: output, toolCallId: call.id))
                    pending.remove(call.id)
                }
            }
        }
        guard pending.isEmpty else { throw ProviderServiceError.invalidHistory }
        return result
    }

    private static func content(for message: Message, mode: ProviderAPI, provider: ModelProvider) throws -> [[String: Any]] {
        let textType = mode == .responses ? "input_text" : "text"
        var parts: [[String: Any]] = message.content.isEmpty ? [] : [["type": textType, "text": message.content]]
        for attachment in message.attachments ?? [] {
            guard let data = Data(base64Encoded: attachment.dataBase64) else { throw ProviderServiceError.invalidAttachment }
            let mime = attachment.mimeType.lowercased()
            if mime.hasPrefix("text/") || ["application/json", "application/xml", "application/yaml", "application/javascript"].contains(mime) {
                guard let text = String(data: data, encoding: .utf8), text.count <= maxTextAttachmentCharacters else { throw ProviderServiceError.invalidAttachment }
                // Assistant attachments are unsupported instead of silently dropping their content.
                guard message.role != .assistant else { throw ProviderServiceError.unsupportedAttachment }
                parts.append(["type": textType, "text": "[Attached file: \(attachment.name)]\n\(text)"])
            } else if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
                guard message.role == .user else { throw ProviderServiceError.unsupportedAttachment }
                let base64 = data.base64EncodedString()
                if mode == .anthropic {
                    parts.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]])
                } else if mode == .responses {
                    parts.append(["type": "input_image", "image_url": "data:\(mime);base64,\(base64)"])
                } else {
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]])
                }
            } else if mime == "application/pdf" {
                guard message.role == .user else { throw ProviderServiceError.unsupportedAttachment }
                let base64 = data.base64EncodedString()
                switch mode {
                case .anthropic:
                    parts.append(["type": "document", "source": ["type": "base64", "media_type": mime, "data": base64]])
                case .responses:
                    parts.append(["type": "input_file", "filename": attachment.name, "file_data": "data:\(mime);base64,\(base64)"])
                case .chatCompletions:
                    guard [.openai, .custom, .openrouter].contains(provider.type) else { throw ProviderServiceError.unsupportedAttachment }
                    parts.append(["type": "file", "file": ["filename": attachment.name, "file_data": "data:\(mime);base64,\(base64)"]])
                }
            } else { throw ProviderServiceError.unsupportedAttachment }
        }
        return parts
    }

    private static func convertTools(_ tools: [[String: Any]], mode: ProviderAPI) throws -> [[String: Any]] {
        try tools.map { tool in
            guard tool["type"] as? String == "function", let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String, !name.isEmpty else {
                throw ProviderServiceError.invalidConfiguration("Tool definitions must use the Chat Completions function schema.")
            }
            var result: [String: Any] = ["name": name, "description": function["description"] as? String ?? ""]
            result[mode == .anthropic ? "input_schema" : "parameters"] = function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            if mode == .responses {
                result["type"] = "function"
                // Responses otherwise normalizes schemas to strict mode, changing optional arguments.
                result["strict"] = function["strict"] as? Bool ?? false
            }
            return result
        }
    }

    public struct ModelPage {
        public let models: [ModelDefinition]
        public let nextID: String?
    }

    public static func parseModels(_ data: Data, anthropic: Bool = false) throws -> ModelPage {
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil, let rows = object["data"] as? [[String: Any]] else { throw ProviderServiceError.invalidResponse }
        var seen = Set<String>()
        let models: [ModelDefinition] = try rows.compactMap { row in
            guard let raw = row["id"] as? String else { throw ProviderServiceError.invalidResponse }
            let id: String
            do { id = try validateModelID(raw) } catch { throw ProviderServiceError.invalidResponse }
            guard seen.insert(id).inserted else { return nil }
            return ModelDefinition(id: id, name: row["display_name"] as? String ?? row["name"] as? String ?? id)
        }
        let hasMore = anthropic && object["has_more"] as? Bool == true
        let next = hasMore ? object["last_id"] as? String : nil
        if hasMore && (next?.isEmpty != false || models.isEmpty) { throw ProviderServiceError.invalidResponse }
        return ModelPage(models: models, nextID: next)
    }
}
