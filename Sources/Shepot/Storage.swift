import AppKit
import Security
import LocalAuthentication
import WhisperCore

struct Dictation: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var original: String
    var text: String
    var style: WritingStyle
    var duration: TimeInterval
    var app: String
    var usedAI: Bool
    var words: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var language: String { didSet { save() } }
    @Published var style: WritingStyle { didSet { save() } }
    @Published var useAI: Bool { didSet { save() } }
    @Published var model: String { didSet { save() } }
    @Published var editorBackend: EditorBackend { didSet { save() } }
    @Published var codexPath: String { didSet { save() } }
    @Published var saveHistory: Bool { didSet { save() } }
    @Published var offlineOnly: Bool { didSet { save() } }
    @Published var dictionary: [DictionaryEntry] { didSet { save() } }
    @Published var hasAPIKey: Bool
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        language = d.string(forKey: "language") ?? "ru-RU"
        style = WritingStyle(rawValue: d.string(forKey: "style") ?? "") ?? .clean
        useAI = d.object(forKey: "useAI") as? Bool ?? true
        model = d.string(forKey: "model") ?? AIEditor.defaultModel
        editorBackend = EditorBackend(rawValue: d.string(forKey: "editorBackend") ?? "") ?? .codexLuna
        codexPath = d.string(forKey: "codexPath") ?? CodexEditor.discoverExecutable() ?? ""
        saveHistory = d.object(forKey: "saveHistory") as? Bool ?? true
        offlineOnly = d.bool(forKey: "offlineOnly")
        dictionary = (try? JSONDecoder().decode([DictionaryEntry].self, from: d.data(forKey: "dictionary") ?? Data())) ?? []
        // Do not read Keychain on launch; metadata lookup does not prompt for access.
        hasAPIKey = Keychain.containsKey()
    }

    func saveAPIKey(_ value: String) throws {
        try Keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = Keychain.containsKey()
    }

    private func save() {
        defaults.set(language, forKey: "language")
        defaults.set(style.rawValue, forKey: "style")
        defaults.set(useAI, forKey: "useAI")
        defaults.set(model, forKey: "model")
        defaults.set(editorBackend.rawValue, forKey: "editorBackend")
        defaults.set(codexPath, forKey: "codexPath")
        defaults.set(saveHistory, forKey: "saveHistory")
        defaults.set(offlineOnly, forKey: "offlineOnly")
        defaults.set(try? JSONEncoder().encode(dictionary), forKey: "dictionary")
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.shepot.mac",
        kSecAttrAccount as String: "openai-api-key"
    ]
    static func containsKey() -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("Не удалось удалить ключ из Связки ключей (\(status)).") }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppError.message("Не удалось сохранить ключ в Связку ключей (\(added)).") }
        } else if status != errSecSuccess {
            throw AppError.message("Не удалось обновить ключ в Связке ключей (\(status)).")
        }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [Dictation] = []
    @Published var storageError: String?
    private let url: URL

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shepot", isDirectory: true)
        url = directory.appendingPathComponent("history.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: url.path) {
                entries = try JSONDecoder().decode([Dictation].self, from: Data(contentsOf: url))
            }
        } catch { storageError = "Не удалось прочитать историю: \(error.localizedDescription)" }
    }
    func add(_ entry: Dictation) {
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(200))
        persist()
    }
    func upsert(_ entry: Dictation) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry; persist() }
        else { add(entry) }
    }
    func update(_ id: UUID, text: String, usedAI: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = text; entries[index].usedAI = usedAI; persist()
    }
    func remove(_ id: UUID) { entries.removeAll { $0.id == id }; persist() }
    func clear() { entries.removeAll(); persist() }
    private func persist() {
        do {
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            storageError = nil
        } catch { storageError = "История не сохранена: \(error.localizedDescription)" }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
