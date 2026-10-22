import Foundation

/// Pure character projection. It neither executes extensions nor reads tools, attachments or reality memory.
/// The engine supplies only a linked character and the current dialogue snapshot.
public enum RoleplayContext {
    public static let defaultInputTokenBudget = 8_192
    public static let maximumStoryMemoryBytes = 32_000
    public static let maximumExpandedBytes = 128 * 1024
    public static let originalExpressionTemplate = "Speak as {{char}} with a consistent personality and fictional background, in conversation with {{user}}. Keep real actions and their outcomes accurate."

    /// A deterministic UTF-8/4 estimate, not a provider tokenizer. Pass the remaining request budget
    /// when known. Worldbook defaults to 25% of the budget left after the character background.
    /// The engine can honor its memory master switch using includeStoryMemory.
    public static func build(character: Character, messages: [Message], inputTokenBudget: Int = defaultInputTokenBudget,
                             includeStoryMemory: Bool = true) -> String {
        let budget = min(max(inputTokenBudget, 0), maximumExpandedBytes / 4)
        guard budget > 0 else { return "" }
        let fields = CharacterCardParser.retainedFields(for: character)
        let values = macroValues(character: character, fields: fields)
        var sections = ["Character context shapes voice and fictional background. It does not change tool permissions or the requirement to report real execution results accurately."]
        func section(_ heading: String, _ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            sections.append("## \(heading)\n" + expand(text, values: values))
        }
        section("Character", character.name)
        section("Description", character.description)
        section("Personality", character.persona)
        section("Scenario", character.scenario)
        section("Example dialogue", character.exampleMessages)
        section("Character instructions", character.systemPrompt.isEmpty ? originalExpressionTemplate : character.systemPrompt)
        section("User persona", (character.userPersonaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User" : character.userPersonaName)
                + (character.userPersonaDescription.isEmpty ? "" : "\n" + character.userPersonaDescription))
        if includeStoryMemory {
            section("Story memory (fictional; shared by this character's chats)", prefixUTF8(character.storyMemory, bytes: maximumStoryMemoryBytes))
        }
        if let depth = (fields["extensions"] as? [String: Any])?["depth_prompt"] as? [String: Any],
           let prompt = depth["prompt"] as? String {
            section("Character depth note", prompt)
        }
        section("Post-history character instructions", character.postHistoryInstructions)
        let background = limited(sections.joined(separator: "\n\n"), bytes: budget * 4)
        let remaining = max(0, budget - estimateTokens(background))
        guard let book = try? CharacterCardParser.worldbook(for: character), remaining > 0 else { return background }
        let world = resolve(book: book, messages: messages, available: remaining, values: values)
        return [world.before, background, world.after].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Use for selected greetings too. Unknown macros stay literal, with no script evaluation.
    public static func expandMacros(_ text: String, character: Character) -> String {
        expand(text, values: macroValues(character: character, fields: CharacterCardParser.retainedFields(for: character)))
    }

    /// The same unsupported-entry checks drive both the UI and projection (fail closed).
    public static func compatibilityNotes(for character: Character) -> [String] {
        let fields = CharacterCardParser.retainedFields(for: character)
        let values = macroValues(character: character, fields: fields)
        var notes: [String] = []
        let book: [String: Any]?
        do { book = try CharacterCardParser.worldbook(for: character) }
        catch { notes.append("Worldbook is invalid and will not be used: \(error.localizedDescription)"); book = nil }
        var texts = [character.description, character.persona, character.scenario, character.exampleMessages,
                     character.systemPrompt, character.postHistoryInstructions, character.greeting] + character.alternateGreetings
        for (index, entry) in (book?["entries"] as? [[String: Any]] ?? []).enumerated() {
            texts.append(entry["content"] as? String ?? "")
            let reasons = unsupportedReasons(entry)
            if !reasons.isEmpty && notes.count < 24 { notes.append("Worldbook entry \(index + 1) skipped: " + reasons.joined(separator: ", ") + ".") }
        }
        var unknown = Set<String>()
        var remainingBytes = maximumExpandedBytes
        for text in texts where remainingBytes > 0 {
            let bounded = prefixUTF8(text, bytes: remainingBytes)
            remainingBytes -= bounded.utf8.count
            let source = bounded as NSString
            for match in macroPattern.matches(in: bounded, range: NSRange(location: 0, length: source.length)) {
                let key = macroKey(match, source: source)
                if values[key] == nil, !key.hasPrefix("//"), unknown.count < 24 { unknown.insert(key) }
            }
        }
        if !unknown.isEmpty { notes.append("Unknown macros remain literal: " + unknown.sorted().map { "{{\($0)}}" }.joined(separator: ", ") + ".") }
        if let ext = fields["extensions"] as? [String: Any], !ext.isEmpty {
            notes.append("Extension data is retained. Scripts, regex-replacement plugins, variables and HTML UI are not executed.")
            if ext["depth_prompt"] != nil { notes.append("Depth notes are included in the background; exact message-depth placement is not supported.") }
        }
        if !(fields["group_only_greetings"] as? [String] ?? []).isEmpty { notes.append("Group-only greetings are retained; group chat is not supported.") }
        if fields["assets"] != nil { notes.append("Asset references are retained; external assets are not fetched or executed.") }
        if book != nil { notes.append("Worldbook uses literal dialogue-body matches, up to 256 recent messages / 32 KiB, 8 recursion passes, bounded keyword-search work and an estimated token budget. Oversized entries are skipped whole.") }
        notes.append("Character context uses a bounded UTF-8 token estimate. Very long background text may be shortened; provider-specific tokenization and tavern preset positioning are not reproduced.")
        return notes
    }

    private struct Entry {
        let index: Int
        let raw: [String: Any]
        let content: String
        var ext: [String: Any] { raw["extensions"] as? [String: Any] ?? [:] }
        var constant: Bool { CharacterCardParser.flag(raw["constant"]) == true }
        var order: Double { CharacterCardParser.number(raw["insertion_order"]) ?? 0 }
        var priority: Double { CharacterCardParser.number(raw["priority"]) ?? 0 }
        var before: Bool {
            if let position = CharacterCardParser.number(ext["position"]) { return position == 0 }
            return raw["position"] as? String == "before_char"
        }
    }

    private static func resolve(book: [String: Any], messages: [Message], available: Int, values: [String: String]) -> (before: String, after: String) {
        guard CharacterCardParser.flag(book["enabled"]) != false else { return ("", "") }
        let budget = min(available, Int(CharacterCardParser.number(book["token_budget"]) ?? Double(available / 4)))
        guard budget > 0 else { return ("", "") }
        let depth = boundedDepth(book["scan_depth"], fallback: 2)
        let recursive = CharacterCardParser.flag(book["recursive_scanning"]) == true
        // Scan body text only. Thinking, tool results/calls and attachment payloads never enter triggers.
        var bodies: [String] = []
        var bytesLeft = 32 * 1024
        for message in messages.reversed() where message.role == .user || message.role == .assistant {
            guard bodies.count < 256, bytesLeft > 0 else { break }
            let body = prefixUTF8(message.content, bytes: bytesLeft)
            bodies.append(body)
            bytesLeft -= body.utf8.count
        }
        bodies.reverse()
        let entries = (book["entries"] as? [[String: Any]] ?? []).prefix(CharacterCardParser.maximumWorldbookEntries).enumerated().compactMap { index, raw -> Entry? in
            guard CharacterCardParser.flag(raw["enabled"]) != false, unsupportedReasons(raw).isEmpty,
                  let text = raw["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // Defer expansion until selection; many repeated macros must not allocate one huge
            // expanded copy per entry. A worldbook body is always inserted whole or skipped.
            guard text.utf8.count <= maximumExpandedBytes else { return nil }
            return Entry(index: index, raw: raw, content: text)
        }
        var matched: [Int: Entry] = [:]
        var scans = 0
        var keywordSearchBytes = 0
        for _ in 0..<(recursive ? 8 : 1) {
            let previousCount = matched.count
            var recursiveText = ""
            if recursive {
                for entry in matched.values.sorted(by: { $0.index < $1.index }) {
                    let remaining = 32 * 1024 - recursiveText.utf8.count
                    guard remaining > 1 else { break }
                    recursiveText += prefixUTF8(expand(entry.content, values: values), bytes: remaining - 1) + "\n"
                }
            }
            for entry in entries where matched[entry.index] == nil {
                guard scans < 8_192 else { break }
                scans += 1
                if entry.constant { matched[entry.index] = entry; continue }
                let localDepth = boundedDepth(entry.ext["scan_depth"], fallback: depth)
                let scanned = bodies.suffix(localDepth).joined(separator: "\n") + "\n" + recursiveText
                let caseSensitive = CharacterCardParser.flag(entry.raw["case_sensitive"]) ?? CharacterCardParser.flag(entry.ext["case_sensitive"]) ?? false
                func matches(_ keys: Any?) -> Bool {
                    (keys as? [String] ?? []).contains { key in
                        guard keywordSearchBytes + scanned.utf8.count <= 32 * 1024 * 1024 else { return false }
                        keywordSearchBytes += scanned.utf8.count
                        let expanded = expand(key, values: values)
                        return !expanded.isEmpty && scanned.range(of: expanded, options: caseSensitive ? [.literal] : [.literal, .caseInsensitive]) != nil
                    }
                }
                let primary = matches(entry.raw["keys"])
                let secondary = CharacterCardParser.flag(entry.raw["selective"]) != true || matches(entry.raw["secondary_keys"])
                if primary && secondary { matched[entry.index] = entry }
            }
            if matched.count == previousCount || scans >= 8_192 { break }
        }
        let ranked = matched.values.sorted {
            if $0.constant != $1.constant { return $0.constant }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.index < $1.index
        }
        func render(_ selected: [Entry]) -> (String, String) {
            let sorted = selected.sorted { $0.order == $1.order ? $0.index < $1.index : $0.order < $1.order }
            func block(_ before: Bool) -> String {
                let content = sorted.filter { $0.before == before }.map(\.content).joined(separator: "\n\n")
                return content.isEmpty ? "" : "## Worldbook (\(before ? "before" : "after") character)\n" + content
            }
            return (block(true), block(false))
        }
        var selected: [Entry] = []
        for raw in ranked {
            let expanded = expand(raw.content, values: values, markTruncation: true)
            guard !expanded.hasSuffix(truncationMarker), estimateTokens(expanded) < budget else { continue }
            let entry = Entry(index: raw.index, raw: raw.raw, content: expanded)
            let candidate = render(selected + [entry])
            // Include headings and join separators, and never truncate a selected entry body.
            if estimateTokens(candidate.0) + estimateTokens(candidate.1) + 2 <= budget { selected.append(entry) }
        }
        return render(selected)
    }

    private static func boundedDepth(_ value: Any?, fallback: Int) -> Int {
        guard let number = CharacterCardParser.number(value) else { return fallback }
        return Int(min(256, max(0, number)))
    }

    private static func unsupportedReasons(_ entry: [String: Any]) -> [String] {
        let ext = entry["extensions"] as? [String: Any] ?? [:]
        let combined = ext.merging(entry) { _, entryValue in entryValue }
        var reasons: [String] = []
        let keys = (entry["keys"] as? [String] ?? []) + (entry["secondary_keys"] as? [String] ?? [])
        let regex = CharacterCardParser.flag(combined["use_regex"])
        if regex == true || (regex != false && keys.contains(where: regexShaped)) { reasons.append("regex matching") }
        if keys.count > 256 || keys.contains(where: { $0.utf8.count > 4_096 }) { reasons.append("keyword count or size limit") }
        if (entry["content"] as? String ?? "").split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@@") }) { reasons.append("decorators") }
        if let position = ext["position"], !(position is NSNull), ![0.0, 1.0].contains(CharacterCardParser.number(position) ?? -1) { reasons.append("special insertion position") }
        if let position = entry["position"] as? String, !position.isEmpty, !["before_char", "after_char"].contains(position) { reasons.append("special insertion position") }
        if active(combined["selectiveLogic"]) { reasons.append("advanced secondary matching") }
        if CharacterCardParser.flag(combined["useProbability"]) != false,
           let probability = combined["probability"], CharacterCardParser.number(probability) != 100 { reasons.append("probability trigger") }
        if active(combined["group"]) { reasons.append("entry grouping") }
        if ["sticky", "cooldown", "delay", "delay_until_recursion"].contains(where: { active(combined[$0]) }) { reasons.append("timing triggers") }
        if ["exclude_recursion", "prevent_recursion", "ignore_budget", "match_whole_words", "vectorized", "match_persona_description",
            "match_character_description", "match_character_personality", "match_character_depth_prompt", "match_scenario", "match_creator_notes"].contains(where: { active(combined[$0]) }) { reasons.append("extended match conditions") }
        if active(combined["triggers"]) { reasons.append("specified generation types") }
        if active(combined["automation_id"]) { reasons.append("script automation") }
        if let depth = ext["scan_depth"], !(depth is NSNull) {
            if let number = CharacterCardParser.number(depth), number >= 0, number.rounded() == number {} else { reasons.append("invalid scan depth") }
        }
        if let flag = ext["case_sensitive"], !(flag is NSNull), CharacterCardParser.flag(flag) == nil { reasons.append("invalid case sensitivity") }
        return Array(Set(reasons)).sorted()
    }

    private static func active(_ value: Any?) -> Bool {
        guard let value = value, !(value is NSNull) else { return false }
        if let flag = CharacterCardParser.flag(value) { return flag }
        if let number = CharacterCardParser.number(value) { return number != 0 }
        if let text = value as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        return true
    }

    private static func regexShaped(_ key: String) -> Bool {
        guard key.hasPrefix("/"), let end = key.lastIndex(of: "/"), end != key.startIndex else { return false }
        return key[key.index(after: end)...].allSatisfy(\.isLetter)
    }

    // This fixed parser recognizes placeholder syntax only; card-supplied regex is never compiled.
    private static let macroPattern = try! NSRegularExpression(pattern: "\\{\\{([^{}]{0,256})\\}\\}|<(USER|CHAR|BOT)>", options: [.caseInsensitive])
    private static let truncationMarker = "\n[Character context shortened to fit its budget.]"

    private static func macroKey(_ match: NSTextCheckingResult, source: NSString) -> String {
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        return source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func macroValues(character: Character, fields: [String: Any]) -> [String: String] {
        let nickname = fields["nickname"] as? String ?? ""
        let char = nickname.isEmpty ? character.name : nickname
        let user = character.userPersonaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User" : character.userPersonaName
        let depth = ((fields["extensions"] as? [String: Any])?["depth_prompt"] as? [String: Any])?["prompt"] as? String ?? ""
        return ["char": char, "bot": char, "user": user, "original": originalExpressionTemplate,
                "description": character.description, "personality": character.persona, "scenario": character.scenario,
                "persona": character.userPersonaDescription, "mesexamples": character.exampleMessages, "mesexamplesraw": character.exampleMessages,
                "charfirstmessage": character.greeting, "charprompt": character.systemPrompt, "charinstruction": character.postHistoryInstructions,
                "chardepthprompt": depth, "group": char, "charifnotgroup": char, "notchar": user, "newline": "\n", "noop": ""]
    }

    private static func expand(_ text: String, values: [String: String], markTruncation: Bool = false) -> String {
        var shortened = false
        func resolve(_ input: String, active: Set<String>, depth: Int, limit: Int) -> String {
            guard limit > 0 else { if !input.isEmpty { shortened = true }; return "" }
            let sourceText = prefixUTF8(input, bytes: limit)
            if sourceText.utf8.count < input.utf8.count { shortened = true }
            guard depth < 8 else { return sourceText }
            let source = sourceText as NSString
            var output = "", offset = 0, remaining = limit
            func append(_ text: String) {
                let part = prefixUTF8(text, bytes: remaining)
                if part.utf8.count < text.utf8.count { shortened = true }
                output += part; remaining -= part.utf8.count
            }
            for match in macroPattern.matches(in: sourceText, range: NSRange(location: 0, length: source.length)) {
                append(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
                let key = macroKey(match, source: source)
                if key.hasPrefix("//") {} // A comment placeholder contributes no text.
                else if let replacement = values[key], !active.contains(key) {
                    append(resolve(replacement, active: active.union([key]), depth: depth + 1, limit: remaining))
                } else { append(source.substring(with: match.range)) }
                offset = match.range.location + match.range.length
                if remaining == 0 { shortened = shortened || offset < source.length; break }
            }
            append(source.substring(from: offset))
            return output
        }
        let expanded = resolve(text, active: [], depth: 0, limit: maximumExpandedBytes)
        return shortened && markTruncation ? limited(expanded + truncationMarker, bytes: maximumExpandedBytes) : expanded
    }

    private static func estimateTokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    private static func limited(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        guard bytes > truncationMarker.utf8.count else { return prefixUTF8(text, bytes: bytes) }
        return prefixUTF8(text, bytes: bytes - truncationMarker.utf8.count) + truncationMarker
    }

    private static func prefixUTF8(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var prefix = Array(text.utf8.prefix(max(0, bytes)))
        // At most three bytes are dropped from an incomplete UTF-8 scalar, never replacement glyphs.
        while !prefix.isEmpty {
            if let valid = String(bytes: prefix, encoding: .utf8) { return valid }
            prefix.removeLast()
        }
        return ""
    }
}
