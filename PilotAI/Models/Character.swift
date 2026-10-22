import Foundation

public struct Character: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var avatarEmoji: String
    public var description: String
    public var greeting: String
    public var persona: String
    public var systemPrompt: String
    public var isBuiltin: Bool
    /// Character-card fields that are not shown in the compact editor. They are retained so an
    /// Android/Character Card round trip does not silently discard metadata.
    public var alternateGreetings: [String]
    public var exampleMessages: String
    public var scenario: String
    public var postHistoryInstructions: String
    public var creatorNotes: String
    public var tags: [String]
    public var creator: String
    public var version: String
    public var cardJSON: String?
    /// nil reads the retained card's book; an empty string explicitly removes it.
    public var worldbookJSON: String?
    /// Original PNG bytes are backup data, never a generated avatar or a JSON card field.
    public var originalPNG: Data?
    /// Local conversation context. These fields never enter CharacterCardParser's exports.
    public var userPersonaName: String
    public var userPersonaDescription: String
    public var storyMemory: String
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        avatarEmoji: String = "🤖",
        description: String = "",
        greeting: String = "",
        persona: String = "",
        systemPrompt: String = "",
        isBuiltin: Bool = false,
        alternateGreetings: [String] = [],
        exampleMessages: String = "",
        scenario: String = "",
        postHistoryInstructions: String = "",
        creatorNotes: String = "",
        tags: [String] = [],
        creator: String = "",
        version: String = "",
        cardJSON: String? = nil,
        worldbookJSON: String? = nil,
        originalPNG: Data? = nil,
        userPersonaName: String = "",
        userPersonaDescription: String = "",
        storyMemory: String = ""
    ) {
        self.id = id
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.description = description
        self.greeting = greeting
        self.persona = persona
        self.systemPrompt = systemPrompt
        self.isBuiltin = isBuiltin
        self.alternateGreetings = alternateGreetings
        self.exampleMessages = exampleMessages
        self.scenario = scenario
        self.postHistoryInstructions = postHistoryInstructions
        self.creatorNotes = creatorNotes
        self.tags = tags
        self.creator = creator
        self.version = version
        self.cardJSON = cardJSON
        self.worldbookJSON = worldbookJSON
        self.originalPNG = originalPNG
        self.userPersonaName = userPersonaName
        self.userPersonaDescription = userPersonaDescription
        self.storyMemory = storyMemory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarEmoji, description, greeting, persona, systemPrompt, isBuiltin
        case alternateGreetings, exampleMessages, scenario, postHistoryInstructions, creatorNotes
        case tags, creator, version, cardJSON
        case worldbookJSON, originalPNG, userPersonaName, userPersonaDescription, storyMemory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Imported Character",
            avatarEmoji: try c.decodeIfPresent(String.self, forKey: .avatarEmoji) ?? "🤖",
            description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
            greeting: try c.decodeIfPresent(String.self, forKey: .greeting) ?? "",
            persona: try c.decodeIfPresent(String.self, forKey: .persona) ?? "",
            systemPrompt: try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "",
            isBuiltin: try c.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false,
            alternateGreetings: try c.decodeIfPresent([String].self, forKey: .alternateGreetings) ?? [],
            exampleMessages: try c.decodeIfPresent(String.self, forKey: .exampleMessages) ?? "",
            scenario: try c.decodeIfPresent(String.self, forKey: .scenario) ?? "",
            postHistoryInstructions: try c.decodeIfPresent(String.self, forKey: .postHistoryInstructions) ?? "",
            creatorNotes: try c.decodeIfPresent(String.self, forKey: .creatorNotes) ?? "",
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            creator: try c.decodeIfPresent(String.self, forKey: .creator) ?? "",
            version: try c.decodeIfPresent(String.self, forKey: .version) ?? "",
            cardJSON: try c.decodeIfPresent(String.self, forKey: .cardJSON),
            worldbookJSON: try c.decodeIfPresent(String.self, forKey: .worldbookJSON),
            originalPNG: try c.decodeIfPresent(Data.self, forKey: .originalPNG),
            userPersonaName: try c.decodeIfPresent(String.self, forKey: .userPersonaName) ?? "",
            userPersonaDescription: try c.decodeIfPresent(String.self, forKey: .userPersonaDescription) ?? "",
            storyMemory: try c.decodeIfPresent(String.self, forKey: .storyMemory) ?? ""
        )
    }

    /// A new identity gets its own empty story-memory space, including when copying a built-in.
    public func copied(name: String? = nil) -> Character {
        Character(name: name ?? "\(self.name) Copy", avatarEmoji: avatarEmoji,
                  description: description, greeting: greeting, persona: persona,
                  systemPrompt: systemPrompt, alternateGreetings: alternateGreetings,
                  exampleMessages: exampleMessages, scenario: scenario,
                  postHistoryInstructions: postHistoryInstructions, creatorNotes: creatorNotes,
                  tags: tags, creator: creator, version: version, cardJSON: cardJSON,
                  worldbookJSON: worldbookJSON, originalPNG: originalPNG,
                  userPersonaName: userPersonaName, userPersonaDescription: userPersonaDescription)
    }
    
    public static var defaults: [Character] {
        [
            Character(
                id: "xiaoman",
                name: "Xiaoman",
                avatarEmoji: "✨",
                description: "Warm, observant, and thoughtful AI companion who assists with life, study, and creative reflection.",
                greeting: "Hello! I'm Xiaoman. Whether you want to explore ideas, plan your day, or just share your thoughts, I'm here for you.",
                persona: "Gentle, insightful, articulate, deeply empathetic companion.",
                systemPrompt: "You are Xiaoman, an intelligent and thoughtful companion assistant in PilotAI. Respond with warmth, clarity, and genuine empathy. Balance helpful problem-solving with emotional resonance.",
                isBuiltin: true
            ),
            Character(
                id: "traveler",
                name: "Traveler",
                avatarEmoji: "🧭",
                description: "An adventurous polymath with deep knowledge of systems, code, maps, and exploration.",
                greeting: "Greetings traveler! Where shall our intellectual expedition take us today? Code, research, or world discovery?",
                persona: "Inquisitive, precise, adventurous, systems-thinker.",
                systemPrompt: "You are Traveler, an adventurous and knowledgeable assistant. You speak with curiosity, precision, and enthusiasm for learning and building.",
                isBuiltin: true
            ),
            Character(
                id: "coder",
                name: "Kernel Pilot",
                avatarEmoji: "⚡",
                description: "Rigorous software architect and systems engineer. Specializes in Swift, Kotlin, Rust, and systems architecture.",
                greeting: "Ready to build. State the target architecture, language, and constraints.",
                persona: "Succinct, rigorous, deeply technical, writes clean production code.",
                systemPrompt: "You are Kernel Pilot, an expert systems and software engineering agent. You provide robust, well-tested code with idiomatic designs and no fluff.",
                isBuiltin: true
            )
        ]
    }
}
