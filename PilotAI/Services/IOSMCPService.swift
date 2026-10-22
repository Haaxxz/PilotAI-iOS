import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streamable HTTP MCP support. Each operation owns its connection and cancellation lifetime.
public enum IOSMCPService {
    public static let maxResponseBytes = 1_048_576
    public static let maxArgumentBytes = 65_536
    public static let maxDiscoveredTools = 128
    public static let maxRunTools = 64

    public struct RunSnapshot: Sendable {
        fileprivate struct Binding: Sendable {
            let modelName: String
            let server: McpServer
            let tool: McpToolDefinition
        }
        fileprivate let bindings: [Binding]

        public var toolSchemas: [[String: Any]] {
            bindings.compactMap { binding in
                guard let schema = try? JSONSerialization.jsonObject(with: Data(binding.tool.inputSchemaJson.utf8)) as? [String: Any] else {
                    return nil
                }
                return ["type": "function", "function": [
                    "name": binding.modelName,
                    "description": "MCP server \"\(binding.server.name)\": \(binding.tool.description)",
                    "parameters": schema
                ]]
            }
        }

        public func contains(toolName: String) -> Bool {
            bindings.contains { $0.modelName == toolName }
        }

        /// Uses the catalog, credentials and enablement frozen when the run was prepared.
        public func execute(toolName: String, arguments: String) async throws -> String {
            guard let binding = bindings.first(where: { $0.modelName == toolName }) else {
                throw IOSMCPError.toolNotEnabled
            }
            return try await IOSMCPService.callTool(server: binding.server, toolName: binding.tool.name, arguments: arguments)
        }
    }

    public struct PreparedRun: Sendable {
        public let snapshot: RunSnapshot
        /// Persist these through AppState.updateMcpServer before the next run.
        public let refreshedServers: [McpServer]
        /// Servers whose refresh failed are omitted from this run, never served from an expired catalog.
        public let failures: [String: String]
    }

    public static func validateEndpoint(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.fragment == nil else {
            throw IOSMCPError.invalidEndpoint
        }
        return url
    }

    public static func discover(server: McpServer) async throws -> McpServer {
        let client = try MCPHTTPClient(server: server)
        defer { client.close() }
        let discovery = try await client.discover()
        try Task.checkCancellation()
        var updated = server
        updated.tools = discovery.tools
        updated.enabledToolNames.formIntersection(discovery.tools.map(\.name))
        updated.lastProtocolVersion = discovery.version
        let now = Date()
        updated.lastRefreshedAt = now
        updated.toolsExpireAt = discovery.ttlMilliseconds.map {
            now.addingTimeInterval(min($0 / 1_000, max(0, Date.distantFuture.timeIntervalSince(now))))
        }
        return updated
    }

    /// Call once at the start of a model run, then retain the returned snapshot for all tool rounds.
    public static func prepareRun(servers: [McpServer]) async throws -> PreparedRun {
        var available: [McpServer] = []
        var refreshed: [McpServer] = []
        var failures: [String: String] = [:]
        for configured in servers where configured.isEnabled && configured.transportType == .sse {
            try Task.checkCancellation()
            if configured.needsToolRefresh() {
                do {
                    let server = try await discover(server: configured)
                    available.append(server)
                    refreshed.append(server)
                } catch {
                    try Task.checkCancellation()
                    failures[configured.id] = error.localizedDescription
                }
            } else {
                available.append(configured)
            }
        }
        return PreparedRun(snapshot: makeSnapshot(servers: available), refreshedServers: refreshed, failures: failures)
    }

    private static func makeSnapshot(servers: [McpServer]) -> RunSnapshot {
        var bindings: [RunSnapshot.Binding] = []
        var names = Set<String>()
        for server in servers {
            for tool in server.activeTools {
                guard bindings.count < maxRunTools else { break }
                guard tool.inputSchemaJson.utf8.count <= maxResponseBytes,
                      (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJson.utf8))) is [String: Any] else { continue }
                let name = modelToolName(serverID: server.id, toolName: tool.name)
                guard names.insert(name).inserted else { continue }
                bindings.append(.init(modelName: name, server: server, tool: tool))
            }
        }
        return RunSnapshot(bindings: bindings)
    }

    public static func callTool(server: McpServer, toolName: String, arguments: String) async throws -> String {
        guard server.isEnabled, let tool = server.activeTools.first(where: { $0.name == toolName }) else {
            throw IOSMCPError.toolNotEnabled
        }
        guard arguments.utf8.count <= maxArgumentBytes else { throw IOSMCPError.invalidArguments }
        let source = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parameters = try? JSONSerialization.jsonObject(with: Data((source.isEmpty ? "{}" : source).utf8)) as? [String: Any] else {
            throw IOSMCPError.invalidArguments
        }
        let client = try MCPHTTPClient(server: server)
        defer { client.close() }
        let result = try await client.call(tool: tool, arguments: parameters)
        try Task.checkCancellation()
        return try adaptResult(result, server: server, tool: tool)
    }

    private static func modelToolName(serverID: String, toolName: String) -> String {
        func normalized(_ value: String, limit: Int) -> String {
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            return String(value.map { allowed.contains($0) ? $0 : "_" }.prefix(limit))
        }
        // Stable FNV-1a namespace; unlike Swift.Hasher it is deterministic across launches.
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in (serverID + "\0" + toolName).utf8 { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "mcp_\(normalized(serverID, limit: 8))_\(normalized(toolName, limit: 30))_\(String(digest, radix: 16))"
    }

    private static func adaptResult(_ result: [String: Any], server: McpServer, tool: McpToolDefinition) throws -> String {
        var texts: [String] = []
        var remaining = 65_536
        var truncated = false
        var omitted = 0
        for item in result["content"] as? [[String: Any]] ?? [] {
            let text: String?
            switch item["type"] as? String {
            case "text": text = item["text"] as? String
            case "resource": text = (item["resource"] as? [String: Any])?["text"] as? String
            case "resource_link":
                if let uri = item["uri"] as? String, !uri.isEmpty {
                    let label = item["name"] as? String ?? item["title"] as? String ?? ""
                    text = label.isEmpty ? uri : "\(label): \(uri)"
                } else { text = nil }
            default: text = nil
            }
            guard let text = text else { omitted += 1; continue }
            if text.utf8.count <= remaining {
                texts.append(text)
                remaining -= text.utf8.count
            } else {
                // Drop an incomplete UTF-8 scalar at the boundary rather than inserting replacement bytes.
                var bytes = Data(text.utf8.prefix(remaining))
                while !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
                if let bounded = String(data: bytes, encoding: .utf8), !bounded.isEmpty { texts.append(bounded) }
                remaining -= bytes.count
                truncated = true
            }
        }
        let isError = result["isError"] as? Bool ?? false
        var payload: [String: Any] = ["ok": !isError, "server": server.name, "tool": tool.name, "content": texts]
        if let structured = result["structuredContent"], !(structured is NSNull) {
            let encoded = try JSONSerialization.data(withJSONObject: structured, options: [.fragmentsAllowed])
            if encoded.count <= 65_536 { payload["structured_content"] = structured } else { truncated = true }
        }
        if isError { payload["code"] = "MCP_TOOL_ERROR" }
        if truncated { payload["truncated"] = true }
        if omitted > 0 { payload["omitted_items"] = omitted }
        return String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
    }
}

public enum IOSMCPError: LocalizedError {
    case invalidEndpoint, unsupportedTransport, invalidArguments, toolNotEnabled, invalidHeader
    case responseTooLarge, incompatibleProtocol
    case invalidResponse(String)
    case httpStatus(Int, rpcCode: Int?)
    case jsonRPC(Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter a valid HTTP or HTTPS MCP endpoint."
        case .unsupportedTransport: return "iOS supports Streamable HTTP MCP servers; local stdio commands are unavailable."
        case .invalidArguments: return "MCP arguments must be a JSON object of at most 64 KiB."
        case .toolNotEnabled: return "This MCP tool is not enabled for this run."
        case .invalidHeader: return "An MCP header or bearer token contains invalid characters."
        case .responseTooLarge: return "The MCP response exceeded the 1 MiB limit."
        case .incompatibleProtocol: return "The MCP server requires a different protocol. Try Automatic or Legacy."
        case .invalidResponse(let message): return "Invalid MCP response: \(message)"
        case .httpStatus(let status, _): return "MCP request failed (HTTP \(status))."
        case .jsonRPC(let code, let message): return "MCP protocol error \(code): \(String(message.prefix(200)))"
        }
    }
}

private final class MCPHTTPClient {
    struct Discovery {
        let version: String
        let tools: [McpToolDefinition]
        let ttlMilliseconds: Double?
    }

    private static let modern = McpServer.ProtocolMode.modern.rawValue
    private static let legacy = McpServer.ProtocolMode.legacy.rawValue
    private static let legacyVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", legacy]
    private let server: McpServer
    private let endpoint: URL
    private var requestID = 0
    private var version: String?
    private var sessionID: String?

    init(server: McpServer) throws {
        guard server.transportType == .sse else { throw IOSMCPError.unsupportedTransport }
        self.server = server
        self.endpoint = try IOSMCPService.validateEndpoint(server.urlOrCommand)
    }

    func discover() async throws -> Discovery {
        if server.protocolMode != .legacy {
            do {
                version = Self.modern
                return try await listTools()
            } catch {
                guard server.protocolMode == .auto, isCompatibilityFailure(error) else { throw error }
                version = nil
            }
        }
        try await initializeLegacy()
        do { return try await listTools() }
        catch {
            guard shouldRenewSession(error) else { throw error }
            sessionID = nil
            version = nil
            try await initializeLegacy()
            return try await listTools()
        }
    }

    func call(tool: McpToolDefinition, arguments: [String: Any]) async throws -> [String: Any] {
        if server.protocolMode == .legacy || (server.protocolMode == .auto && Self.legacyVersions.contains(server.lastProtocolVersion ?? "")) {
            try await initializeLegacy()
        } else if server.protocolMode == .modern || server.lastProtocolVersion == Self.modern {
            version = Self.modern
        } else {
            _ = try await discover()
        }
        var headers: [String: String] = [:]
        if version == Self.modern,
           let schema = try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJson.utf8)) as? [String: Any] {
            headers = parameterHeaders(schema: schema, arguments: arguments)
        }
        func invoke() async throws -> [String: Any] {
            let response = try await request(method: "tools/call", params: ["name": tool.name, "arguments": arguments], name: tool.name, extraHeaders: headers)
            let result = try unwrap(response)
            if result["resultType"] as? String == "input_required" {
                throw IOSMCPError.invalidResponse("interactive supplementary input is not supported.")
            }
            if version == Self.modern, result["resultType"] as? String != "complete" {
                throw IOSMCPError.invalidResponse("unsupported tool result type.")
            }
            return result
        }
        do { return try await invoke() }
        catch {
            // Only an explicit missing legacy session can be retried; never replay ambiguous tool failures.
            guard shouldRenewSession(error) else { throw error }
            sessionID = nil
            version = nil
            try await initializeLegacy()
            return try await invoke()
        }
    }

    func close() {
        guard let sessionID = sessionID, let version = version, Self.legacyVersions.contains(version) else { return }
        self.sessionID = nil
        guard var request = try? makeRequest(method: "DELETE", protocolVersion: version, sessionID: sessionID) else { return }
        request.timeoutInterval = 5
        let cleanupRequest = request
        // Cleanup has its own short lifetime, including when the owning operation was cancelled.
        Task { _ = try? await MCPHTTPExchange(request: cleanupRequest, expectedID: nil).run() }
    }

    private func initializeLegacy() async throws {
        if let version = version, Self.legacyVersions.contains(version) { return }
        version = Self.legacy
        do {
            let response = try await request(method: "initialize", params: [
                "protocolVersion": Self.legacy, "capabilities": [String: Any](),
                "clientInfo": ["name": "PilotAI-iOS", "version": "1"]
            ])
            let result = try unwrap(response)
            guard let negotiated = result["protocolVersion"] as? String, Self.legacyVersions.contains(negotiated) else {
                throw IOSMCPError.invalidResponse("unsupported protocol version.")
            }
            version = negotiated
            sessionID = response.sessionID
            if let sessionID = sessionID,
               sessionID.isEmpty || !sessionID.utf8.allSatisfy({ (33...126).contains($0) }) {
                self.sessionID = nil
                throw IOSMCPError.invalidResponse("invalid session identifier.")
            }
            _ = try await request(method: "notifications/initialized", params: [:], notification: true)
        } catch {
            // Retain an assigned session for best-effort cleanup if initialized notification failed.
            if sessionID == nil { version = nil }
            throw error
        }
    }

    private func listTools() async throws -> Discovery {
        var tools: [McpToolDefinition] = []
        var names = Set<String>()
        var cursor: String?
        var cursors = Set<String>()
        var ttl: Double?
        for _ in 0..<8 {
            let response = try await request(method: "tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            let result = try unwrap(response)
            if version == Self.modern {
                guard let resultType = result["resultType"] as? String else { throw IOSMCPError.incompatibleProtocol }
                guard resultType == "complete" else { throw IOSMCPError.invalidResponse("unsupported catalog result type.") }
                let value = (result["ttlMs"] as? NSNumber)?.doubleValue ?? 0
                let pageTTL = value.isFinite ? max(0, value) : 0
                ttl = min(ttl ?? pageTTL, pageTTL)
            }
            guard let page = result["tools"] as? [[String: Any]] else { throw IOSMCPError.invalidResponse("missing tools array.") }
            for source in page where tools.count < IOSMCPService.maxDiscoveredTools {
                guard let name = (source["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, names.insert(name).inserted else { continue }
                let annotations = source["annotations"] as? [String: Any] ?? [:]
                let schema = source["inputSchema"] as? [String: Any] ?? [:]
                let sourceTitle = source["title"] as? String ?? ""
                let title = sourceTitle.isEmpty ? annotations["title"] as? String ?? "" : sourceTitle
                tools.append(McpToolDefinition(
                    name: name, title: String(title.prefix(160)),
                    description: String((source["description"] as? String ?? "").prefix(2_000)),
                    inputSchemaJson: String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self),
                    readOnlyHint: annotations["readOnlyHint"] as? Bool,
                    destructiveHint: annotations["destructiveHint"] as? Bool,
                    idempotentHint: annotations["idempotentHint"] as? Bool,
                    openWorldHint: annotations["openWorldHint"] as? Bool
                ))
            }
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty != false || tools.count >= IOSMCPService.maxDiscoveredTools { break }
            if let cursor = cursor, !cursors.insert(cursor).inserted { throw IOSMCPError.invalidResponse("repeated pagination cursor.") }
        }
        return Discovery(version: version ?? Self.modern, tools: tools, ttlMilliseconds: ttl)
    }

    private func request(method: String, params: [String: Any], name: String? = nil,
                         extraHeaders: [String: String] = [:], notification: Bool = false) async throws -> MCPWireResponse {
        try Task.checkCancellation()
        let protocolVersion = version ?? Self.modern
        var decorated = params
        if protocolVersion == Self.modern {
            decorated["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": protocolVersion,
                "io.modelcontextprotocol/clientInfo": ["name": "PilotAI-iOS", "version": "1"],
                "io.modelcontextprotocol/clientCapabilities": [String: Any]()
            ]
        }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": decorated]
        var id: Int?
        if !notification { requestID += 1; id = requestID; body["id"] = requestID }
        var request = try makeRequest(method: "POST", protocolVersion: protocolVersion, sessionID: sessionID)
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let name = name {
            let value = protocolVersion == Self.modern ? encodeHeaderValue(name) : name
            guard validHeaderValue(value) else { throw IOSMCPError.invalidHeader }
            request.setValue(value, forHTTPHeaderField: "Mcp-Name")
        }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await MCPHTTPExchange(request: request, expectedID: id).run()
    }

    private func makeRequest(method: String, protocolVersion: String, sessionID: String?) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        for (name, value) in server.headers {
            guard validHeaderName(name), validHeaderValue(value) else { throw IOSMCPError.invalidHeader }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(nil, forHTTPHeaderField: "Mcp-Name")
        // A stale user-supplied session header must never turn a stateless request into a stateful one.
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        let token = server.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            guard validHeaderValue(token) else { throw IOSMCPError.invalidHeader }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func unwrap(_ response: MCPWireResponse) throws -> [String: Any] {
        guard let result = response.json?["result"] as? [String: Any] else {
            throw IOSMCPError.invalidResponse("missing result object.")
        }
        return result
    }

    private func isCompatibilityFailure(_ error: Error) -> Bool {
        guard let error = error as? IOSMCPError else { return false }
        switch error {
        case .incompatibleProtocol: return true
        case .httpStatus(let status, let code):
            return [400, 404, 405].contains(status) && ![-32601, -32020, -32021, -32022].contains(code ?? 0)
        case .jsonRPC(let code, _): return code == -32600
        default: return false
        }
    }

    private func shouldRenewSession(_ error: Error) -> Bool {
        guard sessionID != nil, Self.legacyVersions.contains(version ?? ""),
              let error = error as? IOSMCPError, case .httpStatus(404, _) = error else { return false }
        return true
    }

    private func parameterHeaders(schema: [String: Any], arguments: [String: Any], depth: Int = 0) -> [String: String] {
        guard depth < 32, let properties = schema["properties"] as? [String: [String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for (key, property) in properties {
            guard let value = arguments[key] else { continue }
            if let header = property["x-mcp-header"] as? String, validHeaderName(header) {
                var rendered: String?
                switch property["type"] as? String {
                case "string": rendered = value as? String
                case "boolean":
                    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                        rendered = number.boolValue ? "true" : "false"
                    }
                case "integer":
                    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                        let numeric = number.doubleValue
                        if numeric.isFinite, numeric.rounded() == numeric, abs(numeric) <= 9_007_199_254_740_991 {
                            rendered = String(Int64(numeric))
                        }
                    }
                default: break
                }
                if let rendered = rendered { result["Mcp-Param-\(header)"] = encodeHeaderValue(rendered) }
            }
            if let nested = value as? [String: Any] {
                result.merge(parameterHeaders(schema: property, arguments: nested, depth: depth + 1)) { _, new in new }
            }
        }
        return result
    }
}

private func validHeaderName(_ value: String) -> Bool {
    let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    return !value.isEmpty && value.allSatisfy { allowed.contains($0) }
}

private func validHeaderValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { $0 == 9 || (32...126).contains($0) }
}

private func encodeHeaderValue(_ value: String) -> String {
    if validHeaderValue(value), value.first != " ", value.first != "\t", value.last != " ", value.last != "\t",
       !(value.hasPrefix("=?base64?") && value.hasSuffix("?=")) { return value }
    return "=?base64?\(Data(value.utf8).base64EncodedString())?="
}

private struct MCPWireResponse {
    let json: [String: Any]?
    let sessionID: String?
}

/// Delegate streaming bounds bytes before buffering, and completes SSE as soon as the matching event arrives.
private final class MCPHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let expectedID: Int?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MCPWireResponse, Error>?
    private var session: URLSession?
    private var finished = false
    private var response: HTTPURLResponse?
    private var isSSE = false
    private var totalBytes = 0
    private var body = Data()
    private var line = Data()
    private var event = Data()
    private var previousWasCR = false

    init(request: URLRequest, expectedID: Int?) {
        self.request = request
        self.expectedID = expectedID
    }

    func run() async throws -> MCPWireResponse {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { start($0) }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func start(_ continuation: CheckedContinuation<MCPWireResponse, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    private func finish(_ result: Result<MCPWireResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(IOSMCPError.invalidResponse("expected HTTP.")))
            return
        }
        lock.lock()
        self.response = http
        isSSE = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        lock.unlock()
        if (200..<300).contains(http.statusCode), expectedID == nil {
            completionHandler(.cancel)
            finish(.success(MCPWireResponse(json: nil, sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id"))))
        } else if http.expectedContentLength > IOSMCPService.maxResponseBytes {
            completionHandler(.cancel)
            finish(.failure(IOSMCPError.responseTooLarge))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let result: Result<MCPWireResponse, Error>?
        do {
            totalBytes += data.count
            guard totalBytes <= IOSMCPService.maxResponseBytes else { throw IOSMCPError.responseTooLarge }
            if isSSE {
                var matched: [String: Any]?
                for byte in data {
                    if previousWasCR && byte == 10 { previousWasCR = false; continue }
                    previousWasCR = byte == 13
                    if byte == 10 || byte == 13 {
                        matched = consumeLine()
                        if matched != nil { break }
                    } else { line.append(byte) }
                }
                result = try matched.map { try validated($0) }
            } else {
                body.append(data)
                result = nil
            }
        } catch { result = .failure(error) }
        lock.unlock()
        if let result = result { finish(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let result: Result<MCPWireResponse, Error>
        do {
            if let error = error { throw error }
            let json: [String: Any]?
            if isSSE {
                let finalLine = consumeLine()
                json = finalLine ?? consumeEvent()
            } else {
                json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            result = try validated(json)
        } catch { result = .failure(error) }
        lock.unlock()
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not replay tool POSTs or forward user headers to a redirected origin.
        completionHandler(nil)
    }

    private func consumeLine() -> [String: Any]? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return consumeEvent() }
        if line.starts(with: Data("data:".utf8)) {
            var data = line.dropFirst(5)
            if data.first == 32 { data = data.dropFirst() }
            if !event.isEmpty { event.append(10) }
            event.append(contentsOf: data)
        }
        return nil
    }

    private func consumeEvent() -> [String: Any]? {
        defer { event.removeAll(keepingCapacity: true) }
        guard !event.isEmpty, let json = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any],
              json["method"] == nil, matchesID(json["id"]) else { return nil }
        return json
    }

    private func matchesID(_ candidate: Any?) -> Bool {
        guard let expectedID = expectedID else { return true }
        if let number = candidate as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue == String(expectedID)
        }
        return (candidate as? String) == String(expectedID)
    }

    private func validated(_ json: [String: Any]?) throws -> Result<MCPWireResponse, Error> {
        guard let response = response else { throw IOSMCPError.invalidResponse("missing HTTP response.") }
        let rpcError = json?["error"] as? [String: Any]
        if !(200..<300).contains(response.statusCode) {
            throw IOSMCPError.httpStatus(response.statusCode, rpcCode: rpcError?["code"] as? Int)
        }
        guard let json = json, json["jsonrpc"] as? String == "2.0", matchesID(json["id"]),
              json["method"] == nil, (json["result"] != nil) != (json["error"] != nil) else {
            throw IOSMCPError.invalidResponse("missing or mismatched JSON-RPC response.")
        }
        if let error = rpcError {
            throw IOSMCPError.jsonRPC(error["code"] as? Int ?? -32603, message: error["message"] as? String ?? "Unknown error")
        }
        return .success(MCPWireResponse(json: json, sessionID: response.value(forHTTPHeaderField: "Mcp-Session-Id")))
    }
}
