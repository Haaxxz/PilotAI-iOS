import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct CharacterCardDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .png] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct CharacterShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
public struct CharacterListView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedCharacter: Character?
    @State private var showEditor = false
    @State private var editingCharacter: Character?
    @State private var pendingDeletion: Character?
    @State private var showDeleteConfirmation = false
    @State private var showFileImporter = false
    @State private var searchText = ""
    @State private var exportDocument = CharacterCardDocument()
    @State private var exportFilename = "character"
    @State private var exportType: UTType = .json
    @State private var showExporter = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var shareURL: URL?
    @State private var errorTitle = "Character Error"
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var isImporting = false

    public init() {}

    public var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if isImporting { ProgressView("Importing character…") }
                    if filteredCharacters.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.3").font(.system(size: 30)).foregroundColor(.secondary)
                            Text(searchText.isEmpty ? "No characters yet" : "No matching characters").font(.headline)
                            Text(searchText.isEmpty ? "Import a character card or create one with +." : "Try a different name, tag, or description.")
                                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                            if state.characters.isEmpty, let builtin = Character.defaults.first {
                                Button("Restore \(builtin.name)") { state.addCharacter(builtin) }
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 48)
                    } else {
                        ForEach(filteredCharacters) { character in characterCard(character) }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Characters")
            .searchable(text: $searchText, prompt: "Search characters")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button { showFileImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                            .accessibilityLabel("Import character card").disabled(isImporting)
                        Button { editingCharacter = nil; showEditor = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Create character")
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.png, .json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { importCharacter(url) }
                case .failure(let error): report(error, title: "Import Failed")
                }
            }
            .sheet(item: $selectedCharacter) { CharacterDetailView(character: $0) }
            .sheet(isPresented: $showEditor) {
                CharacterEditorView(character: editingCharacter) { character in
                    if state.characters.contains(where: { $0.id == character.id }) { state.updateCharacter(character) }
                    else { state.addCharacter(character) }
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: exportType, defaultFilename: exportFilename) { result in
                if case .failure(let error) = result { report(error, title: "Export Failed") }
            }
            .sheet(isPresented: $showShareSheet, onDismiss: {
                if let url = shareURL { try? FileManager.default.removeItem(at: url) }
                shareURL = nil; shareItems = []
            }) { CharacterShareSheet(items: shareItems) }
            .alert(errorTitle, isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage) }
            .confirmationDialog("Delete \(pendingDeletion?.name ?? "character")?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Character", role: .destructive) {
                    if let character = pendingDeletion { state.deleteCharacter(id: character.id) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This removes the character, its original card image and local story memory. Existing conversations remain. This cannot be undone.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var filteredCharacters: [Character] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return state.characters }
        return state.characters.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
                || $0.persona.localizedCaseInsensitiveContains(query) || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func importCharacter(_ url: URL) {
        isImporting = true
        // File-provider access and binary parsing may be expensive; keep the main thread responsive.
        DispatchQueue.global(qos: .userInitiated).async {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try CharacterCardParser.importCharacter(from: url) }
            DispatchQueue.main.async {
                isImporting = false
                switch result {
                case .success(let character): state.addCharacter(character)
                case .failure(let error): report(error, title: "Import Failed")
                }
            }
        }
    }

    private func exportCharacter(_ character: Character, png: Bool, share: Bool = false) {
        do {
            let data = try png ? CharacterCardParser.exportPNG(for: character) : CharacterCardParser.exportJSON(for: character)
            let filename = sanitizedFilename(character.name) + (png ? ".png" : ".json")
            if share {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + filename)
                try data.write(to: url, options: .atomic)
                shareURL = url; shareItems = [url]; showShareSheet = true
            } else {
                exportDocument = CharacterCardDocument(data: data)
                exportType = png ? .png : .json
                exportFilename = filename
                showExporter = true
            }
        } catch { report(error, title: "Export Failed") }
    }

    private func report(_ error: Error, title: String) {
        errorTitle = title; errorMessage = error.localizedDescription; showError = true
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = String(name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return cleaned.isEmpty ? "character" : cleaned
    }

    private func characterCard(_ character: Character) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(character.avatarEmoji).font(.system(size: 32)).frame(width: 50, height: 50)
                    .background(Color(.tertiarySystemBackground)).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(character.name).font(.system(size: 17, weight: .bold))
                    Text(character.description).font(.system(size: 13)).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Menu {
                    Button { editingCharacter = character; showEditor = true } label: { Label("Edit", systemImage: "pencil") }
                    Button {
                        let copy = character.copied()
                        state.addCharacter(copy)
                        editingCharacter = copy; showEditor = true
                    } label: { Label("Copy Character", systemImage: "doc.on.doc") }
                    Menu("Export Card") {
                        Button("JSON") { exportCharacter(character, png: false) }
                        Button("PNG") { exportCharacter(character, png: true) }
                    }
                    Menu("Share Card") {
                        Button("JSON") { exportCharacter(character, png: false, share: true) }
                        Button("PNG") { exportCharacter(character, png: true, share: true) }
                    }
                    Button(role: .destructive) {
                        pendingDeletion = character; showDeleteConfirmation = true
                    } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .accessibilityLabel("Actions for \(character.name)")
            }
            if !character.greeting.isEmpty {
                Text(RoleplayContext.expandMacros(character.greeting, character: character))
                    .font(.system(size: 13, design: .serif)).italic().foregroundColor(.secondary).lineLimit(4)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground)).cornerRadius(8)
            }
            if !character.alternateGreetings.isEmpty {
                Text("\(character.alternateGreetings.count) alternate greeting" + (character.alternateGreetings.count == 1 ? "" : "s"))
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button("Details") { selectedCharacter = character }.font(.subheadline)
                Spacer()
                Button {
                    state.newConversation(mode: .roleplay, characterId: character.id,
                                          greeting: RoleplayContext.expandMacros(character.greeting, character: character))
                } label: { Label("Start Chat", systemImage: "bubble.left.and.bubble.right.fill").font(.subheadline) }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16).background(Color(.secondarySystemBackground)).cornerRadius(16)
    }
}
