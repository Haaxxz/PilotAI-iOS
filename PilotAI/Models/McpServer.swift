import Foundation

public struct McpToolDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var description: String
    /// Retain the full JSON Schema, including references and composition keywords.
    public var inputSchemaJson: String
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(name: String, title: String = "", description: String = "", inputSchemaJson: String = "{}",
                readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchemaJson = inputSchemaJson
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchemaJson
        case readOnlyHint, destructiveHint, idempotentHint, openWorldHint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try values.decode(String.self, forKey: .name),
            title: try values.decodeIfPresent(String.self, forKey: .title) ?? "",
            description: try values.decodeIfPresent(String.self, forKey: .description) ?? "",
            inputSchemaJson: try values.decodeIfPresent(String.self, forKey: .inputSchemaJson) ?? "{}",
            readOnlyHint: try values.decodeIfPresent(Bool.self, forKey: .readOnlyHint),
            destructiveHint: try values.decodeIfPresent(Bool.self, forKey: .destructiveHint),
            idempotentHint: try values.decodeIfPresent(Bool.self, forKey: .idempotentHint),
            openWorldHint: try values.decodeIfPresent(Bool.self, forKey: .openWorldHint)
        )
    }
}

public struct McpServer: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var transportType: TransportType
    public var urlOrCommand: String
    public var isEnabled: Bool
    public var envVars: [String: String]
    public var headers: [String: String]
    public var bearerToken: String
    public var protocolMode: ProtocolMode
    public var tools: [McpToolDefinition]
    public var enabledToolNames: Set<String>
    public var lastRefreshedAt: Date?
    public var lastProtocolVersion: String?
    public var toolsExpireAt: Date?

    public enum TransportType: String, Codable, CaseIterable, Sendable {
        // Keep the persisted value for configurations created before Streamable HTTP support.
        case sse = "SSE (HTTP)"
        case stdio = "stdio (Command)"

        public var displayName: String {
            self == .sse ? "Streamable HTTP" : "stdio (unavailable on iOS)"
        }
    }

    public enum ProtocolMode: String, Codable, CaseIterable, Sendable {
        case auto = "auto"
        case modern = "2026-07-28"
        case legacy = "2025-11-25"

        public var displayName: String {
            switch self {
            case .auto: return "Automatic"
            case .modern: return "Modern (2026-07-28)"
            case .legacy: return "Legacy (2025-11-25 or earlier)"
            }
        }
    }

    public var activeTools: [McpToolDefinition] {
        guard isEnabled, transportType == .sse else { return [] }
        return tools.filter { enabledToolNames.contains($0.name) }
    }

    public func needsToolRefresh(at date: Date = Date()) -> Bool {
        lastProtocolVersion == nil ||
            (lastProtocolVersion == ProtocolMode.modern.rawValue && (toolsExpireAt.map { $0 <= date } ?? true))
    }

    public init(id: String = UUID().uuidString, name: String, transportType: TransportType = .sse,
                urlOrCommand: String, isEnabled: Bool = true, envVars: [String: String] = [:],
                headers: [String: String] = [:], bearerToken: String = "", protocolMode: ProtocolMode = .auto,
                tools: [McpToolDefinition] = [], enabledToolNames: Set<String> = [],
                lastRefreshedAt: Date? = nil, lastProtocolVersion: String? = nil, toolsExpireAt: Date? = nil) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.urlOrCommand = urlOrCommand
        self.isEnabled = isEnabled
        self.envVars = envVars
        self.headers = headers
        self.bearerToken = bearerToken
        self.protocolMode = protocolMode
        self.tools = tools
        self.enabledToolNames = enabledToolNames
        self.lastRefreshedAt = lastRefreshedAt
        self.lastProtocolVersion = lastProtocolVersion
        self.toolsExpireAt = toolsExpireAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, transportType, urlOrCommand, isEnabled, envVars, headers, bearerToken, protocolMode
        case tools, enabledToolNames, lastRefreshedAt, lastProtocolVersion, toolsExpireAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try values.decodeIfPresent(String.self, forKey: .name) ?? "",
            transportType: try values.decodeIfPresent(TransportType.self, forKey: .transportType) ?? .sse,
            urlOrCommand: try values.decodeIfPresent(String.self, forKey: .urlOrCommand) ?? "",
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            envVars: try values.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:],
            headers: try values.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
            bearerToken: try values.decodeIfPresent(String.self, forKey: .bearerToken) ?? "",
            protocolMode: try values.decodeIfPresent(ProtocolMode.self, forKey: .protocolMode) ?? .auto,
            tools: try values.decodeIfPresent([McpToolDefinition].self, forKey: .tools) ?? [],
            enabledToolNames: try values.decodeIfPresent(Set<String>.self, forKey: .enabledToolNames) ?? [],
            lastRefreshedAt: try values.decodeIfPresent(Date.self, forKey: .lastRefreshedAt),
            lastProtocolVersion: try values.decodeIfPresent(String.self, forKey: .lastProtocolVersion),
            toolsExpireAt: try values.decodeIfPresent(Date.self, forKey: .toolsExpireAt)
        )
    }
}
