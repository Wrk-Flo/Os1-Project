import Foundation
import SwiftUI

/// Drives the Doctor tab. Phase 1 surfaces two checks per active host:
///
///   1. **Hermes gateway** — runs `hermes gateway status` + reads
///      `~/.hermes/gateway_state.json` for per-platform state. Offers
///      a Restart action that re-runs the supervised install path.
///   2. **Telegram bot** — pings `getMe` against the stored bot token
///      and cross-references against the gateway's view of telegram.
///      Offers a Revalidate action.
///
/// Manual refresh + onAppear only — auto-polling deliberately deferred
/// to Phase 2. The user goes to this tab when something feels wrong;
/// they'll click Refresh.
@MainActor
final class DoctorViewModel: ObservableObject {

    enum Severity: Equatable, Sendable {
        case unknown   // not yet checked
        case ok        // green — everything healthy
        case warn      // amber — degraded but not fatal
        case error     // red — broken, needs user attention
    }

    enum Action: Equatable, Hashable, Sendable {
        case restartGateway
        case revalidateTelegram
        case updateHermes
    }

    struct Check: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let severity: Severity
        let summary: String
        let detail: String?
        let actions: [Action]
    }

    @Published private(set) var checks: [Check] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var actionInFlight: Action?
    @Published var actionError: String?
    @Published private(set) var lastRefreshedAt: Date?

    private let credentialStore: TelegramCredentialStore
    private let telegramAPI: TelegramAPIClient
    private let telegramInstaller: TelegramVMInstaller
    private let hermesUpdater: HermesUpdater
    /// Bridges to AppState — DoctorViewModel doesn't take AppState in its
    /// init (avoids a cycle, keeps unit tests simple), but the update
    /// trigger + availability state need to flow back so the Overview
    /// banner sees the same source-of-truth. Set after construction via
    /// `bindHermesUpdateBridge`.
    private var performHermesUpdateBridge: @MainActor () async -> Void = { }
    private var publishHermesAvailability: @MainActor (HermesUpdateAvailability) -> Void = { _ in }
    private var currentConnection: ConnectionProfile?
    private var currentProfileId: String?

    init(
        credentialStore: TelegramCredentialStore,
        telegramAPI: TelegramAPIClient = TelegramAPIClient(),
        telegramInstaller: TelegramVMInstaller,
        hermesUpdater: HermesUpdater
    ) {
        self.credentialStore = credentialStore
        self.telegramAPI = telegramAPI
        self.telegramInstaller = telegramInstaller
        self.hermesUpdater = hermesUpdater
    }

    func bindHermesUpdateBridge(
        performUpdate: @escaping @MainActor () async -> Void,
        publishAvailability: @escaping @MainActor (HermesUpdateAvailability) -> Void
    ) {
        self.performHermesUpdateBridge = performUpdate
        self.publishHermesAvailability = publishAvailability
    }

    func setActiveConnection(_ connection: ConnectionProfile?) {
        if currentConnection?.id == connection?.id { return }
        currentConnection = connection
        currentProfileId = connection?.id.uuidString
        // Reset transient state — the new host has its own checks.
        checks = []
        lastRefreshedAt = nil
        actionError = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        actionError = nil

        guard let connection = currentConnection else {
            checks = [Check(
                id: "no-connection",
                title: L10n.string("No host selected"),
                severity: .unknown,
                summary: L10n.string("Connect to a host on the Host tab to run checks."),
                detail: nil,
                actions: []
            )]
            return
        }

        // Probe the host. If this fails, every downstream check is
        // moot — surface a single transport-level error row.
        let statusResult: TelegramVMResult
        do {
            statusResult = try await telegramInstaller.checkStatus(on: connection)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            checks = [Check(
                id: "host-unreachable",
                title: L10n.string("Host unreachable"),
                severity: .error,
                summary: L10n.string("Couldn't reach this host to run health checks."),
                detail: message,
                actions: []
            )]
            lastRefreshedAt = Date()
            return
        }

        let snapshot = GatewayStateSnapshot.decode(from: statusResult.gateway_state_json)
        let gatewayCheck = makeGatewayCheck(result: statusResult, snapshot: snapshot)
        let telegramCheck = await makeTelegramCheck(snapshot: snapshot)
        let availability = await probeHermesAvailability(on: connection)
        publishHermesAvailability(availability)
        let hermesCheck = makeHermesCheck(availability: availability)
        // Order: gateway (primary health), Hermes version (often the
        // explanation when gateway misbehaves), telegram (downstream).
        checks = [gatewayCheck, hermesCheck, telegramCheck]
        lastRefreshedAt = Date()
    }

    // MARK: - Actions

    func runAction(_ action: Action) async {
        guard actionInFlight == nil else { return }
        guard let connection = currentConnection else {
            actionError = L10n.string("No host selected.")
            return
        }
        actionInFlight = action
        actionError = nil
        defer { actionInFlight = nil }

        switch action {
        case .restartGateway:
            await restartGateway(on: connection)
        case .revalidateTelegram:
            await revalidateTelegramToken()
        case .updateHermes:
            await performHermesUpdateBridge()
        }
        // Always refresh after an action so the user sees the new state.
        await refresh()
    }

    private func restartGateway(on connection: ConnectionProfile) async {
        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            actionError = L10n.string("No Telegram token configured. Paste one on the Messaging tab first.")
            return
        }
        do {
            let result = try await telegramInstaller.install(
                on: connection,
                token: token,
                allowedUsers: nil
            )
            if !result.success {
                actionError = result.errors.isEmpty
                    ? L10n.string("Restart failed.")
                    : result.errors.joined(separator: "\n")
            }
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func revalidateTelegramToken() async {
        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            actionError = L10n.string("No Telegram token configured. Paste one on the Messaging tab first.")
            return
        }
        do {
            _ = try await telegramAPI.getMe(token: token)
        } catch let error as TelegramAPIError {
            actionError = error.errorDescription
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Check builders

    private func makeGatewayCheck(
        result: TelegramVMResult,
        snapshot: GatewayStateSnapshot?
    ) -> Check {
        let logTail = result.gateway_log_tail
        let actions: [Action] = [.restartGateway]

        // Prefer the live state file when present — it's the most
        // accurate signal. Fall back to the text-based status output.
        if let snapshot {
            if snapshot.isRunning {
                let connected = snapshot.allPlatformsConnected
                if connected == true {
                    let count = snapshot.platforms?.count ?? 0
                    return Check(
                        id: "gateway",
                        title: L10n.string("Hermes gateway"),
                        severity: .ok,
                        summary: L10n.string(count == 1
                            ? "Running, 1 platform connected."
                            : "Running, all platforms connected."),
                        detail: logTail,
                        actions: actions
                    )
                }
                // Running but at least one platform isn't connected.
                let problems = (snapshot.platforms ?? [:])
                    .filter { !$0.value.isConnected }
                    .map { "\($0.key): \($0.value.state ?? "unknown")\($0.value.error_message.map { " (\($0))" } ?? "")" }
                    .sorted()
                return Check(
                    id: "gateway",
                    title: L10n.string("Hermes gateway"),
                    severity: .warn,
                    summary: L10n.string("Running, but some platforms aren't connected."),
                    detail: problems.joined(separator: "\n") + (logTail.map { "\n\n\($0)" } ?? ""),
                    actions: actions
                )
            }
            // Snapshot present but not running.
            return Check(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                severity: .error,
                summary: L10n.string("Not running.") + " " + L10n.string("Click Restart gateway to bring it up."),
                detail: logTail,
                actions: actions
            )
        }

        // No snapshot → fall back to text-based status.
        if result.isGatewayOnline {
            return Check(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                severity: .ok,
                summary: L10n.string("Running."),
                detail: logTail,
                actions: actions
            )
        }
        if let status = result.gateway_status, !status.isEmpty {
            return Check(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                severity: .error,
                summary: L10n.string("Not running.") + " " + L10n.string("Click Restart gateway to bring it up."),
                detail: [status, logTail].compactMap { $0 }.joined(separator: "\n\n"),
                actions: actions
            )
        }
        return Check(
            id: "gateway",
            title: L10n.string("Hermes gateway"),
            severity: .unknown,
            summary: L10n.string("Couldn't determine gateway state."),
            detail: logTail,
            actions: actions
        )
    }

    private func makeTelegramCheck(snapshot: GatewayStateSnapshot?) async -> Check {
        let actions: [Action] = [.revalidateTelegram]

        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            return Check(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                severity: .warn,
                summary: L10n.string("No token configured."),
                detail: L10n.string("Paste a bot token on the Messaging tab to enable Telegram."),
                actions: []
            )
        }

        // Validate the token against api.telegram.org. This is the
        // ground truth for "is the token still good."
        let bot: TelegramBotInfo
        do {
            bot = try await telegramAPI.getMe(token: token)
        } catch let error as TelegramAPIError {
            // 401-style rejection → token-revoked path.
            switch error {
            case .invalidToken, .revokedToken:
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .error,
                    summary: L10n.string("Token rejected by Telegram."),
                    detail: L10n.string("Regenerate via BotFather and paste the new token on the Messaging tab.") +
                        "\n\n" + (error.errorDescription ?? ""),
                    actions: actions
                )
            default:
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .warn,
                    summary: L10n.string("Couldn't reach api.telegram.org."),
                    detail: error.errorDescription,
                    actions: actions
                )
            }
        } catch {
            return Check(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                severity: .warn,
                summary: L10n.string("Couldn't reach api.telegram.org."),
                detail: error.localizedDescription,
                actions: actions
            )
        }

        // Token validates. Now reconcile with what the gateway thinks.
        let gatewayPlatform = snapshot?.platform("telegram")
        let summaryOk = bot.displayHandle

        if let platform = gatewayPlatform {
            if platform.isConnected {
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .ok,
                    summary: summaryOk + " " + L10n.string("is online."),
                    detail: nil,
                    actions: actions
                )
            }
            if platform.isConnecting {
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .warn,
                    summary: L10n.string("Token valid; gateway is still connecting."),
                    detail: platform.error_message,
                    actions: actions
                )
            }
            return Check(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                severity: .warn,
                summary: L10n.string("Token valid; gateway can't connect."),
                detail: platform.error_message ?? L10n.string("State: ") + (platform.state ?? "unknown"),
                actions: actions
            )
        }

        // Token valid but no gateway snapshot — gateway probably down.
        return Check(
            id: "telegram",
            title: L10n.string("Telegram bot"),
            severity: .warn,
            summary: L10n.string("Token valid; gateway not running."),
            detail: L10n.string("Click Restart gateway above to bring it online."),
            actions: actions
        )
    }

    private func probeHermesAvailability(on connection: ConnectionProfile) async -> HermesUpdateAvailability {
        do {
            let result = try await hermesUpdater.checkAvailability(on: connection)
            if !result.installed { return .notInstalled }
            let label = result.version_label ?? L10n.string("Hermes Agent")
            switch result.behind {
            case .some(0):
                return .upToDate(versionLabel: label)
            case .some(let n) where n > 0:
                return .behind(versionLabel: label, commits: n)
            case .some(-1):
                return .behind(versionLabel: label, commits: nil)
            default:
                // Probe couldn't determine — don't nag the user.
                return .upToDate(versionLabel: label)
            }
        } catch {
            return .unknown
        }
    }

    private func makeHermesCheck(availability: HermesUpdateAvailability) -> Check {
        switch availability {
        case .unknown:
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .unknown,
                summary: L10n.string("Couldn't determine version."),
                detail: nil,
                actions: []
            )
        case .notInstalled:
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .warn,
                summary: L10n.string("Hermes isn't installed on this host."),
                detail: L10n.string("Install Hermes Agent from the Overview tab first."),
                actions: []
            )
        case .upToDate(let versionLabel):
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .ok,
                summary: versionLabel,
                detail: L10n.string("Up to date with origin/main."),
                actions: [.updateHermes]
            )
        case .behind(let versionLabel, let commits):
            let summary: String
            if let commits, commits > 0 {
                summary = String(
                    format: L10n.string(commits == 1
                        ? "%@ — %d commit behind main."
                        : "%@ — %d commits behind main."),
                    versionLabel,
                    commits
                )
            } else {
                summary = String(
                    format: L10n.string("%@ — update available."),
                    versionLabel
                )
            }
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .warn,
                summary: summary,
                detail: L10n.string("Click Update to run hermes update --backup. The gateway restarts automatically."),
                actions: [.updateHermes]
            )
        }
    }
}
