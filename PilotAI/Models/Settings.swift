import Foundation

public enum AppTheme: String, Codable, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    public var displayName: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public var theme: AppTheme
    public var hapticsEnabled: Bool
    public var autoScroll: Bool
    public var smoothStreamReveal: Bool
    public var sendOnEnter: Bool
    public var defaultProviderId: String
    public var defaultModelId: String
    public var enableWebSearchTool: Bool
    public var enableTerminalTool: Bool
    public var enableMemoryTool: Bool
    public var enableFileAccessTool: Bool
    public var enableBrowserTool: Bool
    public var enableWorkspaceTool: Bool
    public var enableMCPTool: Bool
    public var enableUnsandboxedGateway: Bool
    public var remoteGatewayURL: String

    private enum CodingKeys: String, CodingKey {
        case theme, hapticsEnabled, autoScroll, smoothStreamReveal, sendOnEnter
        case defaultProviderId, defaultModelId, enableWebSearchTool, enableTerminalTool
        case enableMemoryTool, enableFileAccessTool, enableBrowserTool, enableWorkspaceTool, enableMCPTool
        case enableUnsandboxedGateway, remoteGatewayURL
    }
    
    public init(
        theme: AppTheme = .system,
        hapticsEnabled: Bool = true,
        autoScroll: Bool = true,
        smoothStreamReveal: Bool = true,
        sendOnEnter: Bool = true,
        defaultProviderId: String = "builtin-openrouter",
        defaultModelId: String = "anthropic/claude-3.5-sonnet",
        enableWebSearchTool: Bool = true,
        enableTerminalTool: Bool = true,
        enableMemoryTool: Bool = true,
        enableFileAccessTool: Bool = true,
        enableBrowserTool: Bool = true,
        enableWorkspaceTool: Bool = true,
        enableMCPTool: Bool = true,
        enableUnsandboxedGateway: Bool = false,
        remoteGatewayURL: String = ""
    ) {
        self.theme = theme
        self.hapticsEnabled = hapticsEnabled
        self.autoScroll = autoScroll
        self.smoothStreamReveal = smoothStreamReveal
        self.sendOnEnter = sendOnEnter
        self.defaultProviderId = defaultProviderId
        self.defaultModelId = defaultModelId
        self.enableWebSearchTool = enableWebSearchTool
        self.enableTerminalTool = enableTerminalTool
        self.enableMemoryTool = enableMemoryTool
        self.enableFileAccessTool = enableFileAccessTool
        self.enableBrowserTool = enableBrowserTool
        self.enableWorkspaceTool = enableWorkspaceTool
        self.enableMCPTool = enableMCPTool
        self.enableUnsandboxedGateway = enableUnsandboxedGateway
        self.remoteGatewayURL = remoteGatewayURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            theme: try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system,
            hapticsEnabled: try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true,
            autoScroll: try container.decodeIfPresent(Bool.self, forKey: .autoScroll) ?? true,
            smoothStreamReveal: try container.decodeIfPresent(Bool.self, forKey: .smoothStreamReveal) ?? true,
            sendOnEnter: try container.decodeIfPresent(Bool.self, forKey: .sendOnEnter) ?? true,
            defaultProviderId: try container.decodeIfPresent(String.self, forKey: .defaultProviderId) ?? "builtin-openrouter",
            defaultModelId: try container.decodeIfPresent(String.self, forKey: .defaultModelId) ?? "anthropic/claude-3.5-sonnet",
            enableWebSearchTool: try container.decodeIfPresent(Bool.self, forKey: .enableWebSearchTool) ?? true,
            enableTerminalTool: try container.decodeIfPresent(Bool.self, forKey: .enableTerminalTool) ?? true,
            enableMemoryTool: try container.decodeIfPresent(Bool.self, forKey: .enableMemoryTool) ?? true,
            enableFileAccessTool: try container.decodeIfPresent(Bool.self, forKey: .enableFileAccessTool) ?? true,
            enableBrowserTool: try container.decodeIfPresent(Bool.self, forKey: .enableBrowserTool) ?? true,
            enableWorkspaceTool: try container.decodeIfPresent(Bool.self, forKey: .enableWorkspaceTool) ?? true,
            enableMCPTool: try container.decodeIfPresent(Bool.self, forKey: .enableMCPTool) ?? true,
            enableUnsandboxedGateway: try container.decodeIfPresent(Bool.self, forKey: .enableUnsandboxedGateway) ?? false,
            remoteGatewayURL: try container.decodeIfPresent(String.self, forKey: .remoteGatewayURL) ?? ""
        )
    }
}
