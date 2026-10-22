import SwiftUI

/// Home entry point mirrors Android's compact agent shell: recent history, quick actions, and one-tap chat starters.
public struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showBrowser = false
    @State private var showTerminal = false

    public init() {}

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    welcomeHeader
                    quickActions
                    recentConversations
                    suggestions
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .navigationTitle("PilotAI")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            state.newConversation()
                            state.selectedTab = 1
                        } label: {
                            Label("New Conversation", systemImage: "square.and.pencil")
                        }
                        Button {
                            showTerminal = true
                        } label: {
                            Label("Open Terminal", systemImage: "terminal")
                        }
                        Button {
                            showBrowser = true
                        } label: {
                            Label("Open Browser", systemImage: "safari")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showBrowser) { BrowserView().environmentObject(state) }
            .sheet(isPresented: $showTerminal) { TerminalView().environmentObject(state) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var welcomeHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .background(Color.blue.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.title2.bold())
                Text("Your agent workspace is ready.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick actions")
                .font(.headline)
            HStack(spacing: 10) {
                actionCard("New chat", icon: "plus.bubble.fill", color: .blue) {
                    state.newConversation()
                    state.selectedTab = 1
                }
                actionCard("Characters", icon: "person.2.fill", color: .purple) {
                    state.selectedTab = 2
                }
                actionCard("Settings", icon: "gearshape.fill", color: .gray) {
                    state.selectedTab = 3
                }
            }
        }
    }

    private func actionCard(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private var recentConversations: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent conversations")
                    .font(.headline)
                Spacer()
                Button("See all") { state.selectedTab = 1 }
                    .font(.subheadline.weight(.medium))
            }
            if state.conversations.isEmpty {
                Text("Start a conversation to see it here.")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(state.conversations.prefix(4))) { conversation in
                    Button {
                        state.selectedConversationId = conversation.id
                        state.selectedTab = 1
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: conversation.mode.iconName)
                                .foregroundColor(.blue)
                                .frame(width: 30, height: 30)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(conversation.messages.last?.content ?? "No messages yet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(conversation.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking")
                .font(.headline)
            suggestion("Plan a project and break it into actionable steps", icon: "checklist")
            suggestion("Analyze an image or document", icon: "doc.text.magnifyingglass")
        }
    }

    private func suggestion(_ title: String, icon: String) -> some View {
        Button {
            if state.selectedConversation == nil { state.newConversation() }
            state.selectedTab = 1
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundColor(.blue)
                Text(title).font(.subheadline).foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(11)
        }
        .buttonStyle(.plain)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}
