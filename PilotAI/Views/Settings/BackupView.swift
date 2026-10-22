import SwiftUI
import UniformTypeIdentifiers

public struct BackupView: View {
    @EnvironmentObject private var state: AppState
    @State private var showImportPicker = false
    @State private var exportItem: ExportItem?
    @State private var statusMessage: String?
    @State private var isImporting = false

    public init() {}

    public var body: some View {
        Form {
            Section(header: Text("Export"), footer: Text("Exports Android schema-v2 provider/model rows, conversations, messages, character cards, and MEMORY.md. Skills, MCP servers, and settings use an iOS extension. The shared file includes credentials; store it privately.")) {
                Button(action: exportBackup) { Label("Export Backup", systemImage: "square.and.arrow.up") }
            }
            Section(header: Text("Import"), footer: Text("Records with existing IDs are kept while new records are merged. Imported memory and selection preferences can replace current values. Android-only data retained for re-export is not automatically usable in iOS.")) {
                Button(action: { showImportPicker = true }) {
                    Label(isImporting ? "Importing..." : "Import Backup", systemImage: "square.and.arrow.down")
                }.disabled(isImporting)
            }
            if let statusMessage { Section { Text(statusMessage).font(.caption).foregroundColor(statusMessage.contains("success") ? .green : .red) } }
            Section(header: Text("Backup Contents")) {
                LabeledContent("Conversations", value: "\(state.conversations.count)")
                LabeledContent("Providers", value: "\(state.providers.count)")
                LabeledContent("Characters", value: "\(state.characters.count)")
                LabeledContent("Skills", value: "\(state.skills.count)")
                LabeledContent("MCP Servers", value: "\(state.mcpServers.count)")
                LabeledContent("Memory", value: "~\(state.memory.markdown.estimatedTokenCount) tokens")
            }
        }
        .navigationTitle("Backup & Restore").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportItem) { BackupShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { importBackup(result: $0) }
    }

    private func exportBackup() {
        do {
            let data = try BackupService.shared.exportBackup(providers: state.providers, conversations: state.conversations,
                memory: state.memory, characters: state.characters,
                selectedProviderId: state.settings.defaultProviderId, selectedModelId: state.settings.defaultModelId,
                skills: state.skills, preserving: state.backupPreservation,
                mcpServers: state.mcpServers, settings: state.settings)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PilotAI-backup-\(Int(Date().timeIntervalSince1970)).eta-backup.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection]); exportItem = ExportItem(url: url)
            statusMessage = "Backup exported successfully."
        } catch { statusMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func importBackup(result: Result<[URL], Error>) {
        isImporting = true; defer { isImporting = false }
        do {
            guard let url = try result.get().first else { return }
            let secure = url.startAccessingSecurityScopedResource(); defer { if secure { url.stopAccessingSecurityScopedResource() } }
            let payload = try BackupService.shared.importBackup(from: url)
            let result = state.applyBackup(payload)
            if let error = StorageService.shared.lastError { statusMessage = "Import changed in-memory data, but persistence failed: \(error.localizedDescription)" }
            else {
                statusMessage = "Import successful: +\(result.conversationsAdded) conversations, +\(result.providersAdded) providers, +\(result.charactersAdded) characters, +\(result.skillsAdded) skills."
                if !payload.importWarnings.isEmpty { statusMessage! += "\n\n" + payload.importWarnings.joined(separator: "\n") }
            }
        } catch { statusMessage = "Import failed: \(error.localizedDescription)" }
    }

}

private extension String {
    var estimatedTokenCount: Int { max(0, split(whereSeparator: { $0.isWhitespace }).count == 0 ? count / 4 : count / 4) }
}

struct ExportItem: Identifiable { let id = UUID(); let url: URL }
struct BackupShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
