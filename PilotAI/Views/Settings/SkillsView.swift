import SwiftUI
import UniformTypeIdentifiers

public struct SkillsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showImporter = false
    @State private var showGitHubImporter = false
    @State private var gitHubURL = ""
    @State private var isDownloading = false
    @State private var exportItem: ExportItem?
    @State private var editingSkill: Skill? = nil
    @State private var statusMessage: String?
    
    public init() {}
    
    public var body: some View {
        List {
            Section(header: Text("Agent Skills"), footer: Text("Enabled skills add prompt instructions. Resource listings are metadata only; imported scripts are not executed. Import SKILL.md or JSON, up to 2 MiB. ZIP packages are not supported.")) {
                ForEach(state.skills) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(skill.name).font(.headline)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { val in
                                    var updated = skill
                                    updated.isEnabled = val
                                    state.updateSkill(updated)
                                }
                            ))
                            .labelsHidden()
                        }
                        Text(skill.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if !skill.resources.isEmpty || skill.hasScripts || skill.hasReferences || skill.hasAssets {
                            Text("Resource metadata • \(skill.resources.count) listed files")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { editingSkill = skill }
                    .contextMenu {
                        Button("Export SKILL.md") { exportSkill(skill) }
                        Button("Export JSON") { exportSkills([skill]) }
                    }
                }
                .onDelete { idxSet in
                    idxSet.map { state.skills[$0] }.forEach { state.deleteSkill(id: $0.id) }
                }
            }
            
            Section {
                Button(action: {
                    editingSkill = Skill(name: "", description: "", promptInstructions: "")
                }) {
                    Label("Add Custom Skill", systemImage: "plus.circle.fill")
                }
                Button { showGitHubImporter = true } label: {
                    Label(isDownloading ? "Downloading…" : "Import GitHub File", systemImage: "link")
                }.disabled(isDownloading)
            }
        }
        .navigationTitle("Agent Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Import Files") { showImporter = true }
                    Button("Export All as JSON") { exportSkills(state.skills) }.disabled(state.skills.isEmpty)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .json], allowsMultipleSelection: true) { result in
            importSkills(result)
        }
        .alert("Skills", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: { Text(statusMessage ?? "") }
        .alert("Import GitHub File", isPresented: $showGitHubImporter) {
            TextField("https://github.com/owner/repo/blob/ref/SKILL.md", text: $gitHubURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Import") { importGitHub() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Downloads a single public .md or .json file. Referenced resources are not downloaded.") }
        .sheet(item: $exportItem) { BackupShareSheet(items: [$0.url]) }
        .sheet(item: $editingSkill) { skill in
            SkillEditorSheet(skill: skill) { updated in
                if state.skills.contains(where: { $0.id == updated.id }) {
                    state.updateSkill(updated)
                } else {
                    state.addSkill(updated)
                }
                editingSkill = nil
            } onCancel: { editingSkill = nil }
        }
    }

    private func importSkills(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard urls.count <= SkillDocumentParser.maximumSkills else { throw SkillDocumentParser.ImportError.invalid("Select at most 100 files") }
            var parsed: [Skill] = []
            for url in urls {
                let secure = url.startAccessingSecurityScopedResource(); defer { if secure { url.stopAccessingSecurityScopedResource() } }
                let data = try BoundedDataReader.read(url, limit: SkillDocumentParser.maximumBytes)
                parsed += try SkillDocumentParser.parse(data: data, filename: url.lastPathComponent)
                guard parsed.count <= SkillDocumentParser.maximumSkills else { throw SkillDocumentParser.ImportError.invalid("Import at most 100 skills at once") }
            }
            install(parsed)
        } catch { statusMessage = "Import failed: \(error.localizedDescription)" }
    }

    private func install(_ skills: [Skill]) {
        var ids = Set(state.skills.map(\.id)); var added = 0
        for skill in skills where ids.insert(skill.id).inserted { state.addSkill(skill); added += 1 }
        if let error = StorageService.shared.lastError { statusMessage = "Persistence failed: \(error.localizedDescription)" }
        else { statusMessage = "Imported \(added) skill(s); skipped \(skills.count - added) existing IDs." }
    }

    private func importGitHub() {
        guard let url = URL(string: gitHubURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { statusMessage = "Enter a GitHub file URL."; return }
        isDownloading = true
        Task { @MainActor in
            defer { isDownloading = false }
            do { install(try await SkillDocumentParser.importGitHubFile(from: url)) }
            catch { statusMessage = "Import failed: \(error.localizedDescription)" }
        }
    }

    private func exportSkill(_ skill: Skill) {
        do { try share(SkillDocumentParser.exportMarkdown(skill), filename: "\(UUID().uuidString)-SKILL.md") }
        catch { statusMessage = "Export failed: \(error.localizedDescription)" }
    }
    private func exportSkills(_ skills: [Skill]) {
        do { try share(SkillDocumentParser.exportJSON(skills), filename: "\(UUID().uuidString)-skills.json") }
        catch { statusMessage = "Export failed: \(error.localizedDescription)" }
    }
    private func share(_ data: Data, filename: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic, .completeFileProtection]); exportItem = ExportItem(url: url)
    }
}

struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    let onSave: (Skill) -> Void
    let onCancel: () -> Void
    
    @State private var name: String
    @State private var description: String
    @State private var promptInstructions: String
    @State private var isEnabled: Bool
    @State private var validationMessage: String?
    
    init(skill: Skill, onSave: @escaping (Skill) -> Void, onCancel: @escaping () -> Void) {
        self.skill = skill
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: skill.name)
        _description = State(initialValue: skill.description)
        _promptInstructions = State(initialValue: skill.promptInstructions)
        _isEnabled = State(initialValue: skill.isEnabled)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Skill Info")) {
                    TextField("Skill Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                
                Section(header: Text("System Instructions"), footer: Text("Prompt injected into context when this skill is active.")) {
                    TextEditor(text: $promptInstructions)
                        .frame(minHeight: 100)
                        .font(.system(size: 13, design: .monospaced))
                }
                
                Section {
                    Toggle("Enable Skill", isOn: $isEnabled)
                }
                if !skill.resources.isEmpty {
                    Section(header: Text("Resource Metadata"), footer: Text("These files are not installed or executed by this importer.")) {
                        ForEach(skill.resources) { resource in
                            LabeledContent(resource.path, value: resource.kind.rawValue)
                        }
                    }
                }
                if let validationMessage { Text(validationMessage).foregroundColor(.red) }
            }
            .navigationTitle(skill.name.isEmpty ? "New Skill" : "Edit Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var s = skill
                        s.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        s.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
                        s.promptInstructions = promptInstructions
                        s.isEnabled = isEnabled
                        do { try SkillDocumentParser.validate(s); onSave(s) }
                        catch { validationMessage = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
