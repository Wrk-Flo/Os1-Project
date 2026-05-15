import Foundation
import SwiftUI

/// Drives the Messaging tab. State machine for connecting Telegram to
/// the active host's Hermes gateway. Telegram is the only platform in
/// v1; the architecture is set up so other platforms (Discord, Slack,
/// WhatsApp) can be added as additional cards later without touching
/// the per-toolkit state.
@MainActor
final class MessagingViewModel: ObservableObject {
    enum SetupStep: Equatable {
        case loading           // initial keychain check
        case unconfigured      // no token stored — show paste form
        case configured        // token present + bot info loaded
    }

    enum InstallState: Equatable {
        case unknown
        case checking
        case notInstalled
        case installing
        case installed(online: Bool)
        case failed(message: String)
    }

    enum ScanResult: Equatable {
        case notRun
        case found(token: String, hostLabel: String)
        case notFound(hostLabel: String)
        case failed(message: String)
    }

    @Published private(set) var step: SetupStep = .loading
    @Published var tokenDraft: String = ""
    @Published var allowedUsersDraft: String = ""
    @Published var useDMPairing: Bool = true   // toggle: pairing flow on by default
    @Published var pairingCode: String = ""
    @Published var formError: String?
    @Published var isBusy = false

    @Published private(set) var validatedBot: TelegramBotInfo?

    @Published private(set) var installState: InstallState = .unknown
    @Published var installError: String?

    @Published private(set) var lastScanResult: ScanResult = .notRun
    @Published private(set) var isScanningForToken = false
    @Published var pairingActionMessage: String?

    private let credentialStore: TelegramCredentialStore
    private let installer: TelegramVMInstaller
    private let api: TelegramAPIClient
    private var currentProfileId: String?

    init(
        credentialStore: TelegramCredentialStore = TelegramCredentialStore(),
        installer: TelegramVMInstaller,
        api: TelegramAPIClient = TelegramAPIClient()
    ) {
        self.credentialStore = credentialStore
        self.installer = installer
        self.api = api
        self.refreshFromStorage()
    }

    func setActiveProfile(_ profileId: String?) {
        if currentProfileId == profileId { return }
        currentProfileId = profileId
        // Clear transient state — the new host has its own bot, status,
        // discovery result.
        validatedBot = nil
        tokenDraft = ""
        allowedUsersDraft = ""
        pairingCode = ""
        formError = nil
        installError = nil
        installState = .unknown
        lastScanResult = .notRun
        pairingActionMessage = nil
        refreshFromStorage()
        // If we have a token for this profile, re-validate it so the
        // configured view shows the right bot identity right away.
        if step == .configured {
            Task { await self.revalidateStoredToken() }
        }
    }

    func refreshFromStorage() {
        step = credentialStore.hasToken(forProfileId: currentProfileId) ? .configured : .unconfigured
    }

    // MARK: - Token validation + save

    func saveToken() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil

        let trimmed = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            formError = "Paste your bot token from @BotFather."
            return
        }

        do {
            let bot = try await api.getMe(token: trimmed)
            try saveTrimmed(token: trimmed)
            tokenDraft = ""
            validatedBot = bot
            step = .configured
            installState = .unknown
        } catch let error as TelegramAPIError {
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }

    /// Re-runs `getMe` against the stored token so the configured
    /// view's bot identity is fresh. Silent on failure — the user can
    /// retry by hitting Reconnect.
    func revalidateStoredToken() async {
        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else { return }
        do {
            validatedBot = try await api.getMe(token: token)
        } catch {
            // Don't blow away the configured step — the token may be
            // valid but the local network can't reach api.telegram.org
            // right now. Just leave validatedBot nil.
            validatedBot = nil
        }
    }

    func disconnect(connection: ConnectionProfile?) async {
        do { try deleteCurrentToken() } catch { }
        validatedBot = nil
        tokenDraft = ""
        allowedUsersDraft = ""
        formError = nil
        installError = nil
        installState = .unknown
        // Best-effort: also wipe TELEGRAM_BOT_TOKEN from the host's
        // .env so the gateway doesn't keep responding under our bot.
        if let connection {
            _ = try? await installer.disconnect(on: connection)
        }
        step = .unconfigured
    }

    private func saveTrimmed(token: String) throws {
        if let profileId = currentProfileId {
            try credentialStore.saveToken(token, forProfileId: profileId)
        } else {
            try credentialStore.saveAsDefault(token)
        }
    }

    private func deleteCurrentToken() throws {
        if let profileId = currentProfileId,
           credentialStore.hasProfileScopedToken(profileId: profileId) {
            try credentialStore.deleteToken(forProfileId: profileId)
        } else {
            try credentialStore.deleteDefaultToken()
        }
    }

    // MARK: - VM detection

    func scanForVMToken(connection: ConnectionProfile) async {
        guard step == .unconfigured else { return }
        guard !credentialStore.hasToken(forProfileId: currentProfileId) else { return }
        guard !isScanningForToken else { return }

        let label = connection.label.isEmpty ? "this host" : connection.label
        isScanningForToken = true
        defer { isScanningForToken = false }

        do {
            let result = try await installer.discoverToken(on: connection)
            guard step == .unconfigured else { return }
            guard !credentialStore.hasToken(forProfileId: currentProfileId) else { return }
            if result.hasDiscoveredToken, let token = result.discovered_token {
                lastScanResult = .found(token: token, hostLabel: label)
                if let users = result.discovered_users, !users.isEmpty {
                    allowedUsersDraft = users
                }
            } else {
                lastScanResult = .notFound(hostLabel: label)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastScanResult = .failed(message: message)
        }
    }

    /// Imports a discovered VM token into Keychain after validating it
    /// against api.telegram.org so we don't end up storing a junk
    /// token from a stale .env.
    func importDiscoveredToken() async {
        guard case .found(let token, _) = lastScanResult else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        formError = nil

        do {
            let bot = try await api.getMe(token: token)
            try saveTrimmed(token: token)
            validatedBot = bot
            step = .configured
            installState = .unknown
            lastScanResult = .notRun
        } catch let error as TelegramAPIError {
            formError = error.errorDescription
        } catch {
            formError = error.localizedDescription
        }
    }

    func dismissDiscoveredToken() {
        lastScanResult = .notRun
    }

    // MARK: - VM install / status

    func checkInstallStatus(on connection: ConnectionProfile) async {
        guard credentialStore.hasToken(forProfileId: currentProfileId) else {
            installState = .unknown
            return
        }
        installState = .checking
        installError = nil
        do {
            let result = try await installer.checkStatus(on: connection)
            if result.isInstalled {
                installState = .installed(online: result.isGatewayOnline)
            } else {
                installState = .notInstalled
            }
        } catch {
            // Status is best-effort — fall back to "not installed" so
            // the install button is offered.
            installState = .notInstalled
        }
    }

    func installOnVM(connection: ConnectionProfile) async {
        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            installError = "Telegram bot token isn't set up yet."
            return
        }
        installState = .installing
        installError = nil
        do {
            let result = try await installer.install(
                on: connection,
                token: token,
                allowedUsers: useDMPairing ? nil : allowedUsersDraft
            )
            if result.success {
                installState = .installed(online: result.isGatewayOnline)
            } else {
                let message = result.errors.joined(separator: "\n")
                installState = .failed(message: message)
                installError = message
            }
        } catch {
            let message = error.localizedDescription
            installState = .failed(message: message)
            installError = message
        }
    }

    // MARK: - Pairing

    func approvePairingCode(connection: ConnectionProfile) async {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            pairingActionMessage = "Enter the pairing code your bot DM'd you."
            return
        }
        pairingActionMessage = nil
        do {
            let result = try await installer.approvePairingCode(on: connection, code: code)
            if result.success {
                pairingActionMessage = "Approved. The user can now message your bot."
                pairingCode = ""
            } else {
                pairingActionMessage = result.errors.joined(separator: "\n")
            }
        } catch {
            pairingActionMessage = error.localizedDescription
        }
    }
}
