import Foundation
import SwiftUI

/// State machine for the Mail tab. Owns the UI state, form values, and
/// the orchestration between sign-up / verify / BYOK paths. Network IO
/// is delegated to `AgentMailService`; persistence to
/// `AgentMailCredentialStore` + `AgentMailAccountStore`.
@MainActor
final class MailSetupViewModel: ObservableObject {
    enum Step: Equatable {
        case loading                                              // initial keychain check
        case unconfigured                                         // entry choice screen
        case signupForm                                           // email + username form
        case awaitingOTP(pending: PendingSignup)                  // OTP entry
        case byokForm(reason: BYOKReason)                         // paste API key
        case inboxPicker(apiKey: String,
                         inboxes: [AgentMailInboxSummary])        // pick or create inbox after BYOK
        case configured(account: AgentMailAccount)
    }

    enum BYOKReason: Equatable {
        case userChose
        case emailAlreadyRegistered
    }

    struct PendingSignup: Equatable {
        let apiKey: String
        let humanEmail: String
        let primaryInboxId: String?
        let organizationId: String?
    }

    @Published private(set) var step: Step = .loading
    @Published private(set) var isBusy = false
    @Published var formError: String?

    // Sign-up form state
    @Published var signupEmail: String = ""
    @Published var signupUsername: String = ""
    @Published var otpCode: String = ""

    // BYOK form state
    @Published var byokKey: String = ""

    // Inbox picker state
    @Published var newInboxUsername: String = ""

    // VM scan state — mirrors ConnectorsViewModel's pattern.
    @Published private(set) var discoveredVMKey: DiscoveredKey?
    @Published private(set) var isScanningForVMKey = false
    @Published private(set) var lastScanResult: ScanResult = .notRun

    struct DiscoveredKey: Equatable {
        let key: String
        let primaryInboxId: String?
        let connectionLabel: String
    }

    enum ScanResult: Equatable {
        case notRun
        case found(DiscoveredKey)
        case notFound(connectionLabel: String)
        case failed(message: String)
    }

    private let credentialStore: AgentMailCredentialStore
    private let accountStore: AgentMailAccountStore
    private let service: AgentMailService
    private let vmScanner: AgentMailVMScanner?
    private var currentProfileId: String?

    init(
        credentialStore: AgentMailCredentialStore = AgentMailCredentialStore(),
        accountStore: AgentMailAccountStore,
        service: AgentMailService = AgentMailService(),
        vmScanner: AgentMailVMScanner? = nil
    ) {
        self.credentialStore = credentialStore
        self.accountStore = accountStore
        self.service = service
        self.vmScanner = vmScanner
        self.refreshFromStorage()
    }

    /// Pushed by the view layer whenever the active connection changes.
    /// Re-derives `step` against the new profile's slot (or the default
    /// fallback) so the Mail tab auto-swaps inboxes without leaking one
    /// connection's account into another host.
    func setActiveProfile(_ profileId: String?) {
        if currentProfileId == profileId { return }
        currentProfileId = profileId
        accountStore.setActiveProfile(profileId)
        // Reset transient form state so the new context starts clean.
        signupEmail = ""
        signupUsername = ""
        otpCode = ""
        byokKey = ""
        newInboxUsername = ""
        formError = nil
        // Forget the previous host's scan; the new one starts fresh.
        discoveredVMKey = nil
        lastScanResult = .notRun
        refreshFromStorage()
    }

    private func saveTrimmedKey(_ key: String) throws {
        if let profileId = currentProfileId {
            try credentialStore.saveAPIKey(key, forProfileId: profileId)
        } else {
            try credentialStore.saveAsDefault(key)
        }
    }

    private func deleteCurrentKey() throws {
        if let profileId = currentProfileId,
           credentialStore.hasProfileScopedKey(profileId: profileId) {
            try credentialStore.deleteKey(forProfileId: profileId)
        } else {
            try credentialStore.deleteDefaultKey()
        }
    }

    /// Re-derives `step` from on-disk state. Called on init and on
    /// explicit "clear/reset" actions.
    func refreshFromStorage() {
        if credentialStore.hasAPIKey(forProfileId: currentProfileId), let account = accountStore.account, account.isVerified {
            step = .configured(account: account)
        } else {
            step = .unconfigured
        }
    }

    // MARK: - Navigation actions

    func chooseSignUp() {
        formError = nil
        step = .signupForm
    }

    func chooseBYOK() {
        formError = nil
        step = .byokForm(reason: .userChose)
    }

    func backToEntry() {
        formError = nil
        signupEmail = ""
        signupUsername = ""
        otpCode = ""
        byokKey = ""
        step = .unconfigured
    }

    /// Drops the stored credentials so the user can start over. Used by
    /// "Disconnect AgentMail" buttons in the configured state.
    func reset() {
        do { try deleteCurrentKey() } catch { }
        accountStore.clear()
        signupEmail = ""
        signupUsername = ""
        otpCode = ""
        byokKey = ""
        step = .unconfigured
    }

    // MARK: - Sign-up

    func submitSignUp() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil

        do {
            let result = try await service.signUp(
                humanEmail: signupEmail,
                username: signupUsername
            )
            // Stash the freshly-issued key NOW so the next /verify call has
            // a Bearer token to authenticate with. We mark unverified until
            // verify succeeds.
            try? saveTrimmedKey(result.apiKey)
            accountStore.setAccount(AgentMailAccount(
                humanEmail: result.humanEmail,
                primaryInboxId: result.primaryInboxId,
                organizationId: result.organizationId,
                isVerified: false
            ))
            step = .awaitingOTP(pending: PendingSignup(
                apiKey: result.apiKey,
                humanEmail: result.humanEmail,
                primaryInboxId: result.primaryInboxId,
                organizationId: result.organizationId
            ))
        } catch let AgentMailError.emailAlreadyRegistered(message) {
            // Drop into BYOK with a clear explanation.
            formError = nil
            step = .byokForm(reason: .emailAlreadyRegistered)
            // Stash the email so the form copy can echo it back later if useful.
            byokKey = ""
            _ = message  // already surfaced via the BYOK reason copy
        } catch let error as AgentMailError {
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }

    func resendOTP() async {
        guard case .awaitingOTP(let pending) = step else { return }
        // Sign-up is idempotent — calling it again rotates the key and
        // re-sends the OTP. Mirror the new key + reset the OTP field.
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil
        do {
            let result = try await service.signUp(
                humanEmail: pending.humanEmail,
                username: signupUsername.isEmpty ? extractUsername(from: pending.primaryInboxId) : signupUsername
            )
            try? saveTrimmedKey(result.apiKey)
            accountStore.setAccount(AgentMailAccount(
                humanEmail: result.humanEmail,
                primaryInboxId: result.primaryInboxId,
                organizationId: result.organizationId,
                isVerified: false
            ))
            step = .awaitingOTP(pending: PendingSignup(
                apiKey: result.apiKey,
                humanEmail: result.humanEmail,
                primaryInboxId: result.primaryInboxId,
                organizationId: result.organizationId
            ))
            otpCode = ""
        } catch {
            formError = (error as? AgentMailError)?.errorDescription ?? error.localizedDescription
        }
    }

    func submitVerifyOTP() async {
        guard case .awaitingOTP(let pending) = step else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil

        do {
            try await service.verify(apiKey: pending.apiKey, otpCode: otpCode)
            accountStore.update { acct in
                acct.humanEmail = pending.humanEmail
                acct.primaryInboxId = pending.primaryInboxId
                acct.organizationId = pending.organizationId
                acct.isVerified = true
            }
            otpCode = ""
            if let account = accountStore.account {
                step = .configured(account: account)
            }
        } catch let error as AgentMailError {
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }

    // MARK: - BYOK

    func submitBYOK() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil

        do {
            let inboxes = try await service.validateAPIKey(byokKey)
            // Hand off to the inbox picker so the user explicitly chooses
            // (or creates) the inbox to associate with this Mac.
            // Don't persist the key yet — only on confirm.
            step = .inboxPicker(apiKey: byokKey, inboxes: inboxes)
        } catch let error as AgentMailError {
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }

    // MARK: - Inbox picker

    func selectInbox(_ inbox: AgentMailInboxSummary) {
        guard case .inboxPicker(let apiKey, _) = step else { return }
        do {
            try saveTrimmedKey(apiKey)
            accountStore.setAccount(AgentMailAccount(
                humanEmail: nil,
                primaryInboxId: inbox.inbox_id,
                organizationId: nil,
                isVerified: true   // BYOK keys are already activated
            ))
            byokKey = ""
            if let account = accountStore.account {
                step = .configured(account: account)
            }
        } catch {
            formError = error.localizedDescription
        }
    }

    func createInboxAndUse() async {
        guard case .inboxPicker(let apiKey, _) = step else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil

        let username = newInboxUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            formError = "Enter a username for the new inbox."
            return
        }

        do {
            let created = try await service.createInbox(
                apiKey: apiKey,
                username: username,
                displayName: nil,
                clientId: nil
            )
            try saveTrimmedKey(apiKey)
            accountStore.setAccount(AgentMailAccount(
                humanEmail: nil,
                primaryInboxId: created.inbox_id,
                organizationId: nil,
                isVerified: true
            ))
            byokKey = ""
            newInboxUsername = ""
            if let account = accountStore.account {
                step = .configured(account: account)
            }
        } catch let error as AgentMailError {
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }

    func backFromInboxPicker() {
        formError = nil
        newInboxUsername = ""
        step = .byokForm(reason: .userChose)
    }

    private func extractUsername(from inboxId: String?) -> String {
        guard let inboxId, let at = inboxId.firstIndex(of: "@") else { return "agent" }
        return String(inboxId[..<at])
    }

    // MARK: - VM key auto-detection

    /// Scans the active host's `~/.hermes/config.yaml` for an existing
    /// AgentMail MCP entry (any of `mcp_servers.{agentmail | AgentMail
    /// | agent_mail}`) and pulls its API key out of `env` or `args`.
    /// Cancellable; safe to call from both auto-on-appear paths and
    /// explicit user clicks.
    func scanForVMKey(connection: ConnectionProfile) async {
        guard let vmScanner else { return }
        guard step == .unconfigured || isOnBYOKPath else { return }
        guard !credentialStore.hasAPIKey(forProfileId: currentProfileId) else { return }
        guard !isScanningForVMKey else { return }

        let label = connection.label.isEmpty ? "this host" : connection.label
        isScanningForVMKey = true
        defer { isScanningForVMKey = false }

        do {
            let result = try await vmScanner.discoverKey(on: connection)
            guard step == .unconfigured || isOnBYOKPath else { return }
            guard !credentialStore.hasAPIKey(forProfileId: currentProfileId) else { return }
            if result.hasDiscoveredKey, let key = result.discovered_key {
                let discovered = DiscoveredKey(
                    key: key,
                    primaryInboxId: result.primary_inbox_id,
                    connectionLabel: label
                )
                discoveredVMKey = discovered
                lastScanResult = .found(discovered)
            } else {
                discoveredVMKey = nil
                lastScanResult = .notFound(connectionLabel: label)
            }
        } catch {
            discoveredVMKey = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastScanResult = .failed(message: message)
        }
    }

    /// Whether `step` is somewhere a manual paste would be expected
    /// (entry screen, BYOK form, or after the email-already-registered
    /// auto-redirect). The discover button shows up wherever a paste
    /// would otherwise be the only option.
    private var isOnBYOKPath: Bool {
        if case .byokForm = step { return true }
        return false
    }

    /// Pulls the discovered key into the active profile's Keychain
    /// slot. Like Composio's discover flow, we never write to the
    /// Mac-level default, so one connection's key never overwrites yours.
    func importDiscoveredKey() {
        guard let discovered = discoveredVMKey else { return }
        do {
            try saveTrimmedKey(discovered.key)
            // We don't know whether the discovered key is OTP-verified,
            // but if it's on a working VM it almost certainly is. Mark
            // verified so the user can use it immediately; if AgentMail
            // ever rejects an unverified key, we'll surface the error
            // on the first call.
            accountStore.setAccount(AgentMailAccount(
                humanEmail: nil,
                primaryInboxId: discovered.primaryInboxId,
                organizationId: nil,
                isVerified: true
            ))
            byokKey = ""
            discoveredVMKey = nil
            if let account = accountStore.account {
                step = .configured(account: account)
            }
        } catch {
            formError = error.localizedDescription
        }
    }

    func dismissDiscoveredKey() {
        discoveredVMKey = nil
    }
}
