import Foundation
import Security

/// Per-Mac Keychain wrapper for the user's Telegram bot tokens.
///
/// Same per-`ConnectionProfile.id` slot pattern as Composio /
/// AgentMail: switching hosts auto-swaps to whatever bot is configured
/// for that host. Mac-level "default" slot is the
/// fallback for users whose hosts share a bot.
final class TelegramCredentialStore: @unchecked Sendable {
    enum CredentialError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Couldn't save the Telegram bot token to Keychain (status \(status))."
            case .deleteFailed(let status):
                return "Couldn't remove the Telegram bot token from Keychain (status \(status))."
            }
        }
    }

    static let defaultAccount = "default"

    private let service: String

    init(service: String = "org.telegram.bot-token") {
        self.service = service
    }

    func loadToken(forProfileId profileId: String? = nil) -> String? {
        if let profileId, let key = readKey(account: profileId) {
            return key
        }
        return readKey(account: Self.defaultAccount)
    }

    func hasToken(forProfileId profileId: String? = nil) -> Bool {
        loadToken(forProfileId: profileId) != nil
    }

    func hasProfileScopedToken(profileId: String) -> Bool {
        readKey(account: profileId) != nil
    }

    func saveToken(_ token: String, forProfileId profileId: String) throws {
        try saveKey(token, account: profileId)
    }

    func saveAsDefault(_ token: String) throws {
        try saveKey(token, account: Self.defaultAccount)
    }

    func deleteToken(forProfileId profileId: String) throws {
        try deleteKey(account: profileId)
    }

    func deleteDefaultToken() throws {
        try deleteKey(account: Self.defaultAccount)
    }

    // MARK: - Internals

    private func readKey(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveKey(_ token: String, account: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteKey(account: account)
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.saveFailed(addStatus)
            }
        default:
            throw CredentialError.saveFailed(updateStatus)
        }
    }

    private func deleteKey(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CredentialError.deleteFailed(status)
        }
    }
}
