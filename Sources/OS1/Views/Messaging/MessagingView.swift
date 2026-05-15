import AppKit
import SwiftUI

/// Messaging tab — quick-connect for Telegram (and future platforms).
/// Two screens:
///   - `.unconfigured`: paste BotFather token; auto-detect existing
///     install on the active host
///   - `.configured`: bot identity card + per-host install state +
///     pairing code approval
struct MessagingView: View {
    @ObservedObject var viewModel: MessagingViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        Group {
            switch viewModel.step {
            case .loading:      loadingView
            case .unconfigured: unconfiguredView
            case .configured:   configuredView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.coral)
        .onAppear {
            viewModel.setActiveProfile(appState.activeConnection?.id.uuidString)
        }
        .onChange(of: appState.activeConnection?.id) { _, newId in
            viewModel.setActiveProfile(newId?.uuidString)
        }
        .task(id: scanTaskKey) {
            // Auto-detect existing Telegram install on the active host
            // when we land in unconfigured state. Manual "Detect" button
            // covers retries.
            if viewModel.step == .unconfigured,
               let connection = appState.activeConnection {
                await viewModel.scanForVMToken(connection: connection)
            }
        }
        .task(id: installTaskKey) {
            // Re-evaluate gateway install/online status whenever we
            // land on the configured screen for a (potentially new)
            // connection.
            if viewModel.step == .configured,
               let connection = appState.activeConnection {
                await viewModel.checkInstallStatus(on: connection)
            }
        }
    }

    private var scanTaskKey: String {
        "\(appState.activeConnection?.id.uuidString ?? "none")-\(viewModel.step == .unconfigured ? "uncfg" : "cfg")"
    }

    private var installTaskKey: String {
        "\(appState.activeConnection?.id.uuidString ?? "none")-\(viewModel.step == .configured ? "cfg" : "other")"
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(theme.palette.onCoralPrimary)
            Text(L10n.string("Checking messaging setup…"))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Unconfigured

    private var unconfiguredView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: L10n.string("Messaging"),
                    subtitle: L10n.string("Chat with your agent from anywhere via Telegram. Paste a bot token from @BotFather and OS1 wires up the Hermes gateway on the active host. The agent sees your messages within seconds — no public URL or webhook required (long-polling).")
                )

                if case .found(_, let host) = viewModel.lastScanResult {
                    discoveredTokenBanner(hostLabel: host)
                }

                if let connection = appState.activeConnection,
                   case .found = viewModel.lastScanResult {} else if let connection = appState.activeConnection {
                    detectFromHostPanel(connection: connection)
                }

                quickStartBanner

                HermesSurfacePanel(
                    title: L10n.string("Bot token"),
                    subtitle: L10n.string("Stored in macOS Keychain — never written to disk. Get it from @BotFather: send /newbot, choose a name, copy the token.")
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        EditorField(label: L10n.string("BotFather token")) {
                            VStack(alignment: .leading, spacing: 4) {
                                SecureField(L10n.string("123456789:ABCdefGHIjklMNOpqrSTUvwxYZ"), text: $viewModel.tokenDraft)
                                    .os1Underlined()
                                    .disabled(viewModel.isBusy)
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(theme.palette.onCoralMuted)
                                    Button(L10n.string("Open BotFather in Telegram")) {
                                        if let url = URL(string: "https://t.me/BotFather") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralSecondary)
                                }
                            }
                        }

                        if let error = viewModel.formError {
                            errorBanner(error)
                        }

                        HStack(spacing: 10) {
                            Spacer()
                            Button(L10n.string("Validate & save")) {
                                Task { await viewModel.saveToken() }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(viewModel.isBusy || viewModel.tokenDraft.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var quickStartBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Three steps, ~30 seconds"))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("1. In Telegram, message @BotFather → /newbot → copy the token. 2. Paste it below; OS1 validates it against api.telegram.org. 3. After saving, OS1 writes it to the active host's ~/.hermes/.env and starts the gateway. DM your bot to register yourself with a pairing code — no need to look up your numeric Telegram ID."))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    private func detectFromHostPanel(connection: ConnectionProfile) -> some View {
        let hostLabel = connection.label.isEmpty ? L10n.string("active host") : connection.label
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Telegram already on %@?", hostLabel))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(detectSubtitle(hostLabel: hostLabel))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.scanForVMToken(connection: connection) }
            } label: {
                if viewModel.isScanningForToken {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string("Scanning…"))
                    }
                } else {
                    Text(L10n.string("Detect"))
                }
            }
            .buttonStyle(.os1Secondary)
            .disabled(viewModel.isScanningForToken)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.glassFill.opacity(0.5))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    private func detectSubtitle(hostLabel: String) -> String {
        switch viewModel.lastScanResult {
        case .notRun:
            return L10n.string("Pull an existing bot token from this host's ~/.hermes/.env.")
        case .found:
            return L10n.string("Found a token on %@.", hostLabel)
        case .notFound:
            return L10n.string("No Telegram setup detected on %@.", hostLabel)
        case .failed(let message):
            return L10n.string("Couldn't scan %@: %@", hostLabel, message)
        }
    }

    private func discoveredTokenBanner(hostLabel: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Detected Telegram on %@", hostLabel))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("This host already has a bot token configured. Import it so OS1 can manage the same bot."))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = viewModel.formError {
                    errorBanner(error)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.importDiscoveredToken() }
                    } label: {
                        if viewModel.isBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                                Text(L10n.string("Validating…"))
                            }
                        } else {
                            Text(L10n.string("Import token"))
                        }
                    }
                    .buttonStyle(.os1Primary)
                    .disabled(viewModel.isBusy)

                    Button(L10n.string("Paste my own instead")) {
                        viewModel.dismissDiscoveredToken()
                    }
                    .buttonStyle(.os1Secondary)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    // MARK: - Configured

    private var configuredView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: L10n.string("Messaging"),
                    subtitle: L10n.string("Telegram is wired up. Install on each host where the agent should respond — long-polling means no public URL needed.")
                )

                botIdentityCard

                vmInstallPanel

                pairingPanel
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var botIdentityCard: some View {
        HermesSurfacePanel(title: L10n.string("Bot")) {
            VStack(alignment: .leading, spacing: 12) {
                if let bot = viewModel.validatedBot {
                    HermesLabeledValue(label: L10n.string("Display name"), value: bot.first_name ?? "—")
                    HermesLabeledValue(label: L10n.string("Username"), value: bot.displayHandle)
                    if let canJoinGroups = bot.can_join_groups {
                        HermesLabeledValue(
                            label: L10n.string("Group support"),
                            value: canJoinGroups
                                ? L10n.string("Can join groups")
                                : L10n.string("DM only — enable groups via @BotFather")
                        )
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string("Validating bot identity…"))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.string("Disconnect")) {
                        Task { await viewModel.disconnect(connection: appState.activeConnection) }
                    }
                    .buttonStyle(.os1Secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var vmInstallPanel: some View {
        if let connection = appState.activeConnection {
            HermesSurfacePanel(
                title: L10n.string("Install on this host"),
                subtitle: L10n.string("Writes TELEGRAM_BOT_TOKEN to ~/.hermes/.env on %@ and runs `hermes gateway start` so the agent picks up Telegram messages right away.", connection.label.isEmpty ? L10n.string("active host") : connection.label)
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $viewModel.useDMPairing) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string("DM Pairing"))
                                .os1Style(theme.typography.body)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                            Text(L10n.string("Recommended. After install, DM your bot — it replies with a one-time pairing code that you approve below."))
                                .os1Style(theme.typography.smallCaps)
                                .foregroundStyle(theme.palette.onCoralMuted)
                        }
                    }
                    .tint(theme.palette.onCoralPrimary)

                    if !viewModel.useDMPairing {
                        EditorField(label: L10n.string("Allowed Telegram user IDs (comma-separated)")) {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(L10n.string("123456789, 987654321"), text: $viewModel.allowedUsersDraft)
                                    .os1Underlined()
                                Text(L10n.string("Get yours by messaging @userinfobot in Telegram."))
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralMuted)
                            }
                        }
                    }

                    installStatusRow

                    if let error = viewModel.installError {
                        errorBanner(error)
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.installOnVM(connection: connection) }
                        } label: {
                            if isInstallBusy {
                                ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                            } else {
                                Text(installButtonLabel)
                            }
                        }
                        .buttonStyle(.os1Primary)
                        .disabled(isInstallBusy)
                    }
                }
            }
        } else {
            HermesSurfacePanel(
                title: L10n.string("Install on a host"),
                subtitle: L10n.string("Connect to a Hermes-equipped host first — installing here writes ~/.hermes/.env and starts the gateway on that VM/Mac/VPS.")
            ) {
                Text(L10n.string("No connection selected."))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
            }
        }
    }

    private var installStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: installStatusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
                .frame(width: 18)
            Text(installStatusText)
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Spacer()
        }
    }

    private var installStatusIcon: String {
        switch viewModel.installState {
        case .unknown, .checking, .installing: return "circle.dotted"
        case .notInstalled:                    return "circle"
        case .installed(let online):           return online ? "checkmark.circle.fill" : "checkmark.circle"
        case .failed:                          return "exclamationmark.octagon.fill"
        }
    }

    private var installStatusText: String {
        switch viewModel.installState {
        case .unknown:        return L10n.string("Status unknown")
        case .checking:       return L10n.string("Checking host…")
        case .notInstalled:   return L10n.string("Not installed on this host")
        case .installing:     return L10n.string("Installing on host…")
        case .installed(let online):
            return online
                ? L10n.string("Gateway online — messages flowing")
                : L10n.string("Configured — gateway not yet online")
        case .failed:         return L10n.string("Install failed")
        }
    }

    private var installButtonLabel: String {
        switch viewModel.installState {
        case .installed:
            return L10n.string("Reinstall / refresh")
        case .failed:
            return L10n.string("Retry install")
        default:
            return L10n.string("Install on host")
        }
    }

    private var isInstallBusy: Bool {
        switch viewModel.installState {
        case .checking, .installing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var pairingPanel: some View {
        if let connection = appState.activeConnection,
           viewModel.useDMPairing,
           case .installed = viewModel.installState {
            HermesSurfacePanel(
                title: L10n.string("Approve pairing code"),
                subtitle: L10n.string("DM your new bot from Telegram. It replies with a one-time code like XKGH5N7P. Paste it here to whitelist that user — no numeric IDs required.")
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    EditorField(label: L10n.string("Pairing code")) {
                        TextField(L10n.string("XKGH5N7P"), text: $viewModel.pairingCode)
                            .os1Underlined()
                            .textCase(.uppercase)
                    }

                    if let message = viewModel.pairingActionMessage {
                        Text(message)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.approvePairingCode(connection: connection) }
                        } label: {
                            Text(L10n.string("Approve"))
                        }
                        .buttonStyle(.os1Primary)
                        .disabled(viewModel.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .os1Style(theme.typography.body)
            .foregroundStyle(theme.palette.onCoralPrimary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
