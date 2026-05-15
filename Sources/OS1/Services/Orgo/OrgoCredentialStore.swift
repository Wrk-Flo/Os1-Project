import Foundation
import Security

/// macOS Keychain wrapper for the global Orgo API key.
///
/// One key per Mac (per the design decision). The key is stored as a generic
/// password keyed by service+account so the app can read/write/delete without
/// surfacing any persistence detail to UI code. UI talks to this class; this
/// class talks to the Keychain.
final class OrgoCredentialStore: @unchecked Sendable {
    enum CredentialError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Couldn't save the Orgo API key to Keychain (status \(status))."
            case .deleteFailed(let status):
                return "Couldn't remove the Orgo API key from Keychain (status \(status))."
            }
        }
    }

    private let service: String
    private let account: String

    init(service: String = "ai.orgo.mac.api-key", account: String = "default") {
        self.service = service
        self.account = account
    }

    /// Returns the stored API key, or nil if none has been saved.
    func loadAPIKey() -> String? {
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

    /// True if a (non-empty) API key is currently stored.
    var hasAPIKey: Bool {
        loadAPIKey() != nil
    }

    /// Saves the API key, replacing any existing value. Empty/whitespace input
    /// is treated as a delete to keep the store from carrying empty entries.
    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

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

    /// Removes the API key from Keychain. No-op if none is stored.
    func deleteAPIKey() throws {
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
