import Foundation

public enum MessageRole: String, Codable, CaseIterable {
    case system = "system"
    case user = "user"
    case assistant = "assistant"
    case tool = "tool"
}

public struct MessageAttachment: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let mimeType: String
    /// Base64-encoded bytes. Keeping the wire representation text-only makes attachments safe to persist in legacy JSON stores.
    public let dataBase64: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        mimeType: String,
        dataBase64: String
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
    }
}

public struct ToolCall: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String
    public var output: String?
    public var isExecuting: Bool
    
    public init(id: String = UUID().uuidString, name: String, arguments: String, output: String? = nil, isExecuting: Bool = false) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.output = output
        self.isExecuting = isExecuting
    }
}

public struct Message: Identifiable, Codable, Equatable {
    public let id: String
    public let role: MessageRole
    public var content: String
    public var reasoningContent: String?
    public var toolCalls: [ToolCall]?
    /// Links a tool-result message back to the assistant tool call that requested it.
    /// Optional so conversations written before the iOS tool loop existed remain decodable.
    public var toolCallId: String?
    public var isStreaming: Bool
    public let timestamp: Date
    public var modelName: String?
    /// User-selected files/images. Optional so conversations written before attachments existed remain decodable.
    public var attachments: [MessageAttachment]?
    
    public init(
        id: String = UUID().uuidString,
        role: MessageRole,
        content: String,
        reasoningContent: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        isStreaming: Bool = false,
        timestamp: Date = Date(),
        modelName: String? = nil,
        attachments: [MessageAttachment]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.isStreaming = isStreaming
        self.timestamp = timestamp
        self.modelName = modelName
        self.attachments = attachments
    }
}
