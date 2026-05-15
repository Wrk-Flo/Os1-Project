import Foundation
import Security

/// Per-Mac Keychain wrapper for the user's Composio Connect API key(s).
///
/// Credentials are scoped per `ConnectionProfile.id` so switching to a
/// different host automatically reads that host's key — never leaks one
/// connection's credential into another connection's
/// VM. A Mac-level "default" slot persists for users with a single
/// Composio account they share across their own VMs (most common case)
/// so they don't have to paste once per host.
///
/// Resolution order on read:
///   1. Profile-scoped slot (`<profileId>` Keychain account) — strict per-host
///   2. Default slot (`default` Keychain account) — Mac-level fallback
///
/// Writes always target a specific slot. The view-models choose:
///   - `saveAPIKey(_, forProfileId:)` for a host-specific paste/import
///   - `saveAsDefault(_)` for "make this my default" (UI flag, future)
final class ComposioCredentialStore: @unchecked Sendable {
    enum CredentialError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Couldn't save the Composio API key to Keychain (status \(status))."
            case .deleteFailed(let status):
                return "Couldn't remove the Composio API key from Keychain (status \(status))."
            }
        }
    }

    static let defaultAccount = "default"

    private let service: String

    init(service: String = "dev.composio.connect.api-key") {
        self.service = service
    }

    // MARK: - Read

    /// Resolves the API key for the active context. Profile-scoped first;
    /// falls back to the Mac-level default. Returns nil if nothing is
    /// stored at either tier.
    func loadAPIKey(forProfileId profileId: String? = nil) -> String? {
        if let profileId, let key = readKey(account: profileId) {
            return key
        }
        return readKey(account: Self.defaultAccount)
    }

    /// True if either a profile-specific or default key is stored.
    func hasAPIKey(forProfileId profileId: String? = nil) -> Bool {
        loadAPIKey(forProfileId: profileId) != nil
    }

    /// True if there's a profile-scoped key (regardless of default).
    /// Lets the UI distinguish "this host has its own key" from "we're
    /// just using the Mac-level default."
    func hasProfileScopedKey(profileId: String) -> Bool {
        readKey(account: profileId) != nil
    }

    // MARK: - Write

    /// Saves a key into a specific profile's slot. Empty input deletes
    /// that slot.
    func saveAPIKey(_ apiKey: String, forProfileId profileId: String) throws {
        try saveKey(apiKey, account: profileId)
    }

    /// Saves a key as the Mac-level default. Same semantics for empty.
    func saveAsDefault(_ apiKey: String) throws {
        try saveKey(apiKey, account: Self.defaultAccount)
    }

    // MARK: - Delete

    func deleteKey(forProfileId profileId: String) throws {
        try deleteKey(account: profileId)
    }

    func deleteDefaultKey() throws {
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

    private func saveKey(_ apiKey: String, account: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
