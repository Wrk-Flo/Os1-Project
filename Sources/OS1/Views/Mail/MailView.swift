import SwiftUI

/// Mail tab — entry point for AgentMail integration. Handles two stages:
///
/// 1. **Auth setup** (this checkpoint): create or paste an API key,
///    persist it in macOS Keychain.
/// 2. **VM-side install** (next checkpoint): clone the AgentMail skill +
///    register the MCP server on the active Hermes profile.
///
/// All UI state is driven by `MailSetupViewModel`'s `step` enum, so
/// every transition is an explicit case.
struct MailView: View {
    @ObservedObject var viewModel: MailSetupViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        Group {
            switch viewModel.step {
            case .loading:
                loadingView
            case .unconfigured:
                entryView
            case .signupForm:
                signupFormView
            case .awaitingOTP:
                otpView
            case .byokForm(let reason):
                byokView(reason: reason)
            case .inboxPicker(_, let inboxes):
                inboxPickerView(inboxes: inboxes)
            case .configured(let account):
                configuredView(account: account)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.coral)
        .onAppear { viewModel.refreshFromStorage() }
        .onChange(of: appState.activeConnection?.id) { _, newId in
            // Auto-swap AgentMail account context whenever the user
            // selects a different host. Each inbox stays associated with
            // the connection that configured it.
            viewModel.setActiveProfile(newId?.uuidString)
        }
        .task {
            viewModel.setActiveProfile(appState.activeConnection?.id.uuidString)
        }
        .task(id: scanTaskKey) {
            // When we land on the Mail tab unconfigured AND there's an
            // active host, auto-scan its config.yaml for an existing
            // AgentMail key. Manual `Detect` button covers retries.
            if shouldAutoScan, let connection = appState.activeConnection {
                await viewModel.scanForVMKey(connection: connection)
            }
        }
    }

    /// Re-runs the AgentMail VM scan whenever the active connection
    /// changes or the user navigates between unconfigured and
    /// configured states.
    private var scanTaskKey: String {
        let connectionId = appState.activeConnection?.id.uuidString ?? "none"
        let stepTag: String
        switch viewModel.step {
        case .loading:                stepTag = "loading"
        case .unconfigured:           stepTag = "unconfigured"
        case .signupForm:             stepTag = "signup"
        case .awaitingOTP:            stepTag = "otp"
        case .byokForm:               stepTag = "byok"
        case .inboxPicker:            stepTag = "picker"
        case .configured:             stepTag = "configured"
        }
        return "\(connectionId)-\(stepTag)"
    }

    private var shouldAutoScan: Bool {
        switch viewModel.step {
        case .unconfigured, .byokForm:
            return true
        default:
            return false
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(theme.palette.onCoralPrimary)
            Text(L10n.string("Checking AgentMail setup…"))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entry

    private var entryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: L10n.string("AgentMail"),
                    subtitle: L10n.string("Give your Hermes agent a real email inbox so it can send, receive, and act on email. Free tier: 3 inboxes and 3,000 emails per month, no credit card.")
                )

                if let discovered = viewModel.discoveredVMKey {
                    discoveredKeyBanner(discovered)
                }

                if let connection = appState.activeConnection,
                   viewModel.discoveredVMKey == nil {
                    detectFromHostPanel(connection: connection)
                }

                HermesSurfacePanel(
                    title: "Set up your inbox",
                    subtitle: "Most users start fresh — AgentMail signs you up automatically. If you already have an account at console.agentmail.to, paste your existing API key instead."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        entryButton(
                            title: "Create an inbox for this agent",
                            subtitle: "We'll sign you up using your email and send a one-time code to verify.",
                            systemImage: "envelope.badge",
                            primary: true
                        ) { viewModel.chooseSignUp() }

                        entryButton(
                            title: "I already have an AgentMail key",
                            subtitle: "Paste an existing key from console.agentmail.to.",
                            systemImage: "key",
                            primary: false
                        ) { viewModel.chooseBYOK() }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func entryButton(
        title: String,
        subtitle: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(title))
                        .os1Style(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.palette.onCoralPrimary)

                    Text(L10n.string(subtitle))
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(primary ? theme.palette.glassFill : theme.palette.glassFill.opacity(0.5))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - VM key detection (entry / BYOK shared)

    private func detectFromHostPanel(connection: ConnectionProfile) -> some View {
        let hostLabel = connection.label.isEmpty ? L10n.string("active host") : connection.label
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("AgentMail already on %@?", hostLabel))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(detectFromHostSubtitle(hostLabel: hostLabel))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.scanForVMKey(connection: connection) }
            } label: {
                if viewModel.isScanningForVMKey {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string("Scanning…"))
                    }
                } else {
                    Text(L10n.string("Detect"))
                }
            }
            .buttonStyle(.os1Secondary)
            .disabled(viewModel.isScanningForVMKey)
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

    private func detectFromHostSubtitle(hostLabel: String) -> String {
        switch viewModel.lastScanResult {
        case .notRun:
            return L10n.string("Pull an existing AgentMail key from this host's ~/.hermes/config.yaml.")
        case .found:
            return L10n.string("Found a key on %@.", hostLabel)
        case .notFound:
            return L10n.string("No AgentMail install detected on %@.", hostLabel)
        case .failed(let message):
            return L10n.string("Couldn't scan %@: %@", hostLabel, message)
        }
    }

    private func discoveredKeyBanner(_ discovered: MailSetupViewModel.DiscoveredKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Detected AgentMail on %@", discovered.connectionLabel))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("This host already has an AgentMail key configured. Import it so OS1 can manage your inbox with the same credential."))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(L10n.string("Import key")) {
                        viewModel.importDiscoveredKey()
                    }
                    .buttonStyle(.os1Primary)

                    Button(L10n.string("Set up manually instead")) {
                        viewModel.dismissDiscoveredKey()
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

    // MARK: - Sign-up form

    private var signupFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Create AgentMail inbox",
                    subtitle: "We'll register a new AgentMail account using your email. You'll get a 6-digit code to verify on the next step."
                )

                HermesSurfacePanel(title: "Your details") {
                    VStack(alignment: .leading, spacing: 14) {
                        EditorField(label: "Your email") {
                            TextField(L10n.string("you@example.com"), text: $viewModel.signupEmail)
                                .textContentType(.emailAddress)
                                .os1Underlined()
                                .disabled(viewModel.isBusy)
                        }

                        EditorField(label: "Agent username") {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(L10n.string("my-agent"), text: $viewModel.signupUsername)
                                    .os1Underlined()
                                    .disabled(viewModel.isBusy)
                                Text(L10n.string("Your inbox will be %@@agentmail.to.", viewModel.signupUsername.isEmpty ? "<username>" : viewModel.signupUsername))
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralMuted)
                            }
                        }

                        if let error = viewModel.formError {
                            Text(error)
                                .os1Style(theme.typography.body)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }

                        HStack(spacing: 10) {
                            Button(L10n.string("Back")) { viewModel.backToEntry() }
                                .buttonStyle(.os1Secondary)
                                .disabled(viewModel.isBusy)
                            Spacer()
                            Button {
                                Task { await viewModel.submitSignUp() }
                            } label: {
                                if viewModel.isBusy {
                                    ProgressView().controlSize(.small)
                                        .tint(theme.palette.onCoralPrimary)
                                } else {
                                    Text(L10n.string("Send code"))
                                }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(viewModel.isBusy || viewModel.signupEmail.isEmpty || viewModel.signupUsername.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    // MARK: - OTP

    @ViewBuilder
    private var otpView: some View {
        if case .awaitingOTP(let pending) = viewModel.step {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HermesPageHeader(
                        title: "Verify your email",
                        subtitle: "We sent a 6-digit code to \(pending.humanEmail). Enter it below to finish setup."
                    )

                    HermesSurfacePanel(title: "Verification code") {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField(L10n.string("123456"), text: $viewModel.otpCode)
                                .textContentType(.oneTimeCode)
                                .font(.system(.title2, design: .monospaced).weight(.semibold))
                                .os1Underlined()
                                .disabled(viewModel.isBusy)

                            if let error = viewModel.formError {
                                Text(error)
                                    .os1Style(theme.typography.body)
                                    .foregroundStyle(theme.palette.onCoralPrimary)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }

                            HStack(spacing: 10) {
                                Button(L10n.string("Resend code")) { Task { await viewModel.resendOTP() } }
                                    .buttonStyle(.os1Secondary)
                                    .disabled(viewModel.isBusy)
                                Spacer()
                                Button {
                                    Task { await viewModel.submitVerifyOTP() }
                                } label: {
                                    if viewModel.isBusy {
                                        ProgressView().controlSize(.small)
                                            .tint(theme.palette.onCoralPrimary)
                                    } else {
                                        Text(L10n.string("Verify"))
                                    }
                                }
                                .buttonStyle(.os1Primary)
                                .disabled(viewModel.isBusy || viewModel.otpCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    // MARK: - BYOK

    private func byokView(reason: MailSetupViewModel.BYOKReason) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Use existing AgentMail key",
                    subtitle: byokSubtitle(reason: reason)
                )

                if reason == .emailAlreadyRegistered {
                    alreadyRegisteredBanner
                }

                if let discovered = viewModel.discoveredVMKey {
                    discoveredKeyBanner(discovered)
                }

                if let connection = appState.activeConnection,
                   viewModel.discoveredVMKey == nil {
                    detectFromHostPanel(connection: connection)
                }

                HermesSurfacePanel(title: "API key") {
                    VStack(alignment: .leading, spacing: 14) {
                        EditorField(label: "Paste API key") {
                            VStack(alignment: .leading, spacing: 4) {
                                SecureField(L10n.string("am_us_..."), text: $viewModel.byokKey)
                                    .os1Underlined()
                                    .disabled(viewModel.isBusy)
                                Text(L10n.string("Generate a key at console.agentmail.to → Settings → API keys."))
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralMuted)
                            }
                        }

                        if let error = viewModel.formError {
                            Text(error)
                                .os1Style(theme.typography.body)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }

                        HStack(spacing: 10) {
                            Button(L10n.string("Back")) { viewModel.backToEntry() }
                                .buttonStyle(.os1Secondary)
                                .disabled(viewModel.isBusy)
                            Spacer()
                            Button {
                                Task { await viewModel.submitBYOK() }
                            } label: {
                                if viewModel.isBusy {
                                    ProgressView().controlSize(.small)
                                        .tint(theme.palette.onCoralPrimary)
                                } else {
                                    Text(L10n.string("Save key"))
                                }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(viewModel.isBusy || viewModel.byokKey.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func byokSubtitle(reason: MailSetupViewModel.BYOKReason) -> String {
        switch reason {
        case .userChose:
            return L10n.string("Paste an API key from your existing AgentMail account.")
        case .emailAlreadyRegistered:
            return L10n.string("Looks like you already have an AgentMail account.")
        }
    }

    private var alreadyRegisteredBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.onCoralPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("This email already has an AgentMail account"))
                        .os1Style(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text(L10n.string("AgentMail's automatic sign-up only works for first-time users. To continue, sign in to console.agentmail.to with that email, generate an API key under Settings → API keys, and paste it below."))
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    // MARK: - Inbox picker

    private func inboxPickerView(inboxes: [AgentMailInboxSummary]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Pick an inbox",
                    subtitle: inboxes.isEmpty
                        ? L10n.string("No inboxes on this account yet — create one for the agent.")
                        : L10n.string("Your AgentMail account has %@. Pick the one this Mac should use, or create a new one.", inboxes.count == 1 ? L10n.string("1 inbox") : L10n.string("%@ inboxes", "\(inboxes.count)"))
                )

                if !inboxes.isEmpty {
                    HermesSurfacePanel(title: "Use existing inbox") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(inboxes) { inbox in
                                Button {
                                    viewModel.selectInbox(inbox)
                                } label: {
                                    HStack(alignment: .center, spacing: 10) {
                                        Image(systemName: "envelope.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(theme.palette.onCoralPrimary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(inbox.inbox_id)
                                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                                .foregroundStyle(theme.palette.onCoralPrimary)
                                            if let displayName = inbox.display_name, !displayName.isEmpty {
                                                Text(displayName)
                                                    .os1Style(theme.typography.smallCaps)
                                                    .foregroundStyle(theme.palette.onCoralSecondary)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(theme.palette.onCoralMuted)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(theme.palette.glassFill.opacity(0.5))
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.isBusy)
                            }
                        }
                    }
                }

                HermesSurfacePanel(
                    title: inboxes.isEmpty ? "Create your first inbox" : "Or create a new one",
                    subtitle: inboxes.isEmpty ? nil : "Free tier supports up to 3 inboxes per account."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        EditorField(label: "Username") {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(L10n.string("nick-agent"), text: $viewModel.newInboxUsername)
                                    .os1Underlined()
                                    .disabled(viewModel.isBusy)
                                Text(L10n.string("New inbox: %@@agentmail.to", viewModel.newInboxUsername.isEmpty ? "<username>" : viewModel.newInboxUsername))
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralMuted)
                            }
                        }

                        if let error = viewModel.formError {
                            Text(error)
                                .os1Style(theme.typography.body)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }

                        HStack(spacing: 10) {
                            Button(L10n.string("Back")) { viewModel.backFromInboxPicker() }
                                .buttonStyle(.os1Secondary)
                                .disabled(viewModel.isBusy)
                            Spacer()
                            Button {
                                Task { await viewModel.createInboxAndUse() }
                            } label: {
                                if viewModel.isBusy {
                                    ProgressView().controlSize(.small)
                                        .tint(theme.palette.onCoralPrimary)
                                } else {
                                    Text(L10n.string("Create and use"))
                                }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(viewModel.isBusy || viewModel.newInboxUsername.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    // MARK: - Configured

    @ViewBuilder
    private func configuredView(account: AgentMailAccount) -> some View {
        ConfiguredMailView(
            account: account,
            inboxViewModel: appState.mailInboxViewModel,
            onDisconnect: { viewModel.reset() }
        )
    }
}

/// Two-pane configured-state mail browser. Folder list on the left,
/// message list on the right (with detail to come in D.1.3).
private struct ConfiguredMailView: View {
    let account: AgentMailAccount
    @ObservedObject var inboxViewModel: MailInboxViewModel
    let onDisconnect: () -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        // Nested OS1HSplitView so all three dividers use the warm-tan
        // chrome instead of macOS's default charcoal hairline.
        OS1HSplitView {
            folderPane
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
        } detail: {
            OS1HSplitView {
                messageListPane
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            } detail: {
                messageDetailPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
        .background(theme.palette.coral)
        .onAppear {
            inboxViewModel.setActiveProfile(appState.activeConnection?.id.uuidString)
            if inboxViewModel.inboxesLoadState == .idle {
                inboxViewModel.loadInboxes()
            }
            if inboxViewModel.loadState == .idle {
                inboxViewModel.refresh()
            }
            inboxViewModel.startLive()
        }
        .onDisappear {
            inboxViewModel.stopLive()
        }
        .onChange(of: appState.activeConnection?.id) { _, newId in
            inboxViewModel.setActiveProfile(newId?.uuidString)
            inboxViewModel.loadInboxes()
            inboxViewModel.refresh()
            inboxViewModel.startLive()
        }
        .sheet(item: $inboxViewModel.composeContext) { context in
            MailComposeSheet(viewModel: inboxViewModel, context: context)
        }
    }

    // MARK: - Folder pane

    private var folderPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("AgentMail"))
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)

                inboxSwitcher
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(MailInboxViewModel.Folder.allCases) { folder in
                    folderRow(folder)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            Divider().background(theme.palette.onCoralMuted.opacity(0.18))

            HStack {
                Button(L10n.string("Disconnect")) { onDisconnect() }
                    .buttonStyle(.os1Secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.palette.coral)
    }

    private var inboxSwitcher: some View {
        let active = inboxViewModel.selectedInboxId ?? account.primaryInboxId
        let inboxes = inboxViewModel.availableInboxes
        let activeInbox = inboxes.first(where: { $0.inbox_id == active })
        let displayLabel = activeInbox.flatMap { $0.display_name?.isEmpty == false ? $0.display_name : $0.inbox_id }
            ?? active

        let options: [OS1DropdownMenu.Option] = inboxes.map { inbox in
            OS1DropdownMenu.Option(
                id: inbox.inbox_id,
                label: inbox.display_name?.isEmpty == false ? "\(inbox.display_name!) — \(inbox.inbox_id)" : inbox.inbox_id,
                isSelected: inbox.inbox_id == active
            ) { [weak inboxViewModel] in
                inboxViewModel?.selectInbox(inbox.inbox_id)
            }
        }

        return OS1DropdownMenu(
            selectedLabel: displayLabel,
            placeholder: L10n.string("Pick an inbox"),
            isDisabled: inboxes.isEmpty || inboxViewModel.inboxesLoadState == .loading,
            options: options
        )
    }

    private func folderRow(_ folder: MailInboxViewModel.Folder) -> some View {
        let isSelected = inboxViewModel.selectedFolder == folder
        return Button {
            inboxViewModel.selectFolder(folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: folder.systemImage)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18)
                Text(L10n.string(folder.title))
                    .os1Style(theme.typography.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected
                             ? theme.palette.onCoralPrimary
                             : theme.palette.onCoralSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.palette.glassFill : Color.clear)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message list pane

    private var messageListPane: some View {
        VStack(spacing: 0) {
            messageListHeader

            searchBar

            Divider().background(theme.palette.onCoralMuted.opacity(0.18))

            messageListContent
        }
        .background(theme.palette.coral)
    }

    /// Tiny pill that signals the AgentMail WebSocket is alive and
    /// new mail will land without a manual refresh. Stays subtle —
    /// not a toast, not interactive.
    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(theme.palette.onCoralPrimary)
                .frame(width: 6, height: 6)
            Text(L10n.string("Live"))
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralMuted)
        }
        .help(L10n.string("Subscribed to AgentMail real-time events. New mail appears automatically."))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralMuted)
            TextField(L10n.string("Search subject, sender, or text"), text: $inboxViewModel.searchQuery)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.palette.onCoralPrimary)
            if !inboxViewModel.searchQuery.isEmpty {
                Button {
                    inboxViewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.palette.glassFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var messageListHeader: some View {
        HStack(spacing: 10) {
            Text(L10n.string(inboxViewModel.selectedFolder.title))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)

            if case .loaded = inboxViewModel.loadState {
                Text(L10n.string("%@ messages", "\(inboxViewModel.messages.count)"))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            if inboxViewModel.isLiveConnected {
                liveIndicator
            }

            Spacer()

            Button {
                inboxViewModel.startCompose()
            } label: {
                Label(L10n.string("Compose"), systemImage: "square.and.pencil")
            }
            .buttonStyle(.os1Primary)
            .help(L10n.string("Compose a new message"))

            Button {
                inboxViewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.os1Icon)
            .help(L10n.string("Refresh"))
            .disabled(inboxViewModel.loadState == .loading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var messageListContent: some View {
        if inboxViewModel.selectedFolder == .drafts {
            draftListContent
        } else {
            regularMessageListContent
        }
    }

    @ViewBuilder
    private var regularMessageListContent: some View {
        let visible = inboxViewModel.filteredMessages

        switch inboxViewModel.loadState {
        case .idle:
            HermesLoadingState(label: "Loading inbox…", minHeight: 200)
        case .loading where inboxViewModel.messages.isEmpty:
            HermesLoadingState(label: "Loading inbox…", minHeight: 200)
        case .failed(let message) where inboxViewModel.messages.isEmpty:
            ContentUnavailableView(
                L10n.string("Couldn't load messages"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where inboxViewModel.messages.isEmpty:
            ContentUnavailableView(
                L10n.string("No messages in %@", inboxViewModel.selectedFolder.title),
                systemImage: "tray",
                description: Text(L10n.string("Messages sent or received from this inbox will appear here."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if visible.isEmpty && !inboxViewModel.searchQuery.isEmpty {
                ContentUnavailableView(
                    L10n.string("No matches"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("No messages match \"%@\".", inboxViewModel.searchQuery))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { message in
                            messageRow(message)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    @ViewBuilder
    private var draftListContent: some View {
        let visible = inboxViewModel.filteredDrafts

        switch inboxViewModel.loadState {
        case .idle:
            HermesLoadingState(label: "Loading drafts…", minHeight: 200)
        case .loading where inboxViewModel.drafts.isEmpty:
            HermesLoadingState(label: "Loading drafts…", minHeight: 200)
        case .failed(let message) where inboxViewModel.drafts.isEmpty:
            ContentUnavailableView(
                L10n.string("Couldn't load drafts"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where inboxViewModel.drafts.isEmpty:
            ContentUnavailableView(
                L10n.string("No drafts"),
                systemImage: "doc",
                description: Text(L10n.string("Saved or scheduled drafts in this inbox will appear here."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if visible.isEmpty && !inboxViewModel.searchQuery.isEmpty {
                ContentUnavailableView(
                    L10n.string("No matches"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("No drafts match \"%@\".", inboxViewModel.searchQuery))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { draft in
                            draftRow(draft)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func draftRow(_ draft: AgentMailDraftSummary) -> some View {
        let isSelected = inboxViewModel.selectedDraftId == draft.draft_id
        return Button {
            inboxViewModel.selectDraft(draft.draft_id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(draftRecipientLabel(draft))
                        .os1Style(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let status = draftStatusLabel(draft) {
                        Text(status)
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }
                if let subject = draft.subject, !subject.isEmpty {
                    Text(subject)
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                let preview = draft.displayPreview
                if !preview.isEmpty {
                    Text(preview)
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.palette.glassFill : theme.palette.glassFill.opacity(0.4))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func draftRecipientLabel(_ draft: AgentMailDraftSummary) -> String {
        if let to = draft.to, !to.isEmpty {
            return to.count == 1
                ? L10n.string("To: %@", to[0])
                : L10n.string("To: %@ (+%@)", to[0], "\(to.count - 1)")
        }
        return L10n.string("(no recipient)")
    }

    private func draftStatusLabel(_ draft: AgentMailDraftSummary) -> String? {
        if draft.isScheduled, let raw = draft.send_at {
            return L10n.string("Scheduled · %@", formatTimestamp(raw))
        }
        if let updated = draft.updated_at {
            return formatTimestamp(updated)
        }
        return nil
    }

    private func messageRow(_ message: AgentMailMessageSummary) -> some View {
        let isSelected = inboxViewModel.selectedMessageId == message.message_id
        return Button {
            inboxViewModel.selectMessage(message.message_id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(senderDisplay(for: message))
                        .os1Style(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let timestamp = message.timestamp {
                        Text(formatTimestamp(timestamp))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }

                if let subject = message.subject, !subject.isEmpty {
                    Text(subject)
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                let preview = message.displayPreview
                if !preview.isEmpty {
                    Text(preview)
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.palette.glassFill : theme.palette.glassFill.opacity(0.4))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message detail pane

    @ViewBuilder
    private var messageDetailPane: some View {
        if inboxViewModel.selectedFolder == .drafts {
            draftDetailPane
        } else {
            regularMessageDetailPane
        }
    }

    private var regularMessageDetailPane: some View {
        VStack(spacing: 0) {
            switch inboxViewModel.detailLoadState {
            case .idle where inboxViewModel.selectedMessageId == nil:
                emptyDetailPlaceholder
            case .loading where inboxViewModel.selectedMessage == nil:
                HermesLoadingState(label: "Loading message…", minHeight: 200)
            case .failed(let error) where inboxViewModel.selectedMessage == nil:
                ContentUnavailableView(
                    L10n.string("Couldn't load message"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if let message = inboxViewModel.selectedMessage {
                    detailContent(message: message)
                } else if inboxViewModel.selectedMessageId == nil {
                    emptyDetailPlaceholder
                } else {
                    HermesLoadingState(label: "Loading message…", minHeight: 200)
                }
            }
        }
        .background(theme.palette.coral)
    }

    private var draftDetailPane: some View {
        VStack(spacing: 0) {
            if let error = inboxViewModel.draftActionError {
                Text(error)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            switch inboxViewModel.draftDetailLoadState {
            case .idle where inboxViewModel.selectedDraftId == nil:
                emptyDraftPlaceholder
            case .loading where inboxViewModel.selectedDraft == nil:
                HermesLoadingState(label: "Loading draft…", minHeight: 200)
            case .failed(let error) where inboxViewModel.selectedDraft == nil:
                ContentUnavailableView(
                    L10n.string("Couldn't load draft"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if let draft = inboxViewModel.selectedDraft {
                    draftDetailContent(draft: draft)
                } else if inboxViewModel.selectedDraftId == nil {
                    emptyDraftPlaceholder
                } else {
                    HermesLoadingState(label: "Loading draft…", minHeight: 200)
                }
            }
        }
        .background(theme.palette.coral)
    }

    private var emptyDraftPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("No draft selected"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Pick a draft on the left to review, send, or delete."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func draftDetailContent(draft: AgentMailDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            draftDetailHeader(draft: draft)

            Divider().background(theme.palette.onCoralMuted.opacity(0.18))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let body = draftBody(for: draft), !body.isEmpty {
                        Text(body)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.string("(empty body)"))
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                    if let attachments = draft.attachments, !attachments.isEmpty {
                        attachmentList(attachments)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func draftDetailHeader(draft: AgentMailDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.subject?.isEmpty == false ? draft.subject! : L10n.string("(no subject)"))
                        .os1Style(theme.typography.titleSection)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(2)

                    if let to = draft.to, !to.isEmpty {
                        Text(L10n.string("To: %@", to.joined(separator: ", ")))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                    }
                    if let cc = draft.cc, !cc.isEmpty {
                        Text(L10n.string("Cc: %@", cc.joined(separator: ", ")))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                    if let scheduled = draft.send_at, !scheduled.isEmpty {
                        Text(L10n.string("Scheduled to send %@", formatTimestamp(scheduled, longForm: true)))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    } else if let updated = draft.updated_at {
                        Text(L10n.string("Last edited %@", formatTimestamp(updated, longForm: true)))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button {
                        Task { await inboxViewModel.sendDraftNow(draft.draft_id) }
                    } label: {
                        Label(L10n.string("Send Now"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.os1Primary)
                    .help(draft.send_at?.isEmpty == false
                          ? L10n.string("Override the scheduled send and send right now")
                          : L10n.string("Send this draft now"))

                    Button {
                        Task { await inboxViewModel.deleteDraft(draft.draft_id) }
                    } label: {
                        Label(L10n.string("Delete"), systemImage: "trash")
                    }
                    .buttonStyle(.os1Secondary)
                    .help(L10n.string("Delete this draft (cancels scheduled sends)"))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func draftBody(for draft: AgentMailDraft) -> String? {
        if let text = draft.text, !text.isEmpty { return text }
        if let html = draft.html, !html.isEmpty {
            // Quick-and-dirty HTML→text fallback so the user sees something
            // readable when only an HTML body is set; full HTML rendering
            // belongs in a later checkpoint with a WebView.
            return html
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("No message selected"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Pick a message on the left to read it."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func detailContent(message: AgentMailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(message: message)

            Divider().background(theme.palette.onCoralMuted.opacity(0.18))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let body = preferredBody(for: message), !body.isEmpty {
                        Text(body)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.string("(empty body)"))
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }

                    if let attachments = message.attachments, !attachments.isEmpty {
                        attachmentList(attachments)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func detailHeader(message: AgentMailMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.subject?.isEmpty == false ? message.subject! : L10n.string("(no subject)"))
                        .os1Style(theme.typography.titleSection)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(2)

                    if let from = message.from, !from.isEmpty {
                        Text(L10n.string("From: %@", from))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                    }
                    if let to = message.to, !to.isEmpty {
                        Text(L10n.string("To: %@", to.joined(separator: ", ")))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                    }
                    if let cc = message.cc, !cc.isEmpty {
                        Text(L10n.string("Cc: %@", cc.joined(separator: ", ")))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                    if let timestamp = message.timestamp {
                        Text(formatTimestamp(timestamp, longForm: true))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }
                Spacer(minLength: 12)
                Button {
                    inboxViewModel.startReply(to: message)
                } label: {
                    Label(L10n.string("Reply"), systemImage: "arrowshape.turn.up.left.fill")
                }
                .buttonStyle(.os1Secondary)
                .help(L10n.string("Reply to this message"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func attachmentList(_ attachments: [AgentMailAttachmentSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Attachments"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            ForEach(attachments) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename ?? attachment.attachment_id)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let size = attachment.size {
                            Text(formatBytes(size))
                                .os1Style(theme.typography.smallCaps)
                                .foregroundStyle(theme.palette.onCoralMuted)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.palette.glassFill.opacity(0.5))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                }
            }
        }
    }

    private func preferredBody(for message: AgentMailMessage) -> String? {
        // extracted_text strips quoted reply history (per AgentMail's docs).
        // For the first read we want the full message; for replies we'd
        // prefer extracted. Default to text → extracted_text → empty.
        if let text = message.text, !text.isEmpty { return text }
        if let extracted = message.extracted_text, !extracted.isEmpty { return extracted }
        return nil
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// What the row shows in the sender column. For Sent / All Mail
    /// folders we surface "To: <recipient>" instead of the agent's own
    /// from-address (which would be the same on every row), matching
    /// Gmail's Sent-folder behavior.
    private func senderDisplay(for message: AgentMailMessageSummary) -> String {
        switch inboxViewModel.selectedFolder {
        case .sent, .drafts:
            if let recipients = message.to, !recipients.isEmpty {
                if recipients.count == 1 {
                    return L10n.string("To: %@", recipients[0])
                }
                return L10n.string("To: %@ (+%@)", recipients[0], "\(recipients.count - 1)")
            }
            return message.fromDisplayName.isEmpty
                ? L10n.string("Unknown recipient")
                : L10n.string("To: %@", message.fromDisplayName)
        case .inbox, .all:
            return message.fromDisplayName.isEmpty
                ? L10n.string("Unknown sender")
                : message.fromDisplayName
        }
    }

    private func formatTimestamp(_ raw: String, longForm: Bool = false) -> String {
        // ISO 8601 strings → relative-or-absolute display. Long form for
        // the detail header shows full date + time; short form for list
        // rows shows the most-relevant compact form.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            return raw
        }
        let dateFormatter = DateFormatter()
        if longForm {
            dateFormatter.dateStyle = .full
            dateFormatter.timeStyle = .short
            return dateFormatter.string(from: date)
        }
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 24 * 3600 {
            dateFormatter.timeStyle = .short
            dateFormatter.dateStyle = .none
        } else {
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
        }
        return dateFormatter.string(from: date)
    }
}
