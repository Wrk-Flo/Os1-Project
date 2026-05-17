import Foundation
import Security

/// Keychain wrapper for the future Cua computer-session API key.
///
/// Cua is intentionally separate from `ConnectionProfile` credentials: it is a
/// disposable computer-session provider, not an OS1 host transport.
final class CuaCredentialStore: @unchecked Sendable {
    enum CredentialError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                "Couldn't save the Cua API key to Keychain (status \(status))."
            case .deleteFailed(let status):
                "Couldn't remove the Cua API key from Keychain (status \(status))."
            }
        }
    }

    private let service: String
    private let account: String

    init(service: String = "ai.os1.cua.api-key", account: String = "default") {
        self.service = service
        self.account = account
    }

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

    var hasAPIKey: Bool {
        loadAPIKey() != nil
    }

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
