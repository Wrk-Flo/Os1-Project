import Foundation

/// Stable, opaque user identifier this Mac uses when talking to Composio.
///
/// Composio scopes connected accounts (Gmail authorizations, Slack
/// tokens, etc.) by `user_id`, so we need a value that:
///   - persists across launches (otherwise every relaunch creates a new
///     Composio "user" with no carried-over connections)
///   - is opaque (we don't want to leak hardware UUIDs or email
///     addresses; Composio receives this string and uses it as a foreign
///     key)
///   - survives macOS reinstalls only if the user wants it to
///
/// Stored in UserDefaults — not Keychain — because it's not a secret.
/// Generated lazily on first access. Callers should treat the returned
/// value as a black box.
@MainActor
final class ComposioUserIdentity {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "dev.composio.connect.user-id"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    /// Returns the persisted user_id, generating one on first access.
    /// Format: `os1-<32 random hex chars>` so it's recognizable in
    /// Composio dashboards as coming from this app.
    func userId() -> String {
        if let existing = userDefaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let id = "os1-\(hex)"
        userDefaults.set(id, forKey: key)
        return id
    }

    /// Wipes the stored id. Next call to `userId()` generates a fresh one.
    /// Connections under the old id stay alive on Composio's side but
    /// become unreachable from this Mac.
    func reset() {
        userDefaults.removeObject(forKey: key)
    }
}
