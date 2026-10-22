import SwiftUI

public struct AgentToolsView: View {
    @EnvironmentObject private var state: AppState
    
    public init() {}
    
    public var body: some View {
        List {
            Section(header: Text("Built-in Agent Tools"), footer: Text("Enable or disable specific function-calling capabilities available to the LLM agent.")) {
                Toggle(isOn: $state.settings.enableWebSearchTool) {
                    Label("Web Search Tool", systemImage: "globe")
                }
                Toggle(isOn: $state.settings.enableTerminalTool) {
                    Label("Terminal Tool", systemImage: "terminal.fill")
                }
                Toggle(isOn: $state.settings.enableMemoryTool) {
                    Label("Memory Persistence Tool", systemImage: "brain.head.profile")
                }
                Toggle(isOn: $state.settings.enableFileAccessTool) {
                    Label("File Read / Write Tool", systemImage: "doc.text.fill")
                }
                Toggle(isOn: $state.settings.enableBrowserTool) {
                    Label("Shared Browser Tool", systemImage: "safari")
                }
                Toggle(isOn: $state.settings.enableWorkspaceTool) {
                    Label("Private Workspace Tool", systemImage: "folder.badge.gearshape")
                }
                Toggle(isOn: $state.settings.enableMCPTool) {
                    Label("MCP Server Tools", systemImage: "server.rack")
                }
            }
        }
        .onChange(of: state.settings.enableWebSearchTool) { _ in state.saveSettings() }
        .onChange(of: state.settings.enableTerminalTool) { _ in state.saveSettings() }
        .onChange(of: state.settings.enableMemoryTool) { _ in state.saveSettings() }
        .onChange(of: state.settings.enableFileAccessTool) { _ in state.saveSettings() }
        .onChange(of: state.settings.enableBrowserTool) { _ in state.saveSettings() }
        .onChange(of: state.settings.enableWorkspaceTool) { _ in state.saveSettings() }
        .onChange(of: state.settings.enableMCPTool) { _ in state.saveSettings() }
        .navigationTitle("Agent Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
