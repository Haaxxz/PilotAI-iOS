import SwiftUI

public struct ConversationListView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var shareData: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var conversationToRename: Conversation?
    @State private var renameText: String = ""
    
    public init() {}
    
    var filteredConversations: [Conversation] {
        if searchQuery.isEmpty {
            return state.conversations
        } else {
            return state.conversations.filter { conv in
                conv.title.localizedCaseInsensitiveContains(searchQuery) ||
                conv.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(searchQuery) })
            }
        }
    }
    
    public var body: some View {
        NavigationView {
            List {
                Section(header: Text("Conversations")) {
                    ForEach(filteredConversations) { conv in
                        Button(action: {
                            state.selectedConversationId = conv.id
                            dismiss()
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: conv.mode.iconName)
                                    .font(.system(size: 16))
                                    .foregroundColor(.blue)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conv.title)
                                        .font(.system(size: 15, weight: state.selectedConversationId == conv.id ? .semibold : .regular))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    
                                    HStack {
                                        Text(conv.modelId)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        Text(conv.updatedAt, style: .date)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                if state.selectedConversationId == conv.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                exportConversation(conv)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                state.duplicateConversation(id: conv.id)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button {
                                renameText = conv.title
                                conversationToRename = conv
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button {
                                exportConversation(conv)
                            } label: {
                                Label("Export Markdown", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                state.deleteConversation(id: conv.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            guard filteredConversations.indices.contains(index) else { continue }
                            state.deleteConversation(id: filteredConversations[index].id)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        state.newConversation()
                        dismiss()
                    }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .searchable(text: $searchQuery, prompt: "Search conversations...")
            .sheet(isPresented: $showShareSheet) {
                if let url = shareData {
                    ShareSheet(items: [url])
                }
            }
            .alert("Rename Conversation", isPresented: Binding(
                get: { conversationToRename != nil },
                set: { if !$0 { conversationToRename = nil } }
            )) {
                TextField("Conversation title", text: $renameText)
                Button("Cancel", role: .cancel) { conversationToRename = nil }
                Button("Save") {
                    guard let conversation = conversationToRename else { return }
                    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        state.renameConversation(id: conversation.id, title: title)
                    }
                    conversationToRename = nil
                }
            } message: {
                Text("Choose a title for this conversation.")
            }
        }
    }
    
    private func exportConversation(_ conv: Conversation) {
        var md = "# \(conv.title)\n\n"
        for msg in conv.messages {
            let roleName = msg.role == .user ? "User" : "Assistant"
            md += "### \(roleName)\n"
            md += "\(msg.content)\n\n"
        }
        
        let filename = conv.title.replacingOccurrences(of: " ", with: "_").lowercased() + ".md"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try md.write(to: tempURL, atomically: true, encoding: .utf8)
            self.shareData = tempURL
            self.showShareSheet = true
        } catch {
            print("Failed to export conversation: \(error)")
        }
    }
}
