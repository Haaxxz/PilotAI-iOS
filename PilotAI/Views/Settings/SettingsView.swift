import SwiftUI
import UniformTypeIdentifiers

public struct BackupRestoreView: View {
    @EnvironmentObject private var state: AppState
    @State private var shareData: Data? = nil
    @State private var showShareSheet: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var alertMessage: String? = nil
    @State private var showAlert: Bool = false
    
    public init() {}
    
    public var body: some View {
        Form {
            Section(header: Text("Export Data"), footer: Text("Backs up all conversations, provider configurations, custom headers, roleplay characters, and core memories in PilotAI JSON format.")) {
                Button(action: exportData) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export PilotAI Backup (.json)")
                    }
                }
            }
            
            Section(header: Text("Import Data"), footer: Text("Restores PilotAI or Eta data from an existing backup JSON file.")) {
                Button(action: { showFilePicker = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import Backup File")
                    }
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .sheet(isPresented: $showShareSheet) {
            if let data = shareData {
                ShareSheet(items: [data])
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json]) { result in
            do {
                let fileURL = try result.get()
                if fileURL.startAccessingSecurityScopedResource() {
                    defer { fileURL.stopAccessingSecurityScopedResource() }
                    let payload = try BackupService.shared.importBackup(from: fileURL)
                    let result = state.applyBackup(payload)
                    alertMessage = "Backup imported successfully (+\(result.conversationsAdded) conversations, +\(result.providersAdded) providers)."
                    showAlert = true
                }
            } catch {
                alertMessage = "Failed to import backup: \(error.localizedDescription)"
                showAlert = true
            }
        }
        .alert("Backup", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }
    
    private func exportData() {
        do {
            let data = try BackupService.shared.exportBackup(
                providers: state.providers,
                conversations: state.conversations,
                memory: state.memory,
                characters: state.characters,
                selectedProviderId: state.settings.defaultProviderId,
                selectedModelId: state.settings.defaultModelId,
                skills: state.skills, preserving: state.backupPreservation,
                mcpServers: state.mcpServers, settings: state.settings
            )
            self.shareData = data
            self.showShareSheet = true
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
            showAlert = true
        }
    }
}

public struct ShareSheet: UIViewControllerRepresentable {
    public let items: [Any]
    
    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

public struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("AI Models")) {
                    NavigationLink(destination: ProvidersView().environmentObject(state)) {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.blue)
                            Text("Model Providers")
                            Spacer()
                            Text("\(state.providers.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("Agent Capabilities")) {
                    NavigationLink(destination: MemoryView().environmentObject(state)) {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.pink)
                            Text("Core Memory")
                        }
                    }
                    NavigationLink(destination: McpServersView().environmentObject(state)) {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.purple)
                            Text("MCP Servers")
                        }
                    }
                    NavigationLink(destination: SkillsView().environmentObject(state)) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.yellow)
                            Text("Agent Skills")
                        }
                    }
                    NavigationLink(destination: AgentToolsView().environmentObject(state)) {
                        HStack {
                            Image(systemName: "hammer.fill")
                                .foregroundColor(.gray)
                            Text("Agent Tools")
                        }
                    }
                }
                
                Section(header: Text("Appearance")) {
                    Picker("Theme", selection: $state.settings.theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .onChange(of: state.settings.theme) { _ in
                        state.saveSettings()
                    }
                }
                
                Section(header: Text("Preferences")) {
                    Toggle("Haptic Feedback", isOn: $state.settings.hapticsEnabled)
                        .onChange(of: state.settings.hapticsEnabled) { _ in state.saveSettings() }
                    
                    Toggle("Auto-scroll Messages", isOn: $state.settings.autoScroll)
                        .onChange(of: state.settings.autoScroll) { _ in state.saveSettings() }
                    
                    Toggle("Smooth Stream Reveal", isOn: $state.settings.smoothStreamReveal)
                        .onChange(of: state.settings.smoothStreamReveal) { _ in state.saveSettings() }

                    Toggle("Send on Return", isOn: $state.settings.sendOnEnter)
                        .onChange(of: state.settings.sendOnEnter) { _ in state.saveSettings() }
                }
                
                Section(header: Text("Unsandboxed Command Gateway"), footer: Text("Routes terminal commands to a local desktop machine or remote server without iOS app sandbox limits.")) {
                    Toggle("Enable Remote Gateway", isOn: $state.settings.enableUnsandboxedGateway)
                        .onChange(of: state.settings.enableUnsandboxedGateway) { _ in state.saveSettings() }
                    
                    if state.settings.enableUnsandboxedGateway {
                        HStack {
                            Image(systemName: "terminal")
                                .foregroundColor(.green)
                            TextField("http://192.168.1.100:8080", text: $state.settings.remoteGatewayURL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .onChange(of: state.settings.remoteGatewayURL) { _ in state.saveSettings() }
                        }
                    }
                }
                
                Section(header: Text("Data")) {
                    NavigationLink(destination: BackupView().environmentObject(state)) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.orange)
                            Text("Backup & Restore")
                        }
                    }
                    NavigationLink(destination: WorkspaceView()) {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.blue)
                            Text("Private Workspace")
                        }
                    }
                }
                
                Section(header: Text("About PilotAI")) {
                    HStack {
                        Text("Application")
                        Spacer()
                        Text("PilotAI for iOS")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("3.0.5 (2026092301)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Bundle Identifier")
                        Spacer()
                        Text("com.pilotai")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Platform")
                        Spacer()
                        Text("iOS / iPadOS (arm64)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
