import SwiftUI
import Combine

public struct BackupApplyResult: Equatable {
    public let conversationsAdded: Int
    public let providersAdded: Int
    public let charactersAdded: Int
    public let skillsAdded: Int

    public init(conversationsAdded: Int, providersAdded: Int, charactersAdded: Int, skillsAdded: Int) {
        self.conversationsAdded = conversationsAdded
        self.providersAdded = providersAdded
        self.charactersAdded = charactersAdded
        self.skillsAdded = skillsAdded
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var conversations: [Conversation] = []
    @Published public var selectedConversationId: String? = nil
    /// Main tab contract: Home = 0, Chat = 1, Characters = 2, Settings = 3.
    @Published public var selectedTab: Int = 0
    @Published public var providers: [ModelProvider] = []
    @Published public var characters: [Character] = []
    @Published public var memory: MemoryDocument = .default
    @Published public var settings: AppSettings = AppSettings()
    @Published public var mcpServers: [McpServer] = []
    @Published public var skills: [Skill] = Skill.defaults
    /// Imported Android fields that are not represented by the iOS runtime are retained for
    /// subsequent backup exports and persisted across app launches.
    @Published public var backupPreservation: PilotAIBackupPayload?
    @Published public var isGenerating: Bool = false
    @Published public var terminalOutput: [String] = [
        "PilotAI Interactive Shell [iOS Environment]",
        "Type 'help' or any command to simulate execution.",
        "Persistent session active.\n"
    ]
    
    private let storage = StorageService.shared
    private let engine = AgentEngine.shared
    
    public init() {
        self.conversations = storage.loadConversations()
        self.providers = storage.loadProviders()
        self.characters = storage.loadCharacters()
        self.memory = storage.loadMemory()
        self.settings = storage.loadSettings()
        self.mcpServers = storage.loadMcpServers()
        self.skills = storage.loadSkills()
        self.backupPreservation = storage.loadBackupPreservation()
        
        if let first = conversations.first {
            self.selectedConversationId = first.id
        } else {
            newConversation()
        }
    }
    
    public var selectedConversation: Conversation? {
        get {
            guard let id = selectedConversationId else { return conversations.first }
            return conversations.first(where: { $0.id == id }) ?? conversations.first
        }
        set {
            if let val = newValue, let index = conversations.firstIndex(where: { $0.id == val.id }) {
                conversations[index] = val
                storage.saveConversations(conversations)
            }
        }
    }
    
    public var currentProvider: ModelProvider? {
        if let conv = selectedConversation,
           let prov = providers.first(where: { $0.id == conv.providerId && $0.isEnabled }) {
            return prov
        }
        return providers.first(where: { $0.id == settings.defaultProviderId && $0.isEnabled })
            ?? providers.first(where: { $0.isEnabled })
            ?? providers.first
    }

    public func selectProvider(id: String) {
        guard let prov = providers.first(where: { $0.id == id }) else { return }
        let activeModelId = !prov.defaultModelId.isEmpty ? prov.defaultModelId : (prov.models.first?.id ?? "")
        selectModel(providerId: id, modelId: activeModelId)
    }

    public func selectModel(providerId: String, modelId: String) {
        settings.defaultProviderId = providerId
        settings.defaultModelId = modelId
        saveSettings()
        
        // Update default model inside the target provider
        if let pIdx = providers.firstIndex(where: { $0.id == providerId }) {
            providers[pIdx].defaultModelId = modelId
            storage.saveProviders(providers)
        }
        
        if var conv = selectedConversation {
            conv.providerId = providerId
            conv.modelId = modelId
            selectedConversation = conv
            if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
                conversations[idx] = conv
                storage.saveConversations(conversations)
            }
        }
    }
    
    public var currentCharacter: Character? {
        guard let conv = selectedConversation, let charId = conv.characterId else { return nil }
        return characters.first(where: { $0.id == charId })
    }
    
    // MARK: - Actions
    
    public func newConversation(mode: ConversationMode = .agent, characterId: String? = nil, greeting: String? = nil) {
        let provider = providers.first(where: { $0.id == settings.defaultProviderId && $0.isEnabled })
            ?? providers.first(where: { $0.isEnabled })
            ?? providers.first
            ?? ModelProvider.defaults[0]
            
        let model = provider.models.contains(where: { $0.id == settings.defaultModelId })
            ? settings.defaultModelId
            : (!provider.defaultModelId.isEmpty ? provider.defaultModelId : (provider.models.first?.id ?? ""))
        
        var initialMessages: [Message] = []
        var title = "New Conversation"
        
        if let charId = characterId, let char = characters.first(where: { $0.id == charId }) {
            title = "\(char.name) Chat"
            let openingGreeting = greeting ?? char.greeting
            if !openingGreeting.isEmpty {
                initialMessages.append(Message(role: .assistant, content: openingGreeting, modelName: model))
            }
        }
        
        let newConv = Conversation(
            title: title,
            messages: initialMessages,
            providerId: provider.id,
            modelId: model,
            mode: mode,
            characterId: characterId
        )
        conversations.insert(newConv, at: 0)
        selectedConversationId = newConv.id
        // Starting a roleplay from the character library should take the user to the
        // conversation immediately, matching the Android navigation flow.
        if characterId != nil { selectedTab = 1 }
        storage.saveConversations(conversations)
    }
    
    public func deleteConversation(id: String) {
        conversations.removeAll(where: { $0.id == id })
        if selectedConversationId == id {
            selectedConversationId = conversations.first?.id
        }
        storage.saveConversations(conversations)
    }

    public func renameConversation(id: String, title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversations[index].title = String(trimmed.prefix(120))
        conversations[index].updatedAt = Date()
        storage.saveConversations(conversations)
    }

    public func duplicateConversation(id: String) {
        guard let source = conversations.first(where: { $0.id == id }) else { return }
        let copiedMessages = source.messages.map { message in
            Message(role: message.role, content: message.content,
                    reasoningContent: message.reasoningContent, toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    isStreaming: false, timestamp: message.timestamp, modelName: message.modelName,
                    attachments: message.attachments)
        }
        let copy = Conversation(title: "\(source.title) (Copy)", messages: copiedMessages,
                                providerId: source.providerId, modelId: source.modelId,
                                mode: source.mode, characterId: source.characterId)
        conversations.insert(copy, at: 0)
        selectedConversationId = copy.id
        selectedTab = 1
        storage.saveConversations(conversations)
    }
    
    public func deleteMessage(id: String) {
        guard var conv = selectedConversation else { return }
        conv.messages.removeAll(where: { $0.id == id })
        selectedConversation = conv
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
            storage.saveConversations(conversations)
        }
    }
    
    public func rerunMessage(id: String) {
        guard var conv = selectedConversation else { return }
        guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { return }
        
        // Find preceding user prompt
        var userPrompt = ""
        var userAttachments: [MessageAttachment] = []
        for i in (0..<idx).reversed() {
            if conv.messages[i].role == .user {
                userPrompt = conv.messages[i].content
                userAttachments = conv.messages[i].attachments ?? []
                break
            }
        }
        
        guard !userPrompt.isEmpty || !userAttachments.isEmpty else { return }
        
        // Remove assistant message and any subsequent messages
        conv.messages.removeSubrange(idx..<conv.messages.count)
        selectedConversation = conv
        if let convIdx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[convIdx] = conv
            storage.saveConversations(conversations)
        }
        
        // Re-send prompt with the original attachment payloads.
        sendMessage(userPrompt, attachments: userAttachments)
    }
    
    @discardableResult
    public func undoUserMessage(id: String) -> String? {
        guard var conv = selectedConversation else { return nil }
        guard let idx = conv.messages.firstIndex(where: { $0.id == id }) else { return nil }
        
        let userText = conv.messages[idx].content
        
        // Remove from this user message onwards
        conv.messages.removeSubrange(idx..<conv.messages.count)
        selectedConversation = conv
        if let convIdx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[convIdx] = conv
            storage.saveConversations(conversations)
        }
        
        return userText
    }
    
    public func sendMessage(_ text: String, attachments: [MessageAttachment] = [], webSearchEnabled: Bool = false, reasoningEnabled: Bool = false) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conv = selectedConversation, !trimmedText.isEmpty || !attachments.isEmpty else { return }
        guard let prov = currentProvider else { return }
        
        let userMsg = Message(role: .user, content: text, attachments: attachments.isEmpty ? nil : attachments)
        var updatedMessages = conv.messages
        updatedMessages.append(userMsg)
        
        // Auto update title on first message
        var title = conv.title
        if conv.messages.filter({ $0.role == .user }).isEmpty {
            title = String(trimmedText.prefix(28))
            if title.isEmpty { title = attachments.first?.name ?? "Attachment" }
        }
        
        var updatedConv = conv
        updatedConv.title = title
        updatedConv.messages = updatedMessages
        updatedConv.updatedAt = Date()
        selectedConversation = updatedConv
        
        isGenerating = true
        
        engine.send(
            prompt: text,
            conversation: updatedConv,
            provider: prov,
            character: currentCharacter,
            memory: memory,
            webSearchEnabled: webSearchEnabled,
            reasoningEnabled: reasoningEnabled,
            settings: settings,
            skills: skills,
            conversations: conversations,
            mcpServers: mcpServers,
            onMemoryUpdate: { [weak self] updated in
                self?.memory = updated
            },
            onMCPUpdate: { [weak self] refreshed in
                guard let self else { return }
                for server in refreshed { self.updateMcpServer(server) }
            },
            onUpdate: { [weak self] streamingMsg in
                guard let self = self,
                      let index = self.conversations.firstIndex(where: { $0.id == updatedConv.id }) else { return }
                var origin = self.conversations[index]
                if let last = origin.messages.last, last.role == .assistant && last.isStreaming {
                    origin.messages[origin.messages.count - 1] = streamingMsg
                } else {
                    origin.messages.append(streamingMsg)
                }
                origin.updatedAt = Date()
                self.conversations[index] = origin
            },
            onCompletion: { [weak self] _ in
                guard let self = self else { return }
                self.isGenerating = false
                self.storage.saveConversations(self.conversations)
            }
        )
    }
    
    public func stopGenerating() {
        engine.stop()
        isGenerating = false
        if var conv = selectedConversation, let last = conv.messages.last, last.isStreaming {
            var updated = last
            updated.isStreaming = false
            conv.messages[conv.messages.count - 1] = updated
            selectedConversation = conv
        }
    }
    
    public func runTerminalCommand(_ cmd: String) {
        terminalOutput.append("$ \(cmd)")
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if trimmed == "clear" {
            terminalOutput.removeAll()
            return
        }
        
        if settings.enableTerminalTool && settings.enableUnsandboxedGateway {
            Task { @MainActor in
                do {
                    let output = try await IOSRuntimeToolService.executeGatewayCommand(cmd, settings: self.settings)
                    self.terminalOutput.append(output)
                } catch {
                    self.terminalOutput.append("Gateway Connection Error: \(error.localizedDescription)")
                }
                self.terminalOutput.append("")
            }
            return
        }
        
        switch trimmed {
        case "help":
            terminalOutput.append("Available commands: help, info, clear, models, status, uname, date")
        case "info":
            terminalOutput.append("PilotAI Mobile Agent Engine v3.0.5 (iOS arm64)")
            terminalOutput.append("Bundle ID: com.pilotai")
        case "models":
            for p in providers {
                terminalOutput.append("Provider: \(p.name) (\(p.models.count) models)")
            }
        case "status":
            terminalOutput.append("Memory Active: \(memory.isAutoInjectEnabled ? "YES" : "NO")")
            terminalOutput.append("Conversations Count: \(conversations.count)")
            terminalOutput.append("Unsandboxed Gateway: \(settings.enableUnsandboxedGateway ? "ACTIVE" : "DISABLED")")
        case "uname":
            terminalOutput.append("Darwin Kernel arm64 iOS / PilotAI-Sandboxed")
        case "date":
            terminalOutput.append(Date().description)
        default:
            terminalOutput.append("pilot: local iOS shell access is unavailable; '\(cmd)' was not executed. Enable the explicit Remote Gateway to run it on a user-controlled machine.")
        }
        terminalOutput.append("")
    }
    
    public func saveMemory(_ newDoc: MemoryDocument) {
        self.memory = newDoc
        storage.saveMemory(newDoc)
    }
    
    public func saveProviders() {
        storage.saveProviders(providers)
    }
    
    public func saveSettings() {
        storage.saveSettings(settings)
    }
    
    public func saveCharacters() {
        storage.saveCharacters(characters)
    }

    public func applyBackup(_ payload: PilotAIBackupPayload) -> BackupApplyResult {
        let conversationsAdded = mergeByID(payload.conversations ?? [], into: &conversations)
        let providersAdded = mergeByID(payload.providers ?? [], into: &providers)
        let charactersAdded = mergeByID(payload.characters ?? [], into: &characters)
        let skillsAdded = mergeByID(payload.skills ?? [], into: &skills)

        if let importedMemory = payload.memory {
            memory = importedMemory
        } else if let markdown = payload.memoryMd, !markdown.isEmpty {
            memory.markdown = markdown
            memory.lastModified = Date()
        }

        if let importedSettings = payload.settings {
            settings = importedSettings
        }

        if let importedServers = payload.mcpServers {
            _ = mergeByID(importedServers, into: &mcpServers)
        }

        if let providerID = payload.selectedProviderId,
           let provider = providers.first(where: { $0.id == providerID }) {
            settings.defaultProviderId = provider.id
            if let modelID = payload.selectedModelId,
               provider.models.isEmpty || provider.models.contains(where: { $0.id == modelID }) {
                settings.defaultModelId = modelID
            } else if !provider.defaultModelId.isEmpty {
                settings.defaultModelId = provider.defaultModelId
            }
        }

        backupPreservation = payload
        storage.saveConversations(conversations)
        storage.saveProviders(providers)
        storage.saveCharacters(characters)
        storage.saveSkills(skills)
        storage.saveMcpServers(mcpServers)
        storage.saveMemory(memory)
        storage.saveSettings(settings)
        storage.saveBackupPreservation(payload)

        return BackupApplyResult(conversationsAdded: conversationsAdded, providersAdded: providersAdded,
                                 charactersAdded: charactersAdded, skillsAdded: skillsAdded)
    }

    public func clearBackupPreservation() {
        backupPreservation = nil
        storage.saveBackupPreservation(nil)
    }

    private func mergeByID<T: Identifiable>(_ incoming: [T], into target: inout [T]) -> Int where T.ID == String {
        let existingIDs = Set(target.map(\.id))
        let additions = incoming.filter { !existingIDs.contains($0.id) }
        target.append(contentsOf: additions)
        return additions.count
    }
    
    public func addProvider(_ provider: ModelProvider) {
        providers.append(provider)
        storage.saveProviders(providers)
    }

    public func deleteProvider(id: String) {
        providers.removeAll(where: { $0.id == id })
        storage.saveProviders(providers)
    }

    public func duplicateProvider(id: String) {
        guard let source = providers.first(where: { $0.id == id }) else { return }
        var clone = source
        clone.id = UUID().uuidString
        clone.name = "\(source.name) (Copy)"
        clone.isBuiltIn = false
        providers.append(clone)
        storage.saveProviders(providers)
    }

    public func updateProvider(_ provider: ModelProvider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
            storage.saveProviders(providers)
        }
    }

    public func resetProvider(id: String) {
        if let def = ModelProvider.defaults.first(where: { $0.id == id }),
           let idx = providers.firstIndex(where: { $0.id == id }) {
            var reset = def
            reset.apiKey = providers[idx].apiKey // preserve API key
            providers[idx] = reset
            storage.saveProviders(providers)
        }
    }

    public func addModel(to providerId: String, model: ModelDefinition) {
        if let idx = providers.firstIndex(where: { $0.id == providerId }) {
            providers[idx].models.append(model)
            storage.saveProviders(providers)
        }
    }

    public func updateModel(in providerId: String, model: ModelDefinition) {
        if let pIdx = providers.firstIndex(where: { $0.id == providerId }),
           let mIdx = providers[pIdx].models.firstIndex(where: { $0.id == model.id }) {
            providers[pIdx].models[mIdx] = model
            storage.saveProviders(providers)
        }
    }

    public func deleteModel(from providerId: String, modelId: String) {
        if let pIdx = providers.firstIndex(where: { $0.id == providerId }) {
            providers[pIdx].models.removeAll(where: { $0.id == modelId })
            storage.saveProviders(providers)
        }
    }

    public func fetchModels(for providerId: String) async {
        guard let provider = providers.first(where: { $0.id == providerId }) else { return }
        guard let url = URL(string: provider.baseURL.hasSuffix("/models") ? provider.baseURL : provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for header in provider.customHeaders {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]] {
                let fetched: [ModelDefinition] = dataArray.compactMap { obj in
                    guard let id = obj["id"] as? String else { return nil }
                    return ModelDefinition(id: id, name: id)
                }
                await MainActor.run {
                    if let pIdx = self.providers.firstIndex(where: { $0.id == providerId }) {
                        // Merge: keep existing custom models, add new ones
                        var existing = self.providers[pIdx].models
                        let existingIds = Set(existing.map { $0.id })
                        let newModels = fetched.filter { !existingIds.contains($0.id) }
                        existing.append(contentsOf: newModels)
                        self.providers[pIdx].models = existing
                        self.storage.saveProviders(self.providers)
                    }
                }
            }
        } catch {
            // silently fail, UI will show error
        }
    }

    public func addCharacter(_ char: Character) {
        characters.insert(char, at: 0)
        storage.saveCharacters(characters)
    }

    public func updateCharacter(_ char: Character) {
        if let idx = characters.firstIndex(where: { $0.id == char.id }) {
            characters[idx] = char
            storage.saveCharacters(characters)
        }
    }

    public func deleteCharacter(id: String) {
        characters.removeAll(where: { $0.id == id })
        storage.saveCharacters(characters)
    }

    public func addMcpServer(_ server: McpServer) {
        mcpServers.append(server)
        storage.saveMcpServers(mcpServers)
    }
    public func updateMcpServer(_ server: McpServer) {
        if let idx = mcpServers.firstIndex(where: { $0.id == server.id }) {
            mcpServers[idx] = server
            storage.saveMcpServers(mcpServers)
        }
    }
    public func deleteMcpServer(id: String) {
        mcpServers.removeAll(where: { $0.id == id })
        storage.saveMcpServers(mcpServers)
    }

    public func addSkill(_ skill: Skill) {
        skills.append(skill)
        storage.saveSkills(skills)
    }
    public func updateSkill(_ skill: Skill) {
        if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[idx] = skill
            storage.saveSkills(skills)
        }
    }
    public func deleteSkill(id: String) {
        skills.removeAll(where: { $0.id == id })
        storage.saveSkills(skills)
    }
}
