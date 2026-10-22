import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct WorkspaceView: View {
    private let path: String
    private let service = WorkspaceService.shared
    @State private var entries: [WorkspaceService.Entry] = []
    @State private var listingNote: String?
    @State private var errorMessage: String?
    @State private var action: FileAction = .newFile
    @State private var proposedName = ""
    @State private var showAction = false
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var editor: EditorItem?
    @State private var exportDocument: WorkspaceExportDocument?
    @State private var exportType: UTType = .data
    @State private var exportName = "file"
    @State private var showExporter = false

    public init(path: String = "") { self.path = path }

    public var body: some View {
        List {
            Section {
                Text(path.isEmpty ? "Private Workspace" : path)
                    .font(.subheadline.monospaced()).textSelection(.enabled)
                Text("Files created or imported here can be used by the agent when file access is enabled. Files are limited to 2 MiB; the text editor supports UTF-8 up to 64000 bytes.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            }
            if isImporting { Section { ProgressView("Importing file…") } }
            Section {
                if entries.isEmpty {
                    Text("This folder is empty.").foregroundColor(.secondary)
                }
                ForEach(entries) { entry in
                    Group {
                        if entry.isDirectory {
                            NavigationLink { WorkspaceView(path: entry.path) } label: { row(entry) }
                        } else {
                            Button { openEditor(entry) } label: { row(entry) }.tint(.primary)
                        }
                    }
                    .contextMenu {
                        if !entry.isDirectory {
                            Button { export(entry) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        }
                        Button { propose(.rename(entry), name: entry.name) } label: { Label("Rename…", systemImage: "pencil") }
                        Button(role: .destructive) { propose(.delete(entry)) } label: { Label("Delete…", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { propose(.delete(entry)) } label: { Label("Delete", systemImage: "trash") }
                        Button { propose(.rename(entry), name: entry.name) } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                    }
                    .accessibilityAction(named: "Rename") { propose(.rename(entry), name: entry.name) }
                    .accessibilityAction(named: "Delete") { propose(.delete(entry)) }
                }
            } header: { Text("Files & Folders") } footer: {
                if let listingNote { Text(listingNote) }
            }
        }
        .navigationTitle(path.isEmpty ? "Workspace" : (path.split(separator: "/").last.map(String.init) ?? "Workspace"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { propose(.newFile, name: "Untitled.txt") } label: { Label("New Text File…", systemImage: "doc.badge.plus") }
                    Button { propose(.newFolder, name: "New Folder") } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
                    Button { showImporter = true } label: { Label("Import File…", systemImage: "square.and.arrow.down") }.disabled(isImporting)
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "plus.circle") }
                .accessibilityLabel("Workspace actions")
            }
        }
        .onAppear(perform: refresh)
        .refreshable { refresh() }
        .alert(action.title, isPresented: $showAction) {
            if !action.isDelete { TextField("Name", text: $proposedName).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Button(action.confirmTitle, role: action.isDelete ? .destructive : nil, action: performAction)
            Button("Cancel", role: .cancel) {}
        } message: { Text(action.message) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { propose(.importFile(url), name: url.lastPathComponent) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
        .sheet(item: $editor, onDismiss: refresh) { item in
            WorkspaceTextEditor(path: item.path, initialText: item.text, revision: item.revision)
        }
    }

    private func row(_ entry: WorkspaceService.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text").foregroundColor(entry.isDirectory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(2)
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file)).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !entry.isDirectory {
                Button { export(entry) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).accessibilityLabel("Export \(entry.name)")
            }
        }
    }

    private func refresh() {
        do {
            let result = try service.list(path: path)
            entries = result.entries
            var notes: [String] = []
            if result.truncated { notes.append("This listing is bounded to 100 items. Use smaller subfolders to keep all files visible.") }
            if result.skippedUnsafeEntries > 0 { notes.append("\(result.skippedUnsafeEntries) unsupported or reserved entries were omitted.") }
            listingNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch { errorMessage = error.localizedDescription }
    }

    private func propose(_ next: FileAction, name: String = "") {
        action = next; proposedName = name; showAction = true
    }

    private func childPath(_ name: String) throws -> String {
        // UI operations create direct children. Moving between folders is available to tools
        // using the same path validation and revision checks.
        guard !name.contains("/"), !name.isEmpty else { throw WorkspaceService.WorkspaceError.invalidPath }
        return path.isEmpty ? name : path + "/" + name
    }

    private func performAction() {
        do {
            switch action {
            case .newFile:
                let target = try childPath(proposedName)
                let created = try service.writeText(path: target, text: "", expectedRevision: WorkspaceService.missingRevision)
                editor = EditorItem(path: target, text: "", revision: created.revision)
            case .newFolder: try service.createDirectory(path: childPath(proposedName))
            case .rename(let entry): try service.rename(path: entry.path, to: childPath(proposedName), expectedRevision: entry.revision)
            case .delete(let entry): try service.delete(path: entry.path, expectedRevision: entry.revision)
            case .importFile(let source):
                let target = try childPath(proposedName)
                isImporting = true
                Task {
                    do {
                        // A file provider may need to download/co-ordinate the selected item.
                        // Keep that work off the main actor and never overwrite a destination.
                        _ = try await Task.detached(priority: .userInitiated) {
                            try WorkspaceService.shared.importFile(from: source, to: target)
                        }.value
                        errorMessage = nil
                        refresh()
                    } catch { errorMessage = error.localizedDescription }
                    isImporting = false
                }
                return
            }
            errorMessage = nil
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func openEditor(_ entry: WorkspaceService.Entry) {
        do {
            let snapshot = try service.readText(path: entry.path)
            editor = EditorItem(path: entry.path, text: snapshot.text, revision: snapshot.revision)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func export(_ entry: WorkspaceService.Entry) {
        do {
            let snapshot = try service.read(path: entry.path)
            exportDocument = WorkspaceExportDocument(data: snapshot.data)
            exportType = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            exportName = entry.name
            showExporter = true
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private struct EditorItem: Identifiable {
        let id = UUID()
        let path: String
        let text: String
        let revision: String
    }

    private enum FileAction {
        case newFile, newFolder, rename(WorkspaceService.Entry), delete(WorkspaceService.Entry), importFile(URL)
        var isDelete: Bool { if case .delete = self { return true }; return false }
        var title: String {
            switch self {
            case .newFile: return "Create Text File?"
            case .newFolder: return "Create Folder?"
            case .rename: return "Rename Item?"
            case .delete: return "Delete Item?"
            case .importFile: return "Import File?"
            }
        }
        var confirmTitle: String {
            switch self {
            case .newFile, .newFolder: return "Create"
            case .rename: return "Rename"
            case .delete: return "Delete"
            case .importFile: return "Import"
            }
        }
        var message: String {
            switch self {
            case .newFile, .newFolder: return "Create this item in the current private workspace folder."
            case .rename(let item): return "Rename “\(item.name)”. An existing destination will not be replaced."
            case .delete(let item): return "Permanently delete “\(item.name)”? Folders must be empty."
            case .importFile(let url): return "Copy “\(url.lastPathComponent)” into the agent workspace. Existing files will not be replaced."
            }
        }
    }
}

@MainActor
private struct WorkspaceTextEditor: View {
    @Environment(\.dismiss) private var dismiss
    let path: String
    let initialText: String
    let revision: String
    @State private var text: String
    @State private var errorMessage: String?
    @State private var confirmSave = false
    @State private var confirmDiscard = false

    init(path: String, initialText: String, revision: String) {
        self.path = path; self.initialText = initialText; self.revision = revision
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(path).font(.caption.monospaced()).foregroundColor(.secondary).padding(.horizontal)
                if let errorMessage { Text(errorMessage).font(.caption).foregroundColor(.red).padding(.horizontal) }
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                Text("\(text.utf8.count) / \(WorkspaceService.maxTextBytes) UTF-8 bytes")
                    .font(.caption).foregroundColor(text.utf8.count > WorkspaceService.maxTextBytes ? .red : .secondary).padding(.horizontal)
            }
            .navigationTitle("Edit Text").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if text == initialText { dismiss() } else { confirmDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { confirmSave = true }.disabled(text == initialText || text.utf8.count > WorkspaceService.maxTextBytes)
                }
            }
            .alert("Save Changes?", isPresented: $confirmSave) {
                Button("Save") {
                    do {
                        try WorkspaceService.shared.writeText(path: path, text: text, expectedRevision: revision)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Replace the workspace file only if it has not changed since this editor opened.") }
            .confirmationDialog("Discard Unsaved Changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(text != initialText)
    }
}

private struct WorkspaceExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= WorkspaceService.maxFileBytes else {
            throw WorkspaceService.WorkspaceError.tooLarge
        }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
