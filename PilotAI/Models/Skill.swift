import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Descriptions of package resources, not installed files or executable capabilities.
public struct SkillResource: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case script, reference, asset }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var byteCount: Int?
    public init(path: String, kind: Kind, byteCount: Int? = nil) {
        self.path = path; self.kind = kind; self.byteCount = byteCount
    }
}

public struct Skill: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var promptInstructions: String
    public var isEnabled: Bool
    /// Optional Android SKILL.md metadata. The basic iOS runner uses promptInstructions, but
    /// retaining these fields makes imported skill indexes lossless where possible.
    public var compatibility: String?
    public var metadata: [String: String]
    public var source: String
    public var installed: Bool
    public var hasScripts: Bool
    public var hasReferences: Bool
    public var hasAssets: Bool
    public var resources: [SkillResource]
    public var skillFilePath: String?
    
    public init(id: String = UUID().uuidString, name: String, description: String, promptInstructions: String, isEnabled: Bool = true, compatibility: String? = nil, metadata: [String: String] = [:], source: String = "user", installed: Bool = true, hasScripts: Bool = false, hasReferences: Bool = false, hasAssets: Bool = false, resources: [SkillResource] = [], skillFilePath: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.promptInstructions = promptInstructions
        self.isEnabled = isEnabled
        self.compatibility = compatibility
        self.metadata = metadata
        self.source = source
        self.installed = installed
        self.hasScripts = hasScripts
        self.hasReferences = hasReferences
        self.hasAssets = hasAssets
        self.resources = resources
        self.skillFilePath = skillFilePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, promptInstructions, isEnabled, enabled
        case compatibility, metadata, source, installed, hasScripts, hasReferences, hasAssets
        case bodyMarkdown, skillFilePath, resources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Imported Skill",
            description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
            promptInstructions: try c.decodeIfPresent(String.self, forKey: .promptInstructions) ?? (try c.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? ""),
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? (try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true),
            compatibility: try c.decodeIfPresent(String.self, forKey: .compatibility),
            metadata: try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:],
            source: try c.decodeIfPresent(String.self, forKey: .source) ?? "user",
            installed: try c.decodeIfPresent(Bool.self, forKey: .installed) ?? true,
            hasScripts: try c.decodeIfPresent(Bool.self, forKey: .hasScripts) ?? false,
            hasReferences: try c.decodeIfPresent(Bool.self, forKey: .hasReferences) ?? false,
            hasAssets: try c.decodeIfPresent(Bool.self, forKey: .hasAssets) ?? false,
            resources: try c.decodeIfPresent([SkillResource].self, forKey: .resources) ?? [],
            skillFilePath: try c.decodeIfPresent(String.self, forKey: .skillFilePath)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(promptInstructions, forKey: .promptInstructions)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(compatibility, forKey: .compatibility)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(source, forKey: .source)
        try c.encode(installed, forKey: .installed)
        try c.encode(hasScripts, forKey: .hasScripts)
        try c.encode(hasReferences, forKey: .hasReferences)
        try c.encode(hasAssets, forKey: .hasAssets)
        try c.encode(resources, forKey: .resources)
        try c.encodeIfPresent(skillFilePath, forKey: .skillFilePath)
    }
    
    public static let defaults: [Skill] = [
        Skill(id: "web-search", name: "Web Search", description: "Search the web for up-to-date information", promptInstructions: "Use web search when the user asks about current events, facts, or technical documentation."),
        Skill(id: "code-analysis", name: "Code Analysis", description: "Analyze and explain code structure, bugs, and performance", promptInstructions: "Provide detailed breakdown of code syntax, potential bugs, and optimization suggestions."),
        Skill(id: "summarization", name: "Content Summarizer", description: "Summarize long texts, articles, or transcripts", promptInstructions: "Condense long content into concise key points and executive summaries.")
    ]
}

public enum SkillDocumentParser {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumSkills = 100
    public enum ImportError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? { switch self { case .invalid(let message): return message } }
    }
    private static func invalid(_ message: String) -> ImportError { .invalid(message) }

    public static func parse(data: Data, filename: String = "SKILL.md") throws -> [Skill] {
        guard data.count <= maximumBytes else { throw invalid("Skill document exceeds 2 MiB") }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw invalid("Skill documents must be UTF-8 text") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !filename.lowercased().hasSuffix(".zip") else { throw invalid("ZIP packages are not supported. Import SKILL.md or JSON instead.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let skills: [Skill]
        if filename.lowercased().hasSuffix(".json") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            let rows: [[String: Any]]
            if let list = object as? [[String: Any]] { rows = list }
            else if let root = object as? [String: Any], let list = root["skills"] as? [[String: Any]] { rows = list }
            else if let row = object as? [String: Any] { rows = [row] }
            else { throw invalid("Expected a skill object or array of skills") }
            guard !rows.isEmpty, rows.count <= maximumSkills else { throw invalid("Import between 1 and 100 skills at once") }
            skills = try rows.map { row in
                guard row["name"] is String, row["promptInstructions"] is String || row["bodyMarkdown"] is String else { throw invalid("JSON skills require name and promptInstructions (or bodyMarkdown)") }
                return try JSONDecoder().decode(Skill.self, from: JSONSerialization.data(withJSONObject: row))
            }
        } else { skills = [try markdown(text)] }
        guard Set(skills.map(\.id)).count == skills.count else { throw invalid("Duplicate skill IDs in the import") }
        try skills.forEach(validate)
        return skills
    }

    public static func validate(_ skill: Skill) throws {
        guard !skill.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, skill.id.utf8.count <= 256,
              !skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, skill.name.count <= 128,
              !skill.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !skill.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid("Skill needs an ID and a name of 1–128 characters without control characters") }
        guard skill.description.utf8.count <= 16 * 1024, (skill.compatibility?.utf8.count ?? 0) <= 4096 else { throw invalid("Skill description or compatibility text is too long") }
        guard !skill.promptInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !skill.promptInstructions.contains("\0"), skill.promptInstructions.utf8.count <= 1024 * 1024 else { throw invalid("Skill instructions must contain text and fit within 1 MiB") }
        guard skill.metadata.count <= 128, skill.metadata.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16 * 1024 }) else { throw invalid("Skill metadata exceeds its limits") }
        guard skill.resources.count <= 256, Set(skill.resources.map(\.path)).count == skill.resources.count else { throw invalid("Duplicate or excessive resource metadata") }
        for resource in skill.resources {
            let parts = resource.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !resource.path.isEmpty, resource.path.utf8.count <= 1024, !resource.path.hasPrefix("/"),
                  !resource.path.contains("\\"), !resource.path.contains(":"), !resource.path.contains("%"),
                  !resource.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), (resource.byteCount ?? 0) >= 0 else { throw invalid("Resource paths must be safe relative paths") }
        }
    }

    public static func exportJSON(_ skills: [Skill]) throws -> Data {
        guard skills.count <= maximumSkills else { throw invalid("Export at most 100 skills per document") }
        try skills.forEach(validate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(skills)
        guard data.count <= maximumBytes else { throw invalid("Skill export exceeds 2 MiB") }
        return data
    }

    public static func exportMarkdown(_ skill: Skill) throws -> Data {
        try validate(skill)
        func quote(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        var header = ["---", "id: \(try quote(skill.id))", "name: \(try quote(skill.name))", "description: \(try quote(skill.description))",
                      "enabled: \(skill.isEnabled)", "source: \(try quote(skill.source))", "installed: \(skill.installed)",
                      "has-scripts: \(skill.hasScripts)", "has-references: \(skill.hasReferences)", "has-assets: \(skill.hasAssets)"]
        if let compatibility = skill.compatibility { header.append("compatibility: \(try quote(compatibility))") }
        if let path = skill.skillFilePath { header.append("skill-file-path: \(try quote(path))") }
        if !skill.resources.isEmpty {
            let resources = String(decoding: try JSONEncoder().encode(skill.resources), as: UTF8.self)
            header.append("resources-json: \(try quote(resources))")
        }
        if !skill.metadata.isEmpty {
            header.append("metadata:")
            for key in skill.metadata.keys.sorted() { header.append("  \(try quote(key)): \(try quote(skill.metadata[key]!))") }
        }
        header.append("---")
        let data = Data((header.joined(separator: "\n") + "\n" + skill.promptInstructions).utf8)
        guard data.count <= maximumBytes, header.joined(separator: "\n").utf8.count <= 32 * 1024 else { throw invalid("Markdown front matter exceeds 32 KiB; export JSON instead") }
        return data
    }

    /// Deliberately a bounded YAML subset: scalar strings, |/> block scalars, and a scalar
    /// metadata map. Unsupported structures fail rather than silently altering instructions.
    private static func markdown(_ text: String) throws -> Skill {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw invalid("SKILL.md requires a closed --- front-matter block with a name") }
        guard end <= 512, lines[1..<end].joined(separator: "\n").utf8.count <= 32 * 1024 else { throw invalid("Skill front matter exceeds its limits") }
        var fields: [String: String] = [:]; var metadata: [String: String] = [:]
        var index = 1; var inMetadata = false; var hasMetadata = false
        while index < end {
            let line = lines[index]; index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            guard !line.contains("\t") else { throw invalid("Use spaces in front matter") }
            let indented = line.hasPrefix(" ")
            guard !indented || inMetadata else { throw invalid("Unsupported nested front matter") }
            let (key, raw) = try pair(line.trimmingCharacters(in: .whitespaces))
            if !indented { inMetadata = false }
            if key == "metadata", !indented {
                guard raw.isEmpty, !hasMetadata else { throw invalid("metadata must be one scalar map") }
                hasMetadata = true; inMetadata = true; continue
            }
            var value: String
            if ["|", "|-", "|+", ">", ">-", ">+"].contains(raw) {
                let parentIndent = line.prefix(while: { $0 == " " }).count
                var block: [String] = []
                var minimumIndent: Int?
                while index < end {
                    let next = lines[index]
                    let indent = next.prefix(while: { $0 == " " }).count
                    if !next.isEmpty && indent <= parentIndent { break }
                    if !next.isEmpty { minimumIndent = min(minimumIndent ?? indent, indent) }
                    block.append(next); index += 1
                }
                let unindented = block.map { String($0.dropFirst(min($0.count, minimumIndent ?? 0))) }
                if raw.hasPrefix(">") {
                    value = ""
                    for (i, text) in unindented.enumerated() {
                        if i > 0 { value += text.isEmpty || unindented[i - 1].isEmpty ? "\n" : " " }
                        value += text
                    }
                } else { value = unindented.joined(separator: "\n") }
                if raw.hasSuffix("-") { value = value.trimmingCharacters(in: .newlines) }
                else if !raw.hasSuffix("+") { value = value.trimmingCharacters(in: .newlines) + "\n" }
            } else { value = try scalar(raw) }
            if indented {
                guard metadata[key] == nil else { throw invalid("Duplicate metadata key: \(key)") }; metadata[key] = value
            } else {
                guard fields[key] == nil else { throw invalid("Duplicate front-matter key: \(key)") }; fields[key] = value
            }
        }
        guard let name = fields["name"], !name.isEmpty else { throw invalid("SKILL.md is missing name") }
        func bool(_ key: String, fallback: Bool) throws -> Bool {
            guard let value = fields[key] else { return fallback }
            guard value == "true" || value == "false" else { throw invalid("\(key) must be true or false") }; return value == "true"
        }
        let known = Set(["id", "name", "description", "compatibility", "enabled", "source", "installed", "has-scripts", "has-references", "has-assets", "resources-json", "skill-file-path"])
        for (key, value) in fields where !known.contains(key) { metadata["frontmatter.\(key)"] = value }
        let resources = try fields["resources-json"].map { try JSONDecoder().decode([SkillResource].self, from: Data($0.utf8)) } ?? []
        return Skill(id: fields["id"] ?? UUID().uuidString, name: name, description: fields["description"] ?? "",
            promptInstructions: lines[(end + 1)...].joined(separator: "\n"), isEnabled: try bool("enabled", fallback: true),
            compatibility: fields["compatibility"], metadata: metadata, source: fields["source"] ?? "imported",
            installed: try bool("installed", fallback: true), hasScripts: try bool("has-scripts", fallback: resources.contains { $0.kind == .script }),
            hasReferences: try bool("has-references", fallback: resources.contains { $0.kind == .reference }),
            hasAssets: try bool("has-assets", fallback: resources.contains { $0.kind == .asset }), resources: resources, skillFilePath: fields["skill-file-path"])
    }

    private static func pair(_ line: String) throws -> (String, String) {
        var quoted: Swift.Character?; var escaped = false
        for i in line.indices {
            let c = line[i]
            if escaped { escaped = false; continue }
            if c == "\\", quoted == "\"" { escaped = true; continue }
            if c == "\"" || c == "'" { if quoted == c { quoted = nil } else if quoted == nil { quoted = c }; continue }
            if c == ":", quoted == nil {
                let key = try scalar(String(line[..<i]).trimmingCharacters(in: .whitespaces))
                guard !key.isEmpty else { throw invalid("Empty front-matter key") }
                return (key, String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        throw invalid("Expected key: value in front matter")
    }
    private static func scalar(_ raw: String) throws -> String {
        if raw.hasPrefix("\"") {
            guard let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { throw invalid("Invalid quoted front-matter string") }; return value
        }
        if raw.hasPrefix("'") {
            guard raw.count >= 2, raw.hasSuffix("'") else { throw invalid("Unclosed front-matter quote") }
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard !["&", "*", "!", "[", "{", "|", ">"].contains(where: raw.hasPrefix) else { throw invalid("Unsupported YAML structure; use scalar metadata or JSON") }
        return (raw.components(separatedBy: " #").first ?? raw).trimmingCharacters(in: .whitespaces)
    }

    public static func githubRawURL(for input: URL) throws -> URL {
        guard let c = URLComponents(url: input, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              ["github.com", "raw.githubusercontent.com"].contains(c.host?.lowercased() ?? "") else { throw invalid("Use an HTTPS GitHub file URL without credentials, query, or fragment") }
        var parts = c.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { throw invalid("Invalid GitHub path") }; parts.removeFirst()
        guard parts.count >= 4, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("%") }),
              ["md", "json"].contains(input.pathExtension.lowercased()) else { throw invalid("Select a .md or .json file, not a repository or ZIP") }
        if c.host?.lowercased() == "github.com" {
            guard parts.count >= 5, parts[2] == "blob" else { throw invalid("Use a GitHub /owner/repository/blob/ref/path file URL") }
            parts.remove(at: 2)
        }
        var result = URLComponents(); result.scheme = "https"; result.host = "raw.githubusercontent.com"; result.path = "/" + parts.joined(separator: "/")
        guard let url = result.url else { throw invalid("Invalid GitHub file URL") }; return url
    }

    public static func importGitHubFile(from input: URL) async throws -> [Skill] {
        let url = try githubRawURL(for: input)
        let loader = SkillFileDownload()
        let data = try await loader.download(url)
        return try parse(data: data, filename: url.lastPathComponent).map { skill in
            var skill = skill; skill.source = "github"; skill.metadata["sourceURL"] = url.absoluteString; return skill
        }
    }
}

/// Download one text document with an allocation bound. Redirects, cookies, cached credentials,
/// archives, package traversal, and execution of package scripts are not part of this importer.
private final class SkillFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var continuation: CheckedContinuation<Data, Error>?
    private var data = Data()
    private var cancelled = false
    func download(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session; lock.unlock()
                session.dataTask(with: url).resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); cancelled = true
        let completion = continuation; continuation = nil
        let session = session; self.session = nil; lock.unlock()
        session?.invalidateAndCancel(); completion?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(SkillDocumentParser.ImportError.invalid("GitHub redirects are not followed; provide the direct file URL")))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == "raw.githubusercontent.com", response.expectedContentLength <= Int64(SkillDocumentParser.maximumBytes) else {
            completionHandler(.cancel); finish(.failure(SkillDocumentParser.ImportError.invalid("GitHub did not return a file within the 2 MiB limit"))); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.lock()
        guard data.count + bytes.count <= SkillDocumentParser.maximumBytes else {
            lock.unlock(); finish(.failure(SkillDocumentParser.ImportError.invalid("Skill download exceeds 2 MiB"))); return
        }
        data.append(bytes); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else { lock.lock(); let result = data; lock.unlock(); finish(.success(result)) }
    }
}
