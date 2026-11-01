import Foundation
import HoTHCore
import OSLog
import Security
import SwiftUI

// MARK: - Keychain

/// Minimal generic-password Keychain wrapper. Values never leave this type except as return values.
enum KeychainStore {
    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case invalidData

        var description: String {
            switch self {
            case .unexpectedStatus(let status): return "Keychain error (status \(status))"
            case .invalidData: return "Keychain item is not valid UTF-8"
            }
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves (or replaces) a string value.
    static func save(_ value: String, service: String, account: String = "default") throws {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    /// Returns the stored string, or nil when no item exists.
    static func read(service: String, account: String = "default") throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return string
    }

    static func delete(service: String, account: String = "default") throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - API key provider

/// Supplies the OpenAI key from the Keychain at call time. Never logs the key.
/// DEBUG simulator builds fall back to the `OPENAI_API_KEY` scheme environment variable.
struct KeychainAPIKeyProvider: APIKeyProvider {
    static let service = "HoTH.OpenAIKey"

    func apiKey() async throws -> String {
        guard let key = currentKey() else { throw OpenAIError.missingKey }
        return key
    }

    /// Synchronous lookup for UI status (masked display only).
    func currentKey() -> String? {
        if let stored = try? KeychainStore.read(service: Self.service),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #if DEBUG && targetEnvironment(simulator)
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        #endif
        return nil
    }

    var isUsingEnvironmentFallback: Bool {
        let stored = (try? KeychainStore.read(service: Self.service)) ?? nil
        return (stored ?? "").isEmpty && currentKey() != nil
    }

    func save(_ key: String) throws {
        try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), service: Self.service)
    }

    func delete() throws {
        try KeychainStore.delete(service: Self.service)
    }

    /// "••••1234" style status; never exposes more than the last four characters.
    func maskedStatus() -> String? {
        guard let key = currentKey(), key.count >= 4 else { return nil }
        return "••••" + key.suffix(4)
    }
}

// MARK: - App services

/// Shared app-wide services and user settings.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    enum Role: String, CaseIterable, Identifiable {
        case resident, crew
        var id: String { rawValue }
    }

    enum Language: String, CaseIterable, Identifiable {
        case system, en, ar
        var id: String { rawValue }
    }

    let keyProvider: KeychainAPIKeyProvider
    var openAI: OpenAIClient
    var prompts: Prompts

    // Settings are UserDefaults-backed (same keys work with `@AppStorage` in views). Explicit
    // `objectWillChange` keeps every observer (RTL flip, toggles) in sync without a relaunch.
    enum SettingsKey {
        static let demoMode = "hoth.settings.demoMode"
        static let role = "hoth.settings.role"
        static let visionModel = "hoth.settings.visionModel"
        static let language = "hoth.settings.language"
        static let voiceFirstInterview = "hoth.settings.voiceFirstInterview"
    }

    private let defaults = UserDefaults.standard

    var demoMode: Bool {
        get { defaults.object(forKey: SettingsKey.demoMode) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: SettingsKey.demoMode) }
    }

    /// "Start interview with voice": the interview opens on Talk (default on).
    var voiceFirstInterview: Bool {
        get { defaults.object(forKey: SettingsKey.voiceFirstInterview) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: SettingsKey.voiceFirstInterview) }
    }

    /// "resident" or "crew".
    var role: String {
        get { defaults.string(forKey: SettingsKey.role) ?? Role.resident.rawValue }
        set { objectWillChange.send(); defaults.set(newValue, forKey: SettingsKey.role) }
    }

    var visionModelOverride: String {
        get { defaults.string(forKey: SettingsKey.visionModel) ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: SettingsKey.visionModel) }
    }

    /// "system", "en" or "ar".
    var preferredLanguage: String {
        get { defaults.string(forKey: SettingsKey.language) ?? Language.system.rawValue }
        set { objectWillChange.send(); defaults.set(newValue, forKey: SettingsKey.language) }
    }

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "AppServices")

    private init() {
        let provider = KeychainAPIKeyProvider()
        keyProvider = provider
        openAI = OpenAIClient(keyProvider: provider)
        do {
            prompts = try Prompts(bundle: .main)
        } catch {
            // prompts.json is a bundled build input; its absence is a packaging bug, not a runtime state.
            Self.logger.fault("prompts.json failed to load: \(String(describing: error))")
            preconditionFailure("prompts.json missing or invalid: \(error)")
        }
    }

    /// Vision model: the user override when set, else the prompts.json default.
    var visionModel: String {
        Prompts.resolveVisionModel(override: visionModelOverride, prompts: prompts)
    }

    var isCrew: Bool { role == Role.crew.rawValue }

    /// DEBUG-only UI-test mode (`HOTH_UITEST=1` launch env): in-memory store and the local chat
    /// interview, so the golden-path UI test is repeatable and makes at most one live call (vision).
    nonisolated static var isUITestRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HOTH_UITEST"] == "1"
        #else
        return false
        #endif
    }

    /// Locale override for the SwiftUI environment; nil follows the system.
    var localeOverride: Locale? {
        switch Language(rawValue: preferredLanguage) ?? .system {
        case .system: return nil
        case .en: return Locale(identifier: "en")
        case .ar: return Locale(identifier: "ar")
        }
    }

    /// True when content should be shown in Arabic (override, or system language).
    var isArabic: Bool {
        let identifier = localeOverride?.identifier ?? Locale.preferredLanguages.first ?? "en"
        return identifier.hasPrefix("ar")
    }

    var layoutDirection: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }

    func hasAPIKey() -> Bool { keyProvider.currentKey() != nil }

    func saveAPIKey(_ key: String) throws {
        try keyProvider.save(key)
        objectWillChange.send()
    }

    func deleteAPIKey() throws {
        try keyProvider.delete()
        objectWillChange.send()
    }
}
