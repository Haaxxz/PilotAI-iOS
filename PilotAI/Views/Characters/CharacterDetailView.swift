import SwiftUI

@MainActor
struct CharacterDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let character: Character
    @State private var greetingIndex = 0
    @State private var showEditor = false

    private var current: Character { state.characters.first { $0.id == character.id } ?? character }
    private var greetings: [String] { [current.greeting] + current.alternateGreetings }
    private var greeting: String { greetings.indices.contains(greetingIndex) ? greetings[greetingIndex] : current.greeting }

    var body: some View {
        NavigationView {
            Form {
                Section("Profile") {
                    Label(current.name, systemImage: "person.crop.circle")
                    Text(current.description)
                    if !current.persona.isEmpty { Text(current.persona).foregroundColor(.secondary) }
                    if !current.tags.isEmpty { Text(current.tags.joined(separator: ", ")).font(.caption).foregroundColor(.secondary) }
                }
                Section("Opening Greeting") {
                    if greetings.count > 1 {
                        Picker("Variant", selection: $greetingIndex) {
                            ForEach(Array(greetings.enumerated()), id: \.offset) { index, _ in
                                Text(index == 0 ? "Default" : "Alternate \(index)").tag(index)
                            }
                        }
                    }
                    Text(greeting.isEmpty ? "None" : RoleplayContext.expandMacros(greeting, character: current))
                    Button {
                        state.newConversation(mode: .roleplay, characterId: current.id,
                                              greeting: RoleplayContext.expandMacros(greeting, character: current))
                        dismiss()
                    } label: { Label("Start Chat with This Greeting", systemImage: "bubble.left.and.bubble.right.fill") }
                }
                Section("Character Background") {
                    if !current.scenario.isEmpty { DisclosureGroup("Scenario") { Text(current.scenario) } }
                    if !current.exampleMessages.isEmpty { DisclosureGroup("Example Dialogue") { Text(current.exampleMessages) } }
                    if !current.systemPrompt.isEmpty { DisclosureGroup("Character Instructions") { Text(current.systemPrompt) } }
                    if !current.postHistoryInstructions.isEmpty { DisclosureGroup("Post-history Instructions") { Text(current.postHistoryInstructions) } }
                    DisclosureGroup("Worldbook JSON") {
                        Text((try? CharacterCardParser.worldbookText(for: current)).flatMap { $0.isEmpty ? nil : $0 } ?? "No embedded worldbook")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Section(header: Text("Your Persona"), footer: Text("Used only with this character; excluded from card exports.")) {
                    Text(current.userPersonaName.isEmpty ? "User" : current.userPersonaName)
                    if !current.userPersonaDescription.isEmpty { Text(current.userPersonaDescription) }
                }
                Section(header: Text("Story Memory"), footer: Text("Shared by this character's chats. Editing or regenerating chat text does not roll it back. Excluded from card exports.")) {
                    Text(current.storyMemory.isEmpty ? "No story memory yet" : current.storyMemory).textSelection(.enabled)
                    Button("Edit Persona & Story Memory") { showEditor = true }
                }
                Section {
                    DisclosureGroup("Compatibility Notes") {
                        ForEach(Array(RoleplayContext.compatibilityNotes(for: current).enumerated()), id: \.offset) { _, note in
                            Text(note).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
                if !current.creatorNotes.isEmpty {
                    Section("Creator Notes") { Text(current.creatorNotes).font(.footnote) }
                }
            }
            .navigationTitle(current.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Edit") { showEditor = true } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showEditor) {
                CharacterEditorView(character: current) { state.updateCharacter($0) }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
