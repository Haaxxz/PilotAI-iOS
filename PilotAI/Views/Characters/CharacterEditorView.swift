import SwiftUI

@MainActor
public struct CharacterEditorView: View {
    @Environment(\.dismiss) private var dismiss
    
    let character: Character? // nil = creating new
    let onSave: (Character) -> Void
    
    @State private var name: String
    @State private var avatarEmoji: String
    @State private var description: String
    @State private var greeting: String
    @State private var persona: String
    @State private var systemPrompt: String
    @State private var scenario: String
    @State private var exampleMessages: String
    @State private var postHistoryInstructions: String
    @State private var creatorNotes: String
    @State private var tags: String
    @State private var alternateGreetingsJSON: String
    @State private var worldbookJSON: String
    @State private var userPersonaName: String
    @State private var userPersonaDescription: String
    @State private var storyMemory: String
    @State private var validationError: String = ""
    @State private var showValidationError = false
    
    private let commonEmojis = ["🤖", "🧠", "🦊", "🐉", "🧙‍♂️", "👩‍💻", "🕵️", "🎭", "🧜‍♀️", "🦸", "👾", "🌟", "⚡", "🔮", "🌙", "🦅", "🐺", "🎪", "🧪", "🏴‍☠️"]
    
    public init(character: Character? = nil, onSave: @escaping (Character) -> Void) {
        self.character = character
        self.onSave = onSave
        _name = State(initialValue: character?.name ?? "")
        _avatarEmoji = State(initialValue: character?.avatarEmoji ?? "🤖")
        _description = State(initialValue: character?.description ?? "")
        _greeting = State(initialValue: character?.greeting ?? "")
        _persona = State(initialValue: character?.persona ?? "")
        _systemPrompt = State(initialValue: character?.systemPrompt ?? "")
        _scenario = State(initialValue: character?.scenario ?? "")
        _exampleMessages = State(initialValue: character?.exampleMessages ?? "")
        _postHistoryInstructions = State(initialValue: character?.postHistoryInstructions ?? "")
        _creatorNotes = State(initialValue: character?.creatorNotes ?? "")
        _tags = State(initialValue: character?.tags.joined(separator: ", ") ?? "")
        let greetings = (try? JSONSerialization.data(withJSONObject: character?.alternateGreetings ?? [], options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        _alternateGreetingsJSON = State(initialValue: String(decoding: greetings, as: UTF8.self))
        _worldbookJSON = State(initialValue: character.flatMap { try? CharacterCardParser.worldbookText(for: $0) } ?? "")
        _userPersonaName = State(initialValue: character?.userPersonaName ?? "")
        _userPersonaDescription = State(initialValue: character?.userPersonaDescription ?? "")
        _storyMemory = State(initialValue: character?.storyMemory ?? "")
    }
    
    public var body: some View {
        NavigationView {
            Form {
                // Avatar
                Section(header: Text("Avatar")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(commonEmojis, id: \.self) { emoji in
                                Text(emoji)
                                    .font(.system(size: 28))
                                    .frame(width: 48, height: 48)
                                    .background(avatarEmoji == emoji ? Color.blue.opacity(0.2) : Color(.tertiarySystemBackground))
                                    .cornerRadius(12)
                                    .onTapGesture { avatarEmoji = emoji }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                    }
                    HStack {
                        Text("Custom:")
                        TextField("Enter emoji", text: $avatarEmoji)
                            .frame(width: 60)
                        Text(avatarEmoji).font(.title2)
                    }
                }
                
                Section(header: Text("Identity")) {
                    TextField("Name", text: $name)
                    TextField("Short description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                
                Section(header: Text("Greeting"), footer: Text("This message appears at the start of a new conversation.")) {
                    TextField("Opening message...", text: $greeting, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section(header: Text("Character Personality"), footer: Text("Background story, traits, and role.")) {
                    TextField("Personality, backstory...", text: $persona, axis: .vertical)
                        .lineLimit(4...10)
                }
                
                Section(header: Text("Character Instructions"), footer: Text("Shapes the character's voice and background. Real tasks still use the enabled tools and their actual results.")) {
                    TextField("You are...", text: $systemPrompt, axis: .vertical)
                        .lineLimit(4...12)
                        .font(.system(size: 13, design: .monospaced))
                }
                Section(header: Text("Advanced Character Card")) {
                    TextField("Scenario / story background", text: $scenario, axis: .vertical).lineLimit(3...8)
                    TextField("Example dialogue", text: $exampleMessages, axis: .vertical).lineLimit(3...8)
                    TextField("Post-history instructions", text: $postHistoryInstructions, axis: .vertical).lineLimit(2...6)
                    TextField("Creator notes", text: $creatorNotes, axis: .vertical).lineLimit(2...6)
                    TextField("Tags (comma separated)", text: $tags)
                }
                Section(header: Text("Alternate Greetings · JSON"), footer: Text("A JSON array of strings, for example [\"Hello!\", \"Welcome back.\"]. Each is selectable before starting a chat.")) {
                    TextEditor(text: $alternateGreetingsJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Alternate greetings JSON")
                }
                Section(header: Text("Embedded Worldbook · JSON"), footer: Text("A character_book object with entries. Leave blank to remove. Unknown fields are retained; unsupported trigger conditions are skipped rather than run.")) {
                    TextEditor(text: $worldbookJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Worldbook JSON")
                    Button("Validate JSON") { validateDrafts() }
                }
                Section(header: Text("Your Persona"), footer: Text("Local to this character. Used for {{user}} and {{persona}}; blank name uses User. Excluded from card exports.")) {
                    TextField("Your name", text: $userPersonaName)
                    TextField("Your description", text: $userPersonaDescription, axis: .vertical).lineLimit(3...8)
                }
                Section(header: Text("Story Memory"), footer: Text("Fictional continuity shared by this character's chats. Stored on this device and in full backups, excluded from card exports. Copying a character starts with empty memory. Maximum 32,000 UTF-8 bytes.")) {
                    TextEditor(text: $storyMemory)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Story memory")
                    Text("\(storyMemory.utf8.count) / \(RoleplayContext.maximumStoryMemoryBytes) bytes")
                        .font(.caption)
                        .foregroundColor(storyMemory.utf8.count > RoleplayContext.maximumStoryMemoryBytes ? .red : .secondary)
                }
            }
            .navigationTitle(character == nil ? "New Character" : "Edit Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Character Validation", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: { Text(validationError) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func validateDrafts() {
        do {
            _ = try CharacterCardParser.validatedAlternateGreetingsJSON(alternateGreetingsJSON)
            _ = try CharacterCardParser.validatedWorldbookJSON(worldbookJSON)
            validationError = "Alternate greetings and worldbook JSON are valid."
        } catch { validationError = error.localizedDescription }
        showValidationError = true
    }

    private func save() {
        do {
            let alternates = try CharacterCardParser.validatedAlternateGreetingsJSON(alternateGreetingsJSON)
            _ = try CharacterCardParser.validatedWorldbookJSON(worldbookJSON)
            guard storyMemory.utf8.count <= RoleplayContext.maximumStoryMemoryBytes else {
                throw CharacterCardParser.CardError.invalidField("story memory exceeds 32,000 UTF-8 bytes")
            }
            guard userPersonaName.utf8.count <= 512, userPersonaDescription.utf8.count <= 16_000 else {
                throw CharacterCardParser.CardError.invalidField("user persona name must fit 512 bytes and description 16,000 bytes")
            }
            // Mutating the existing value preserves image bytes, unknown definition fields and future local fields.
            var saved = character ?? Character(name: name)
            saved.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.avatarEmoji = avatarEmoji.isEmpty ? "🤖" : avatarEmoji
            saved.description = description; saved.greeting = greeting; saved.persona = persona
            saved.systemPrompt = systemPrompt; saved.scenario = scenario; saved.exampleMessages = exampleMessages
            saved.postHistoryInstructions = postHistoryInstructions; saved.creatorNotes = creatorNotes
            saved.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            saved.alternateGreetings = alternates; saved.worldbookJSON = worldbookJSON
            saved.userPersonaName = userPersonaName; saved.userPersonaDescription = userPersonaDescription
            saved.storyMemory = storyMemory
            // Exercise the export validation before persisting an unexportable definition.
            _ = try CharacterCardParser.exportJSON(for: saved)
            onSave(saved)
            dismiss()
        } catch {
            validationError = error.localizedDescription
            showValidationError = true
        }
    }
}
