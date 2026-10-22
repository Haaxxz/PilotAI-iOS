import SwiftUI

public struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @State private var inputText: String = ""
    @State private var showHistorySheet: Bool = false
    @State private var showModelPicker: Bool = false
    @State private var showTerminalSheet: Bool = false
    @State private var showBrowserSheet: Bool = false
    
    public init() {}
    
    private var currentModelName: String {
        guard let conv = state.selectedConversation else {
            return state.currentProvider?.models.first?.name ?? "Default"
        }
        if let m = state.currentProvider?.models.first(where: { $0.id == conv.modelId }) {
            return m.name
        }
        return conv.modelId
    }
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Main Message List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if let conv = state.selectedConversation {
                                if conv.messages.isEmpty {
                                    emptyWelcomeView
                                        .padding(.top, 40)
                                } else {
                                    ForEach(conv.messages) { message in
                                        MessageBubbleView(
                                            message: message,
                                            onDelete: {
                                                state.deleteMessage(id: message.id)
                                            },
                                            onRerun: {
                                                state.rerunMessage(id: message.id)
                                            },
                                            onUndo: {
                                                if let undoneText = state.undoUserMessage(id: message.id) {
                                                    inputText = undoneText
                                                }
                                            }
                                        )
                                        .id(message.id)
                                    }
                                }
                            }
                            
                            Color.clear
                                .frame(height: 1)
                                .id("bottomAnchor")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        hideKeyboard()
                    }
                    .onAppear {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onChange(of: state.selectedConversationId) { _ in
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    .onChange(of: state.selectedConversation?.messages.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: state.selectedConversation?.messages.last?.content) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                
                // Bottom Input Bar
                InputBarView(
                    text: $inputText,
                    isGenerating: state.isGenerating,
                    onSend: { attachments, webSearch, reasoning in
                        state.sendMessage(inputText, attachments: attachments, webSearchEnabled: webSearch, reasoningEnabled: reasoning)
                    },
                    onStop: {
                        state.stopGenerating()
                    }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showHistorySheet = true }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 16))
                    }
                }
                
                ToolbarItem(placement: .principal) {
                    Button(action: { showModelPicker = true }) {
                        VStack(spacing: 2) {
                            Text(state.selectedConversation?.title ?? "PilotAI")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            HStack(spacing: 4) {
                                Text("\(state.currentProvider?.name ?? "Provider") · \(currentModelName)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { state.newConversation() }) {
                            Label("New Conversation", systemImage: "square.and.pencil")
                        }
                        Button(action: { showTerminalSheet = true }) {
                            Label("Open Terminal", systemImage: "terminal")
                        }
                        Button(action: { showBrowserSheet = true }) {
                            Label("Launch Kimi Web", systemImage: "sparkles")
                        }
                        Button(action: { showBrowserSheet = true }) {
                            Label("Open Browser", systemImage: "safari")
                        }
                        if let conversation = state.selectedConversation {
                            Divider()
                            Button {
                                state.duplicateConversation(id: conversation.id)
                            } label: {
                                Label("Duplicate Conversation", systemImage: "plus.square.on.square")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17))
                    }
                }
            }
            .sheet(isPresented: $showHistorySheet) {
                ConversationListView()
                    .environmentObject(state)
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheetView()
                    .environmentObject(state)
            }
            .sheet(isPresented: $showTerminalSheet) {
                TerminalView()
                    .environmentObject(state)
            }
            .sheet(isPresented: $showBrowserSheet) {
                BrowserView()
                    .environmentObject(state)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private var emptyWelcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            VStack(spacing: 6) {
                Text("What would you like to build?")
                    .font(.system(size: 20, weight: .bold))
                
                Text("PilotAI is ready to write code, analyze data, and assist across platforms.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            VStack(spacing: 10) {
                suggestionCard(title: "Code Architecture", prompt: "Explain clean architecture for a cross-platform mobile app")
                suggestionCard(title: "Roleplay Companions", prompt: "Tell me about Xiaoman and Traveler roleplay characters")
                suggestionCard(title: "Terminal Execution", prompt: "How do I run persistent terminal commands inside PilotAI?")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }
    
    private func suggestionCard(title: String, prompt: String) -> some View {
        Button(action: {
            inputText = prompt
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        guard state.settings.autoScroll else { return }
        guard let messages = state.selectedConversation?.messages, !messages.isEmpty else { return }
        
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        }
    }
}


struct ModelPickerSheetView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery: String = ""
    
    private var filteredProviders: [(provider: ModelProvider, models: [ModelDefinition])] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeProviders = state.providers.filter { $0.isEnabled }
        
        if q.isEmpty {
            return activeProviders.map { ($0, $0.models) }
        }
        
        return activeProviders.compactMap { provider in
            let matchesProvider = provider.name.lowercased().contains(q)
            let matchingModels = provider.models.filter { model in
                matchesProvider || model.name.lowercased().contains(q) || model.id.lowercased().contains(q)
            }
            if matchingModels.isEmpty { return nil }
            return (provider, matchingModels)
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search models or providers…", text: $searchQuery)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                if filteredProviders.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "slash.circle")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("No models matching \"\(searchQuery)\"")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    }
                } else {
                    ForEach(filteredProviders, id: \.provider.id) { item in
                        Section(header: Text(item.provider.name)) {
                            ForEach(item.models) { model in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name)
                                            .font(.system(size: 15, weight: .medium))
                                        Text(model.id)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if item.provider.id == state.currentProvider?.id && model.id == (state.selectedConversation?.modelId ?? state.currentProvider?.defaultModelId) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    state.selectModel(providerId: item.provider.id, modelId: model.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Provider & Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

