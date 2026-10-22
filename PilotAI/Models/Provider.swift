import Foundation

public enum ProviderType: String, Codable, CaseIterable {
    case openai = "openai"
    case anthropic = "anthropic"
    case deepseek = "deepseek"
    case kimi = "kimi"
    case alibaba = "alibaba"
    case minimax = "minimax"
    case siliconflow = "siliconflow"
    case openrouter = "openrouter"
    case mimo = "mimo"
    case stepfun = "stepfun"
    case local = "local"
    case custom = "custom"
    
    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi (Moonshot)"
        case .alibaba: return "Alibaba Bailian"
        case .minimax: return "MiniMax"
        case .siliconflow: return "SiliconFlow"
        case .openrouter: return "OpenRouter"
        case .mimo: return "MiMo"
        case .stepfun: return "StepFun"
        case .local: return "Local (Ollama/LM Studio)"
        case .custom: return "Custom OpenAI-Compatible"
        }
    }
    
    public var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .alibaba: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .minimax: return "https://api.minimax.chat/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .mimo: return "https://api.xiaomimimo.com/v1"
        case .stepfun: return "https://api.stepfun.com/v1"
        case .local: return "http://127.0.0.1:11434/v1"
        case .custom: return "https://api.openai.com/v1"
        }
    }
}

public struct ModelDefinition: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let supportsVision: Bool
    public let supportsReasoning: Bool
    public let contextWindow: Int
    public let contextWindowOverride: Int?
    public let sortOrder: Int
    
    public init(id: String, name: String, supportsVision: Bool = false, supportsReasoning: Bool = false, contextWindow: Int = 128_000, contextWindowOverride: Int? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.contextWindow = contextWindow
        self.contextWindowOverride = contextWindowOverride
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, supportsVision, supportsReasoning, contextWindow, contextWindowOverride, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        self.init(id: id,
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? id,
                  supportsVision: try values.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false,
                  supportsReasoning: try values.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? false,
                  contextWindow: try values.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 128_000,
                  contextWindowOverride: try values.decodeIfPresent(Int.self, forKey: .contextWindowOverride),
                  sortOrder: try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0)
    }
}

public struct CustomHeader: Identifiable, Codable, Equatable {
    public var id: String = UUID().uuidString
    public var key: String
    public var value: String
    
    public init(id: String = UUID().uuidString, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case id, key, value }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
                  key: try values.decode(String.self, forKey: .key),
                  value: try values.decode(String.self, forKey: .value))
    }
}

public struct ModelProvider: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var type: ProviderType
    public var baseURL: String
    public var apiKey: String
    public var defaultModelId: String
    public var models: [ModelDefinition]
    public var customHeaders: [CustomHeader]
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var systemPrompt: String
    public var endpointMode: String
    public var hostedWebSearchEnabled: Bool
    public var anthropicVersion: String
    /// Additional JSON parameters; protocol-owned fields cannot be overridden.
    public var customRequestBodyJSON: String
    /// Empty means use the model's default. OpenAI-compatible APIs only.
    public var reasoningEffort: String
    public var maxOutputTokens: Int?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        type: ProviderType,
        baseURL: String? = nil,
        apiKey: String = "",
        defaultModelId: String,
        models: [ModelDefinition] = [],
        customHeaders: [CustomHeader] = [],
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        systemPrompt: String = "",
        endpointMode: String = "chat_completions",
        hostedWebSearchEnabled: Bool = false,
        anthropicVersion: String = "2023-06-01",
        customRequestBodyJSON: String = "",
        reasoningEffort: String = "",
        maxOutputTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL ?? type.defaultBaseURL
        self.apiKey = apiKey
        self.defaultModelId = defaultModelId
        self.models = models
        self.customHeaders = customHeaders
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.systemPrompt = systemPrompt
        self.endpointMode = endpointMode
        self.hostedWebSearchEnabled = hostedWebSearchEnabled
        self.anthropicVersion = anthropicVersion
        self.customRequestBodyJSON = customRequestBodyJSON
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, baseURL, apiKey, defaultModelId, models, customHeaders
        case isEnabled, isBuiltIn, systemPrompt, endpointMode, hostedWebSearchEnabled, anthropicVersion
        case customRequestBodyJSON, reasoningEffort, maxOutputTokens
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decodeIfPresent(ProviderType.self, forKey: .type) ?? .custom
        let models = try values.decodeIfPresent([ModelDefinition].self, forKey: .models) ?? []
        self.init(
            id: try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try values.decodeIfPresent(String.self, forKey: .name) ?? type.displayName,
            type: type,
            baseURL: try values.decodeIfPresent(String.self, forKey: .baseURL),
            apiKey: try values.decodeIfPresent(String.self, forKey: .apiKey) ?? "",
            defaultModelId: try values.decodeIfPresent(String.self, forKey: .defaultModelId) ?? models.first?.id ?? "",
            models: models,
            customHeaders: try values.decodeIfPresent([CustomHeader].self, forKey: .customHeaders) ?? [],
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isBuiltIn: try values.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false,
            systemPrompt: try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "",
            endpointMode: try values.decodeIfPresent(String.self, forKey: .endpointMode) ?? "chat_completions",
            hostedWebSearchEnabled: try values.decodeIfPresent(Bool.self, forKey: .hostedWebSearchEnabled) ?? false,
            anthropicVersion: try values.decodeIfPresent(String.self, forKey: .anthropicVersion) ?? "2023-06-01",
            customRequestBodyJSON: try values.decodeIfPresent(String.self, forKey: .customRequestBodyJSON) ?? "",
            reasoningEffort: try values.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "",
            maxOutputTokens: try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        )
    }
    
    public static var defaults: [ModelProvider] {
        [
            ModelProvider(
                id: "builtin-openai",
                name: "OpenAI",
                type: .openai,
                baseURL: "https://api.openai.com/v1",
                defaultModelId: "gpt-4o",
                models: [
                    ModelDefinition(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", supportsVision: true, supportsReasoning: true, contextWindow: 200_000),
                    ModelDefinition(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", supportsVision: true, supportsReasoning: false, contextWindow: 200_000),
                    ModelDefinition(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", supportsVision: true, supportsReasoning: false, contextWindow: 200_000),
                    ModelDefinition(id: "gpt-5.5", name: "GPT-5.5", supportsVision: true, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "gpt-4o", name: "GPT-4o", supportsVision: true, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "gpt-4o-mini", name: "GPT-4o mini", supportsVision: true, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "o3-mini", name: "o3-mini", supportsVision: false, supportsReasoning: true, contextWindow: 200_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-anthropic",
                name: "Anthropic",
                type: .anthropic,
                baseURL: "https://api.anthropic.com",
                defaultModelId: "claude-3-5-sonnet-20241022",
                models: [
                    ModelDefinition(id: "claude-fable-5", name: "Claude Fable 5", supportsVision: true, supportsReasoning: true, contextWindow: 200_000),
                    ModelDefinition(id: "claude-opus-4-8", name: "Claude Opus 4.8", supportsVision: true, supportsReasoning: false, contextWindow: 200_000),
                    ModelDefinition(id: "claude-sonnet-5", name: "Claude Sonnet 5", supportsVision: true, supportsReasoning: true, contextWindow: 200_000),
                    ModelDefinition(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", supportsVision: true, supportsReasoning: false, contextWindow: 200_000),
                    ModelDefinition(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", supportsVision: true, supportsReasoning: false, contextWindow: 200_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-dashscope",
                name: "Alibaba Bailian",
                type: .alibaba,
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                defaultModelId: "qwen-turbo",
                models: [
                    ModelDefinition(id: "qwen3.7-plus", name: "Qwen 3.7 Plus", supportsVision: false, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "qwen3-max", name: "Qwen 3 Max", supportsVision: false, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "qwen-vl-max", name: "Qwen VL Max", supportsVision: true, supportsReasoning: false, contextWindow: 32_000),
                    ModelDefinition(id: "qwen-turbo", name: "Qwen Turbo", supportsVision: false, supportsReasoning: false, contextWindow: 128_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-deepseek",
                name: "DeepSeek",
                type: .deepseek,
                baseURL: "https://api.deepseek.com",
                defaultModelId: "deepseek-chat",
                models: [
                    ModelDefinition(id: "deepseek-chat", name: "DeepSeek Chat", supportsVision: false, supportsReasoning: false, contextWindow: 64_000),
                    ModelDefinition(id: "deepseek-reasoner", name: "DeepSeek Reasoner", supportsVision: false, supportsReasoning: true, contextWindow: 64_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-kimi",
                name: "Kimi",
                type: .kimi,
                baseURL: "https://api.moonshot.cn/v1",
                defaultModelId: "moonshot-v1-8k",
                models: [
                    ModelDefinition(id: "kimi-k1.5", name: "Kimi k1.5", supportsVision: false, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "moonshot-v1-128k", name: "Moonshot v1 128K", supportsVision: false, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "moonshot-v1-32k", name: "Moonshot v1 32K", supportsVision: false, supportsReasoning: false, contextWindow: 32_000),
                    ModelDefinition(id: "moonshot-v1-8k", name: "Moonshot v1 8K", supportsVision: false, supportsReasoning: false, contextWindow: 8_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-mimo",
                name: "MiMo",
                type: .mimo,
                baseURL: "https://api.xiaomimimo.com/v1",
                defaultModelId: "mimo-v1-lite",
                models: [
                    ModelDefinition(id: "mimo-v1-pro", name: "MiMo v1 Pro", supportsVision: false, supportsReasoning: false, contextWindow: 32_000),
                    ModelDefinition(id: "mimo-v1-lite", name: "MiMo v1 Lite", supportsVision: false, supportsReasoning: false, contextWindow: 32_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-minimax",
                name: "MiniMax",
                type: .minimax,
                baseURL: "https://api.minimaxi.com/v1",
                defaultModelId: "abab6.5t-chat",
                models: [
                    ModelDefinition(id: "abab7-chat-preview", name: "abab7 Chat Preview", supportsVision: false, supportsReasoning: false, contextWindow: 32_000),
                    ModelDefinition(id: "abab6.5t-chat", name: "abab6.5t Chat", supportsVision: false, supportsReasoning: false, contextWindow: 32_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-stepfun",
                name: "StepFun",
                type: .stepfun,
                baseURL: "https://api.stepfun.com/v1",
                defaultModelId: "step-1-8k",
                models: [
                    ModelDefinition(id: "step-2-16k", name: "Step 2 16K", supportsVision: false, supportsReasoning: false, contextWindow: 16_000),
                    ModelDefinition(id: "step-1-8k", name: "Step 1 8K", supportsVision: false, supportsReasoning: false, contextWindow: 8_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-siliconflow",
                name: "SiliconFlow",
                type: .siliconflow,
                baseURL: "https://api.siliconflow.cn/v1",
                defaultModelId: "deepseek-ai/DeepSeek-V3",
                models: [
                    ModelDefinition(id: "deepseek-ai/DeepSeek-V3", name: "DeepSeek V3", supportsVision: false, supportsReasoning: false, contextWindow: 64_000),
                    ModelDefinition(id: "deepseek-ai/DeepSeek-R1", name: "DeepSeek R1", supportsVision: false, supportsReasoning: true, contextWindow: 64_000),
                    ModelDefinition(id: "Qwen/Qwen2.5-72B-Instruct", name: "Qwen 2.5 72B", supportsVision: false, supportsReasoning: false, contextWindow: 32_000)
                ],
                isBuiltIn: true
            ),
            ModelProvider(
                id: "builtin-openrouter",
                name: "OpenRouter",
                type: .openrouter,
                baseURL: "https://openrouter.ai/api/v1",
                apiKey: "",
                defaultModelId: "anthropic/claude-3.5-sonnet",
                models: [
                    ModelDefinition(id: "deepseek/deepseek-r1", name: "DeepSeek R1", supportsVision: false, supportsReasoning: true, contextWindow: 64_000),
                    ModelDefinition(id: "openai/gpt-4o", name: "GPT-4o", supportsVision: true, supportsReasoning: false, contextWindow: 128_000),
                    ModelDefinition(id: "anthropic/claude-3.5-sonnet", name: "Claude 3.5 Sonnet", supportsVision: true, supportsReasoning: false, contextWindow: 200_000),
                    ModelDefinition(id: "google/gemini-2.0-flash-001", name: "Gemini 2.0 Flash", supportsVision: true, supportsReasoning: false, contextWindow: 1_000_000)
                ],
                isBuiltIn: true
            )
        ]
    }
    
}
