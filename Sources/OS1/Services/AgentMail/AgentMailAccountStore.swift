import Foundation

/// Non-sensitive metadata for the user's AgentMail account, stored in
/// UserDefaults alongside the Keychain-stored API key.
///
/// Like `AgentMailCredentialStore`, metadata is per-`ConnectionProfile.id`
/// with a Mac-level default fallback. Switching to a different host
/// auto-swaps which inbox / human email / verification status the UI
/// shows — no risk of conflating one user's email with another's.
struct AgentMailAccount: Codable, Equatable {
    /// The human email the user signed up with (used to send the OTP).
    /// For BYOK paths we don't always know this, so it's optional.
    var humanEmail: String?

    /// Default inbox returned by sign-up, e.g. "nick-agent@agentmail.to".
    var primaryInboxId: String?

    /// Organization owning the account.
    var organizationId: String?

    /// True after the OTP /verify step has succeeded for this account.
    var isVerified: Bool = false
}

@MainActor
final class AgentMailAccountStore: ObservableObject {
    static let defaultSlot = "default"

    /// The currently-active account metadata. Updated every time we
    /// `setActiveProfile(...)` so SwiftUI views refresh on connection
    /// switches without callers needing to read a profile id at every
    /// call site.
    @Published private(set) var account: AgentMailAccount?

    private let userDefaults: UserDefaults
    private let baseKey: String
    private var activeProfileId: String?

    init(
        userDefaults: UserDefaults = .standard,
        baseKey: String = "to.agentmail.account-metadata"
    ) {
        self.userDefaults = userDefaults
        self.baseKey = baseKey
        self.account = nil
        // Initial load uses the default slot until the view layer pushes
        // a profile id in.
        self.account = read(forSlot: Self.defaultSlot)
    }

    // MARK: - Active profile

    /// Called by the view layer whenever the active connection changes
    /// (or initially, on app launch). Resolves: profile-scoped first,
    /// default fallback second.
    func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        account = read(forSlot: profileId ?? Self.defaultSlot)
            ?? (profileId != nil ? read(forSlot: Self.defaultSlot) : nil)
    }

    // MARK: - Mutation

    /// Updates the account for the active context. Writes to the
    /// profile-scoped slot if a profile is active, otherwise the default.
    func update(_ updater: (inout AgentMailAccount) -> Void) {
        var current = account ?? AgentMailAccount()
        updater(&current)
        account = current
        persistActive()
    }

    func setAccount(_ next: AgentMailAccount) {
        account = next
        persistActive()
    }

    func clear() {
        account = nil
        if let activeProfileId {
            userDefaults.removeObject(forKey: storageKey(forSlot: activeProfileId))
        } else {
            userDefaults.removeObject(forKey: storageKey(forSlot: Self.defaultSlot))
        }
    }

    // MARK: - Direct slot accessors (used by detection / migration)

    func account(forProfileId profileId: String) -> AgentMailAccount? {
        read(forSlot: profileId) ?? read(forSlot: Self.defaultSlot)
    }

    func setAccount(_ account: AgentMailAccount, forProfileId profileId: String) {
        write(account, toSlot: profileId)
        if activeProfileId == profileId {
            self.account = account
        }
    }

    func clear(forProfileId profileId: String) {
        userDefaults.removeObject(forKey: storageKey(forSlot: profileId))
        if activeProfileId == profileId {
            account = nil
        }
    }

    // MARK: - Internals

    private func persistActive() {
        guard let account else {
            if let activeProfileId {
                userDefaults.removeObject(forKey: storageKey(forSlot: activeProfileId))
            } else {
                userDefaults.removeObject(forKey: storageKey(forSlot: Self.defaultSlot))
            }
            return
        }
        write(account, toSlot: activeProfileId ?? Self.defaultSlot)
    }

    private func read(forSlot slot: String) -> AgentMailAccount? {
        guard let data = userDefaults.data(forKey: storageKey(forSlot: slot)) else { return nil }
        return try? JSONDecoder().decode(AgentMailAccount.self, from: data)
    }

    private func write(_ account: AgentMailAccount, toSlot slot: String) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        userDefaults.set(data, forKey: storageKey(forSlot: slot))
    }

    private func storageKey(forSlot slot: String) -> String {
        slot == Self.defaultSlot ? baseKey : "\(baseKey).profile.\(slot)"
    }
}
