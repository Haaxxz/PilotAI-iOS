import SwiftUI

public struct McpServersView: View {
    @EnvironmentObject private var state: AppState
    @State private var editingServer: McpServer? = nil
    
    public init() {}
    
    public var body: some View {
        List {
            Section(header: Text("Model Context Protocol (MCP)")) {
                Text("Connect external tools, databases, and services to your AI agent via MCP servers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Configured Servers")) {
                if state.mcpServers.isEmpty {
                    Text("No MCP servers configured.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(state.mcpServers) { server in
                        HStack {
                            Button { editingServer = server } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.name).font(.headline).foregroundColor(.primary)
                                    Text("\(server.transportType.displayName) · \(server.urlOrCommand)")
                                        .font(.caption).fontDesign(.monospaced)
                                        .foregroundColor(.secondary).lineLimit(1)
                                    Text("\(server.activeTools.count) of \(server.tools.count) tools enabled")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { server.isEnabled },
                                set: { val in
                                    guard var updated = state.mcpServers.first(where: { $0.id == server.id }) else { return }
                                    updated.isEnabled = val
                                    state.updateMcpServer(updated)
                                }
                            ))
                            .labelsHidden()
                            .accessibilityLabel("Enable \(server.name)")
                            .disabled(server.transportType == .stdio && !server.isEnabled)
                        }
                    }
                    .onDelete { idxSet in
                        idxSet.map { state.mcpServers[$0] }.forEach { state.deleteMcpServer(id: $0.id) }
                    }
                }
            }
            
            Section {
                Button(action: {
                    editingServer = McpServer(name: "", urlOrCommand: "")
                }) {
                    Label("Add MCP Server", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingServer) { server in
            McpServerEditorSheet(server: server) { updated in
                if state.mcpServers.contains(where: { $0.id == updated.id }) {
                    state.updateMcpServer(updated)
                } else {
                    state.addMcpServer(updated)
                }
                editingServer = nil
            } onCancel: { editingServer = nil }
        }
    }
}

struct McpServerEditorSheet: View {
    let server: McpServer
    let onSave: (McpServer) -> Void
    let onCancel: () -> Void
    
    @State private var draft: McpServer
    @State private var isDiscovering = false
    @State private var discoveryTask: Task<Void, Never>?
    @State private var discoveryError: String?
    
    init(server: McpServer, onSave: @escaping (McpServer) -> Void, onCancel: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onCancel = onCancel
        var draft = server
        // Existing custom Bearer headers remain editable through the new token field.
        for (key, value) in server.headers where key.lowercased() == "authorization" && value.lowercased().hasPrefix("bearer ") {
            if draft.bearerToken.isEmpty { draft.bearerToken = String(value.dropFirst(7)) }
            draft.headers.removeValue(forKey: key)
        }
        _draft = State(initialValue: draft)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Info")) {
                    TextField("Server Name", text: $draft.name)
                    Picker("Transport", selection: $draft.transportType) {
                        ForEach(McpServer.TransportType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField(draft.transportType == .sse ? "https://example.com/mcp" : "Executable Command", text: $draft.urlOrCommand)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if draft.transportType == .sse {
                        Picker("Protocol", selection: $draft.protocolMode) {
                            ForEach(McpServer.ProtocolMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        SecureField("Bearer Token (optional)", text: $draft.bearerToken)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .disabled(isDiscovering)
                
                Section {
                    Toggle("Enable Server", isOn: $draft.isEnabled)
                        .disabled(isDiscovering || (draft.transportType == .stdio && !draft.isEnabled))
                    if draft.transportType == .stdio {
                        Text("Local stdio commands cannot run on iOS. Use a Streamable HTTP endpoint for this server.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                if draft.transportType == .sse {
                    Section(header: Text("Tool Discovery")) {
                        Button(action: discoverTools) {
                            HStack {
                                Label(draft.lastRefreshedAt == nil ? "Discover Tools" : "Refresh Tools", systemImage: "arrow.clockwise")
                                Spacer()
                                if isDiscovering { ProgressView() }
                            }
                        }
                        .disabled(!canSave || isDiscovering)
                        if let error = discoveryError {
                            Text(error).font(.caption).foregroundColor(.red)
                        }
                        if let version = draft.lastProtocolVersion {
                            Text("Protocol: \(version)").font(.caption).foregroundColor(.secondary)
                        }
                        if let refreshed = draft.lastRefreshedAt {
                            Text("Refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if let expiry = draft.toolsExpireAt {
                            Text(expiry <= Date() ? "Catalog expired; it will be refreshed before the next run." : "Catalog expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Section {
                        if draft.tools.isEmpty {
                            Text(draft.lastRefreshedAt == nil ? "Discover this server's tools, then enable the ones you want to use." : "This server returned no tools.")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        ForEach(draft.tools) { tool in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { draft.enabledToolNames.contains(tool.name) },
                                    set: { enabled in
                                        if enabled { draft.enabledToolNames.insert(tool.name) }
                                        else { draft.enabledToolNames.remove(tool.name) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tool.title.isEmpty ? tool.name : tool.title).font(.headline)
                                        if !tool.title.isEmpty {
                                            Text(tool.name).font(.caption).fontDesign(.monospaced).foregroundColor(.secondary)
                                        }
                                    }
                                }
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(.caption).foregroundColor(.secondary)
                                }
                                Text(annotationSummary(tool)).font(.caption).foregroundColor(.secondary)
                                DisclosureGroup("Input Schema") {
                                    Text(tool.inputSchemaJson)
                                        .font(.caption2).fontDesign(.monospaced).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption)
                            }
                        }
                        .disabled(isDiscovering)
                    } header: {
                        Text("Tools (\(draft.enabledToolNames.intersection(draft.tools.map(\.name)).count)/\(draft.tools.count) enabled)")
                    } footer: {
                        Text("New tools are off by default. Hints are reported by the server. Save to apply your selections to future runs.")
                    }
                }
            }
            .navigationTitle(server.name.isEmpty ? "New MCP Server" : "Edit MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { discoveryTask?.cancel(); onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(normalizedDraft)
                    }
                    .disabled(!canSave || isDiscovering)
                }
            }
        }
        .onChange(of: connectionIdentity) { _ in
            // Endpoint/account changes must not inherit permission for a different catalog.
            draft.tools = []
            draft.enabledToolNames = []
            draft.lastRefreshedAt = nil
            draft.lastProtocolVersion = nil
            draft.toolsExpireAt = nil
            discoveryError = nil
        }
        .onDisappear { discoveryTask?.cancel() }
    }

    private var normalizedDraft: McpServer {
        var result = draft
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.urlOrCommand = result.urlOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        result.bearerToken = result.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private var connectionIdentity: [String] {
        [normalizedDraft.urlOrCommand, normalizedDraft.bearerToken, draft.transportType.rawValue, draft.protocolMode.rawValue]
    }

    private var canSave: Bool {
        let value = normalizedDraft
        guard !value.name.isEmpty, !value.urlOrCommand.isEmpty else { return false }
        return value.transportType == .stdio || (try? IOSMCPService.validateEndpoint(value.urlOrCommand)) != nil
    }

    private func discoverTools() {
        let requested = normalizedDraft
        isDiscovering = true
        discoveryError = nil
        discoveryTask = Task { @MainActor in
            defer { isDiscovering = false }
            do {
                let discovered = try await IOSMCPService.discover(server: requested)
                try Task.checkCancellation()
                draft = discovered
            } catch {
                if !Task.isCancelled { discoveryError = error.localizedDescription }
            }
        }
    }

    private func annotationSummary(_ tool: McpToolDefinition) -> String {
        var hints: [String] = []
        if let readOnly = tool.readOnlyHint { hints.append(readOnly ? "read-only" : "may modify data") }
        if let destructive = tool.destructiveHint { hints.append(destructive ? "destructive" : "non-destructive") }
        if let idempotent = tool.idempotentHint { hints.append(idempotent ? "idempotent" : "not idempotent") }
        if let openWorld = tool.openWorldHint { hints.append(openWorld ? "external access" : "closed-world") }
        return hints.isEmpty ? "No server behavior hints provided." : "Server hints: " + hints.joined(separator: " · ")
    }
}
