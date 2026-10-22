import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Injectable so migration failures can be tested without touching the user's Keychain.
/// Records are immutable snapshots. An unsuccessful file commit must never erase an old key.
public protocol StorageCredentialStore {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
}

public struct KeychainCredentialStore: StorageCredentialStore {
    public let service: String
    public init(service: String = "PilotAI.StorageCredentials") { self.service = service }
    public func read(account: String) throws -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageService.StorageError.credentials("Keychain read failed (\(status))") }
        return data
        #else
        throw StorageService.StorageError.credentials("Security Keychain is unavailable on this platform")
        #endif
    }
    public func write(_ data: Data, account: String) throws {
        #if canImport(Security)
        // Each save uses a fresh account. Never delete/update an old credential to make room.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageService.StorageError.credentials("Keychain write failed (\(status))") }
        #else
        throw StorageService.StorageError.credentials("Security Keychain is unavailable on this platform")
        #endif
    }
}

public final class StorageService {
    public static let shared = StorageService()
    private static let lock = NSRecursiveLock()
    private let fileManager: FileManager
    public let directory: URL
    private let credentials: StorageCredentialStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var failure: StorageError?
    private var blockedFiles = Set<String>()

    /// Sticky until explicitly cleared, so a later successful save cannot hide an earlier failure.
    public var lastError: StorageError? {
        Self.lock.lock(); defer { Self.lock.unlock() }; return failure
    }
    public func clearLastError() { Self.lock.lock(); defer { Self.lock.unlock() }; failure = nil }

    public init(directory: URL? = nil, credentialStore: StorageCredentialStore = KeychainCredentialStore(), fileManager: FileManager = .default) {
        self.directory = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileManager = fileManager; self.credentials = credentialStore
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    public enum StorageError: LocalizedError, Equatable {
        case file(String, String), credentials(String), blocked(String)
        public var errorDescription: String? {
            switch self {
            case .file(let file, let detail): return "\(file): \(detail)"
            case .credentials(let detail): return detail
            case .blocked(let file): return "\(file) was not saved because its existing data could not be read. Recover the file, then reload it before saving."
            }
        }
    }

    public func loadConversations() -> [Conversation] {
        load("conversations.json", missing: [Conversation(title: "Getting Started with PilotAI", messages: [
            Message(role: .assistant, content: "Welcome to **PilotAI** for iOS! You can chat with models, use tools, create roleplay characters, and maintain persistent memory across conversations.")
        ])], failed: [])
    }
    @discardableResult public func saveConversations(_ value: [Conversation]) -> Bool { save(value, "conversations.json") }
    public func loadCharacters() -> [Character] { load("characters.json", missing: Character.defaults, failed: []) }
    @discardableResult public func saveCharacters(_ value: [Character]) -> Bool { save(value, "characters.json") }
    public func loadMemory() -> MemoryDocument { load("memory.json", missing: .default, failed: MemoryDocument(markdown: "", isAutoInjectEnabled: false)) }
    @discardableResult public func saveMemory(_ value: MemoryDocument) -> Bool { save(value, "memory.json") }
    public func loadSettings() -> AppSettings { load("settings.json", missing: AppSettings(), failed: AppSettings()) }
    @discardableResult public func saveSettings(_ value: AppSettings) -> Bool { save(value, "settings.json") }
    public func loadSkills() -> [Skill] { load("skills.json", missing: Skill.defaults, failed: []) }
    @discardableResult public func saveSkills(_ value: [Skill]) -> Bool { save(value, "skills.json") }

    public func loadProviders() -> [ModelProvider] {
        loadSecure("providers.json", missing: ModelProvider.defaults, unpack: Self.unpackProviders, pack: Self.packProviders)
    }
    @discardableResult public func saveProviders(_ value: [ModelProvider]) -> Bool {
        saveSecure(value, "providers.json", unpack: Self.unpackProviders, pack: Self.packProviders)
    }
    public func loadMcpServers() -> [McpServer] {
        loadSecure("mcp_servers.json", missing: [], unpack: Self.unpackServers, pack: Self.packServers)
    }
    @discardableResult public func saveMcpServers(_ value: [McpServer]) -> Bool {
        saveSecure(value, "mcp_servers.json", unpack: Self.unpackServers, pack: Self.packServers)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func record(_ error: Error, file: String, block: Bool = true) {
        failure = (error as? StorageError) ?? .file(file, error.localizedDescription)
        if block { blockedFiles.insert(file) }
    }
    private func readIfPresent(_ name: String) throws -> Data? {
        do { return try Data(contentsOf: url(name)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    private func write(_ data: Data, _ name: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url(name), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url(name), options: .atomic)
        #endif
    }
    private func load<T: Codable>(_ name: String, missing: T, failed: T) -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard let data = try readIfPresent(name) else {
                // A file removed after a failed read is not a successful recovery.
                return blockedFiles.contains(name) ? failed : missing
            }
            let result = try decoder.decode(T.self, from: data)
            blockedFiles.remove(name); return result
        } catch { record(error, file: name); return failed }
    }
    private func save<T: Codable>(_ value: T, _ name: String) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard !blockedFiles.contains(name) else { throw StorageError.blocked(name) }
            // Also protect files a caller has never loaded (including another process's changes).
            if let old = try readIfPresent(name) { _ = try decoder.decode(T.self, from: old) }
        } catch { record(error, file: name); return false }
        do { try write(encoder.encode(value), name); return true }
        catch { record(error, file: name, block: false); return false }
    }

    private struct SecureRecords<T: Codable>: Codable {
        var format = "pilotai-secure-records"
        var version = 1
        var credentialReference: String?
        var records: [T]
    }
    private struct SecretFields: Codable {
        var apiKey: String = ""
        var customHeaders: [CustomHeader] = []
        var customRequestBodyJSON: String?
        var bearerToken: String = ""
        var headers: [String: String] = [:]
        var envVars: [String: String] = [:]
        var isEmpty: Bool { apiKey.isEmpty && customHeaders.isEmpty && (customRequestBodyJSON ?? "").isEmpty && bearerToken.isEmpty && headers.isEmpty && envVars.isEmpty }
    }
    private typealias Secrets = [String: SecretFields]
    private static func packProviders(_ values: [ModelProvider]) -> ([ModelProvider], Secrets) {
        var secrets: Secrets = [:]
        let records = values.map { value -> ModelProvider in
            var value = value; var fields = SecretFields()
            fields.apiKey = value.apiKey; fields.customHeaders = value.customHeaders
            fields.customRequestBodyJSON = value.customRequestBodyJSON.isEmpty ? nil : value.customRequestBodyJSON
            if !fields.isEmpty { secrets[value.id] = fields }
            value.apiKey = ""; value.customHeaders = []; value.customRequestBodyJSON = ""; return value
        }
        return (records, secrets)
    }
    private static func unpackProviders(_ records: [ModelProvider], _ secrets: Secrets) -> [ModelProvider] {
        records.map { value in
            var value = value
            if let secret = secrets[value.id] {
                value.apiKey = secret.apiKey; value.customHeaders = secret.customHeaders
                value.customRequestBodyJSON = secret.customRequestBodyJSON ?? value.customRequestBodyJSON
            }
            return value
        }
    }
    private static func packServers(_ values: [McpServer]) -> ([McpServer], Secrets) {
        var secrets: Secrets = [:]
        let records = values.map { value -> McpServer in
            var value = value; var fields = SecretFields()
            fields.bearerToken = value.bearerToken; fields.headers = value.headers; fields.envVars = value.envVars
            if !fields.isEmpty { secrets[value.id] = fields }
            value.bearerToken = ""; value.headers = [:]; value.envVars = [:]; return value
        }
        return (records, secrets)
    }
    private static func unpackServers(_ records: [McpServer], _ secrets: Secrets) -> [McpServer] {
        records.map { value in
            var value = value
            if let secret = secrets[value.id] { value.bearerToken = secret.bearerToken; value.headers = secret.headers; value.envVars = secret.envVars }
            return value
        }
    }
    private func validateIDs<T: Identifiable>(_ records: [T]) throws where T.ID == String {
        let ids = records.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw StorageError.credentials("Duplicate or blank record IDs cannot be stored securely") }
    }
    private func decodeSecure<T: Codable & Identifiable>(_ data: Data, unpack: ([T], Secrets) -> [T]) throws -> ([T], Bool) where T.ID == String {
        // Legacy records are arrays. Do not mistake a damaged secure envelope for a legacy file.
        if (try JSONSerialization.jsonObject(with: data)) is [Any] {
            let records = try decoder.decode([T].self, from: data); try validateIDs(records); return (records, true)
        }
        let envelope = try decoder.decode(SecureRecords<T>.self, from: data)
        guard envelope.format == "pilotai-secure-records", envelope.version == 1 else { throw StorageError.credentials("Unknown secure storage format") }
        var secrets: Secrets = [:]
        if let reference = envelope.credentialReference {
            guard let data = try credentials.read(account: reference) else { throw StorageError.credentials("Stored credentials are unavailable; the original file has been kept") }
            secrets = try decoder.decode(Secrets.self, from: data)
        }
        try validateIDs(envelope.records)
        return (unpack(envelope.records, secrets), false)
    }
    private func commitSecure<T: Codable & Identifiable>(_ values: [T], _ name: String, pack: ([T]) -> ([T], Secrets)) throws where T.ID == String {
        try validateIDs(values)
        let (records, secrets) = pack(values)
        var reference: String?
        if !secrets.isEmpty {
            let account = "\(name):\(UUID().uuidString)"; let data = try encoder.encode(secrets)
            try credentials.write(data, account: account)
            guard try credentials.read(account: account) == data else { throw StorageError.credentials("Credential verification failed; the original file has been kept") }
            reference = account
        }
        let envelope = SecureRecords(credentialReference: reference, records: records)
        try write(encoder.encode(envelope), name)
    }
    private func loadSecure<T: Codable & Identifiable>(_ name: String, missing: [T], unpack: ([T], Secrets) -> [T], pack: ([T]) -> ([T], Secrets)) -> [T] where T.ID == String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard let data = try readIfPresent(name) else { return blockedFiles.contains(name) ? [] : missing }
            let (records, legacy) = try decodeSecure(data, unpack: unpack)
            blockedFiles.remove(name)
            if legacy {
                // Readable legacy keys remain usable in memory if migration fails. The legacy
                // file is only replaced after the Keychain write and read-back both succeed.
                do { try commitSecure(records, name, pack: pack) }
                catch { record(error, file: name, block: false) }
            }
            return records
        } catch { record(error, file: name); return [] }
    }
    private func saveSecure<T: Codable & Identifiable>(_ values: [T], _ name: String, unpack: ([T], Secrets) -> [T], pack: ([T]) -> ([T], Secrets)) -> Bool where T.ID == String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard !blockedFiles.contains(name) else { throw StorageError.blocked(name) }
            if let old = try readIfPresent(name) { _ = try decodeSecure(old, unpack: unpack) }
        } catch { record(error, file: name); return false }
        do { try commitSecure(values, name, pack: pack); return true }
        catch { record(error, file: name, block: false); return false }
    }

    // The preservation document can contain credentials in unknown Android fields. Encrypt the
    // entire archive instead of trying to guess every secret-bearing key in somebody else's schema.
    private struct EncryptedBackup: Codable {
        let format: String
        let credentialReference: String
        let ciphertext: Data
    }
    private let backupName = "backup_preservation.json"
    private let legacyRawName = "backup_preservation.raw.json"

    public func loadBackupPreservation() -> PilotAIBackupPayload? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard let data = try readIfPresent(backupName) else { return nil }
            let (payload, legacy) = try decodeBackup(data)
            blockedFiles.remove(backupName)
            if legacy {
                do { try commitBackup(payload) }
                catch { record(error, file: backupName, block: false) }
            }
            return payload
        } catch { record(error, file: backupName); return nil }
    }
    @discardableResult public func saveBackupPreservation(_ payload: PilotAIBackupPayload?) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            if let payload {
                guard !blockedFiles.contains(backupName) else { throw StorageError.blocked(backupName) }
                if let data = try readIfPresent(backupName) { _ = try decodeBackup(data) }
                try commitBackup(payload)
            } else {
                // Explicit user-directed clearing only. Credential snapshots are never deleted here.
                for name in [legacyRawName, backupName] where fileManager.fileExists(atPath: url(name).path) { try fileManager.removeItem(at: url(name)) }
                blockedFiles.remove(backupName)
            }
            return true
        } catch { record(error, file: backupName); return false }
    }
    private func decodeBackup(_ data: Data) throws -> (PilotAIBackupPayload, Bool) {
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["format"] as? String == "pilotai-encrypted-backup-v1" {
            #if canImport(CryptoKit)
            let envelope = try decoder.decode(EncryptedBackup.self, from: data)
            guard let key = try credentials.read(account: envelope.credentialReference), key.count == 32 else { throw StorageError.credentials("Backup encryption key is unavailable") }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: SymmetricKey(data: key), authenticating: Data(envelope.credentialReference.utf8))
            return (try BackupService.shared.importBackup(data: plain), false)
            #else
            throw StorageError.credentials("Encrypted backup preservation requires CryptoKit")
            #endif
        }
        var payload = try BackupService.shared.importBackup(data: data)
        if let original = try readIfPresent(legacyRawName) { payload.rawDocument = original }
        return (payload, true)
    }
    private func commitBackup(_ payload: PilotAIBackupPayload) throws {
        #if canImport(CryptoKit)
        // Preserve the original document directly. Re-encoding both Android assets and native
        // snapshots could double a near-limit import and produce an archive we cannot reload.
        let document = try payload.rawDocument ?? encoder.encode(payload)
        _ = try BackupService.shared.importBackup(data: document)
        let account = "backup-key:\(UUID().uuidString)"
        let key = SymmetricKey(size: .bits256); let keyData = key.withUnsafeBytes { Data($0) }
        try credentials.write(keyData, account: account)
        guard try credentials.read(account: account) == keyData else { throw StorageError.credentials("Backup encryption key verification failed") }
        let box = try AES.GCM.seal(document, using: key, authenticating: Data(account.utf8))
        guard let ciphertext = box.combined else { throw StorageError.credentials("Backup encryption failed") }
        try write(encoder.encode(EncryptedBackup(format: "pilotai-encrypted-backup-v1", credentialReference: account, ciphertext: ciphertext)), backupName)
        if fileManager.fileExists(atPath: url(legacyRawName).path) { try fileManager.removeItem(at: url(legacyRawName)) }
        #else
        throw StorageError.credentials("Encrypted backup preservation requires CryptoKit")
        #endif
    }
}
