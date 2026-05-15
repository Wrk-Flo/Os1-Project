import SwiftUI

struct ConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.os1Theme) private var theme

    private enum Field: Hashable {
        case label
        case alias
        case host
        case user
        case port
        case hermesProfile
        case apiKey
        case newComputerName
    }

    @State private var draft: ConnectionProfile
    @State private var portText: String
    @FocusState private var focusedField: Field?

    // Orgo-only state.
    @State private var apiKeyDraft: String = ""
    @State private var hasAPIKeyOnFile: Bool
    @State private var isVerifyingAPIKey = false
    @State private var apiKeyVerifyError: String?
    @State private var workspaces: [OrgoWorkspaceSummary] = []
    @State private var isLoadingWorkspaces = false
    @State private var workspaceLoadError: String?
    @State private var newComputerName: String = ""
    @State private var isCreatingComputer = false
    @State private var createComputerError: String?
    @State private var showCreateComputerForm = false

    let isEditing: Bool
    let credentialStore: OrgoCredentialStore
    let catalogService: OrgoCatalogService
    let onSave: (ConnectionProfile) -> Void

    init(
        connection: ConnectionProfile,
        isEditing: Bool,
        credentialStore: OrgoCredentialStore,
        catalogService: OrgoCatalogService,
        onSave: @escaping (ConnectionProfile) -> Void
    ) {
        _draft = State(initialValue: connection)
        _portText = State(initialValue: connection.sshPort.map(String.init) ?? "")
        _hasAPIKeyOnFile = State(initialValue: credentialStore.hasAPIKey)
        self.isEditing = isEditing
        self.credentialStore = credentialStore
        self.catalogService = catalogService
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HermesPageHeader(
                        title: isEditing ? "Edit Host" : "New Host",
                        subtitle: subtitleForKind
                    )

                    transportKindPanel

                    switch draft.transport {
                    case .ssh:
                        sshForm
                    case .orgo:
                        orgoForm
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(theme.palette.coral)

            bottomActionBar
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(theme.palette.coral)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                focusedField = .label
            }
            if case .orgo = draft.transport, hasAPIKeyOnFile {
                Task { await loadWorkspaces() }
            }
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(L10n.string("Cancel")) {
                dismiss()
            }
            .buttonStyle(.os1Secondary)
            .keyboardShortcut(.cancelAction)

            Button(L10n.string("Save")) {
                var updatedDraft = draft
                if case .ssh = draft.transport {
                    updatedDraft.sshPort = parsedPort
                }
                onSave(updatedDraft)
                dismiss()
            }
            .buttonStyle(.os1Primary)
            .keyboardShortcut(.defaultAction)
            .disabled(!isDraftValid)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(theme.palette.coral)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.palette.onCoralMuted.opacity(0.18))
                .frame(height: 1)
        }
    }

    // MARK: - Transport kind picker

    private var transportKindPanel: some View {
        HermesSurfacePanel(
            title: "Transport",
            subtitle: "Choose how OS1 reaches the host."
        ) {
            Picker("", selection: transportKindBinding) {
                Text(L10n.string("SSH")).tag(TransportKind.ssh)
                Text(L10n.string("Orgo VM")).tag(TransportKind.orgo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var transportKindBinding: Binding<TransportKind> {
        Binding(
            get: { draft.transport.kind },
            set: { newKind in
                guard newKind != draft.transport.kind else { return }
                switch newKind {
                case .ssh:
                    draft.transport = .ssh(SSHConfig())
                    portText = ""
                case .orgo:
                    draft.transport = .orgo(OrgoConfig())
                    if hasAPIKeyOnFile {
                        Task { await loadWorkspaces() }
                    }
                }
            }
        )
    }

    private var subtitleForKind: String {
        switch draft.transport {
        case .ssh:
            return "Set the SSH details OS1 should use for discovery, file editing, sessions and terminal access."
        case .orgo:
            return "Connect to a virtual computer running on Orgo. The same Hermes workflow, but the host runs in the cloud."
        }
    }

    // MARK: - SSH form

    private var sshForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HermesSurfacePanel(
                title: "Connection Details",
                subtitle: "Give the host a clear name, then prefer an SSH alias whenever you have one."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    EditorField(label: "Name") {
                        TextField(L10n.string("Home Pi, Studio Mac, Prod VPS"), text: $draft.label)
                            .focused($focusedField, equals: .label)
                            .os1Underlined()
                    }

                    EditorField(label: "SSH alias") {
                        TextField(L10n.string("hermes-home"), text: $draft.sshAlias)
                            .focused($focusedField, equals: .alias)
                            .os1Underlined()
                    }

                    EditorField(label: "Host or IP address") {
                        TextField(L10n.string("mac-studio.local, 203.0.113.10, localhost"), text: $draft.sshHost)
                            .focused($focusedField, equals: .host)
                            .os1Underlined()
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            EditorField(label: "SSH user") {
                                TextField("alex", text: $draft.sshUser)
                                    .focused($focusedField, equals: .user)
                                    .os1Underlined()
                            }

                            EditorField(label: "SSH port") {
                                TextField("22", text: $portText)
                                    .focused($focusedField, equals: .port)
                                    .os1Underlined()
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            EditorField(label: "SSH user") {
                                TextField("alex", text: $draft.sshUser)
                                    .focused($focusedField, equals: .user)
                                    .os1Underlined()
                            }

                            EditorField(label: "SSH port") {
                                TextField("22", text: $portText)
                                    .focused($focusedField, equals: .port)
                                    .os1Underlined()
                            }
                        }
                    }

                    EditorField(label: "Hermes profile") {
                        TextField(L10n.string("default or researcher"), text: hermesProfileBinding)
                            .focused($focusedField, equals: .hermesProfile)
                            .os1Underlined()
                    }

                    if let validationMessage {
                        HermesValidationMessage(text: validationMessage)
                    }
                }
            }

            HermesSurfacePanel(
                title: "How Hermes Connects",
                subtitle: "The goal is to keep the profile understandable without hiding the technical model."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionHintRow(
                        title: "Preferred setup",
                        detail: "Use an SSH alias when possible. It keeps the system SSH config as the source of truth."
                    )

                    ConnectionHintRow(
                        title: "Same Mac",
                        detail: "If Hermes runs on this Mac, stay with the SSH model and use localhost, the local hostname, or a local SSH alias."
                    )

                    ConnectionHintRow(
                        title: "Authentication",
                        detail: "SSH must already work from this Mac without interactive prompts. Password login may still exist on the host, but OS1 expects keys, an SSH agent, or another non-interactive SSH path for the actual connection it uses."
                    )

                    ConnectionHintRow(
                        title: "Network path",
                        detail: "The Mac and Hermes host do not need to be on the same Wi-Fi. Local network, public IP, VPN, or Tailscale all work as long as standard ssh from this Mac reaches the host."
                    )

                    if draft.trimmedAlias != nil && draft.trimmedHost != nil {
                        HermesInsetSurface {
                            Text(L10n.string("The SSH alias currently takes priority over Host. The Host value is preserved in the profile, but it will be ignored while the alias is present."))
                                .os1Style(theme.typography.body)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ConnectionHintRow(
                            title: "Overrides",
                            detail: "SSH user and port are optional. Leave them empty to keep the remote defaults."
                        )
                    }

                    HermesInsetSurface {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.string("Hermes profile"))
                                .os1Style(theme.typography.titlePanel)
                                .foregroundStyle(theme.palette.onCoralPrimary)

                            Text(L10n.string("Leave it empty for the default Hermes home at `~/.hermes`. Set a profile name like `researcher` to target `~/.hermes/profiles/researcher` on the same host."))
                                .os1Style(theme.typography.body)
                                .foregroundStyle(theme.palette.onCoralSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HermesSurfacePanel(
                title: "Examples",
                subtitle: "A few common patterns that work well with OS1."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ExampleValueRow(label: "Raspberry Pi", value: "Alias `hermes-home` or host `raspberrypi.local`")
                    ExampleValueRow(label: "Remote Mac", value: "Host `mac-studio.local`")
                    ExampleValueRow(label: "VPS", value: "Host `vps.example.com` or `203.0.113.10`")
                    ExampleValueRow(label: "Same Mac", value: "Host `localhost` or a local SSH alias")
                }
            }
        }
    }

    // MARK: - Orgo form

    private var orgoForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HermesSurfacePanel(
                title: "Connection Details",
                subtitle: "Pick a virtual computer in your Orgo workspace. OS1 will install Hermes on first connect if it's not already there."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    EditorField(label: "Name") {
                        TextField(L10n.string("Research VM"), text: $draft.label)
                            .focused($focusedField, equals: .label)
                            .os1Underlined()
                    }

                    apiKeyRow

                    if hasAPIKeyOnFile {
                        workspaceRow
                        computerRow
                    }

                    EditorField(label: "Hermes profile") {
                        TextField(L10n.string("default or researcher"), text: hermesProfileBinding)
                            .focused($focusedField, equals: .hermesProfile)
                            .os1Underlined()
                    }

                    if let validationMessage {
                        HermesValidationMessage(text: validationMessage)
                    }
                }
            }

            HermesSurfacePanel(
                title: "How Hermes Connects to Orgo",
                subtitle: "Direct API + websocket — no SSH, no gateway, no shadow state."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionHintRow(
                        title: "Authentication",
                        detail: "OS1 talks to Orgo with your API key (saved to macOS Keychain). One key per Mac — every Orgo connection profile reuses it."
                    )
                    ConnectionHintRow(
                        title: "Hermes on the VM",
                        detail: "On first connect, OS1 installs Hermes Agent on the Orgo VM if it's not already there. After that, the workspace looks the same as any SSH host."
                    )
                    ConnectionHintRow(
                        title: "Profiles",
                        detail: "Leave Hermes profile empty for the default home at `~/.hermes`. Set a name to target `~/.hermes/profiles/<name>` on the VM."
                    )
                }
            }
        }
    }

    // MARK: - Orgo: API key row

    @ViewBuilder
    private var apiKeyRow: some View {
        EditorField(label: "Orgo API key") {
            if hasAPIKeyOnFile {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text(L10n.string("API key saved to Keychain"))
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Spacer()
                    Button(L10n.string("Replace")) {
                        replaceAPIKey()
                    }
                    .buttonStyle(.os1Secondary)
                }
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SecureField(L10n.string("sk_live_…"), text: $apiKeyDraft)
                            .focused($focusedField, equals: .apiKey)
                            .os1Underlined()
                        Button(action: { Task { await verifyAndSaveAPIKey() } }) {
                            if isVerifyingAPIKey {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(theme.palette.onCoralPrimary)
                            } else {
                                Text(L10n.string("Verify & Save"))
                            }
                        }
                        .buttonStyle(.os1Primary)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifyingAPIKey)
                    }
                    if let error = apiKeyVerifyError {
                        Text(error)
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.string("Get a key at orgo.ai/settings/api-keys. Stored in macOS Keychain — never written to disk."))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }
            }
        }
    }

    // MARK: - Orgo: workspace row

    @ViewBuilder
    private var workspaceRow: some View {
        EditorField(label: "Workspace") {
            HStack(spacing: 10) {
                OS1DropdownMenu(
                    selectedLabel: selectedWorkspace?.name,
                    placeholder: L10n.string("Pick a workspace…"),
                    isDisabled: isLoadingWorkspaces || workspaces.isEmpty,
                    options: workspaces.map { ws in
                        OS1DropdownMenu.Option(
                            id: ws.id,
                            label: ws.name,
                            isSelected: workspaceIDBinding.wrappedValue == ws.id
                        ) {
                            workspaceIDBinding.wrappedValue = ws.id
                        }
                    }
                )

                if isLoadingWorkspaces {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.onCoralPrimary)
                }

                Button(action: { Task { await loadWorkspaces() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.os1Icon)
                .help(L10n.string("Refresh workspaces"))
                .disabled(isLoadingWorkspaces)
            }
            if let error = workspaceLoadError {
                Text(error)
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isLoadingWorkspaces && workspaces.isEmpty {
                Text(L10n.string("No workspaces yet. Create one at orgo.ai then refresh."))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
        }
    }

    private var workspaceIDBinding: Binding<String?> {
        Binding(
            get: {
                guard case .orgo(let cfg) = draft.transport else { return nil }
                return cfg.workspaceId.isEmpty ? nil : cfg.workspaceId
            },
            set: { newID in
                guard case .orgo(var cfg) = draft.transport else { return }
                cfg.workspaceId = newID ?? ""
                cfg.computerId = ""
                draft.transport = .orgo(cfg)
                showCreateComputerForm = false
                createComputerError = nil
            }
        )
    }

    // MARK: - Orgo: computer row

    @ViewBuilder
    private var computerRow: some View {
        EditorField(label: "Computer") {
            VStack(alignment: .leading, spacing: 10) {
                let workspace = selectedWorkspace
                let computers = workspace?.computers ?? []
                let placeholder = workspace == nil
                    ? L10n.string("Pick a workspace first")
                    : (computers.isEmpty
                       ? L10n.string("No computers in this workspace")
                       : L10n.string("Pick a computer…"))

                OS1DropdownMenu(
                    selectedLabel: selectedComputerLabel(in: computers),
                    placeholder: placeholder,
                    isDisabled: workspace == nil || computers.isEmpty,
                    options: computers.map { computer in
                        OS1DropdownMenu.Option(
                            id: computer.id,
                            label: "\(computer.name)  (\(computer.status))",
                            isSelected: computerIDBinding.wrappedValue == computer.id
                        ) {
                            computerIDBinding.wrappedValue = computer.id
                        }
                    }
                )

                if workspace != nil && !showCreateComputerForm {
                    Button(action: { showCreateComputerForm = true; newComputerName = "" }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12, weight: .semibold))
                            Text(L10n.string("Create new computer…"))
                        }
                    }
                    .buttonStyle(.os1Secondary)
                }

                if showCreateComputerForm, workspace != nil {
                    HermesInsetSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("New computer"))
                                .os1Style(theme.typography.titlePanel)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                            HStack(spacing: 8) {
                                TextField(L10n.string("name (e.g. orgo-mac-2)"), text: $newComputerName)
                                    .focused($focusedField, equals: .newComputerName)
                                    .os1Underlined()
                                Button(action: { Task { await createComputer() } }) {
                                    if isCreatingComputer {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(theme.palette.onCoralPrimary)
                                    } else {
                                        Text(L10n.string("Create"))
                                    }
                                }
                                .buttonStyle(.os1Primary)
                                .disabled(newComputerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingComputer)
                                Button(L10n.string("Cancel")) {
                                    showCreateComputerForm = false
                                    newComputerName = ""
                                    createComputerError = nil
                                }
                                .buttonStyle(.os1Secondary)
                            }
                            if let error = createComputerError {
                                Text(error)
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(L10n.string("Defaults: Linux, 8 GB RAM, 4 CPU, 50 GB disk. Use the Orgo dashboard for custom specs."))
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    private var computerIDBinding: Binding<String?> {
        Binding(
            get: {
                guard case .orgo(let cfg) = draft.transport else { return nil }
                return cfg.computerId.isEmpty ? nil : cfg.computerId
            },
            set: { newID in
                guard case .orgo(var cfg) = draft.transport else { return }
                cfg.computerId = newID ?? ""
                draft.transport = .orgo(cfg)
            }
        )
    }

    private var selectedWorkspace: OrgoWorkspaceSummary? {
        guard case .orgo(let cfg) = draft.transport, !cfg.workspaceId.isEmpty else { return nil }
        return workspaces.first { $0.id == cfg.workspaceId }
    }

    private func selectedComputerLabel(in computers: [OrgoComputerSummary]) -> String? {
        guard let id = computerIDBinding.wrappedValue,
              let computer = computers.first(where: { $0.id == id }) else { return nil }
        return "\(computer.name)  (\(computer.status))"
    }

    // MARK: - Orgo: actions

    @MainActor
    private func verifyAndSaveAPIKey() async {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isVerifyingAPIKey = true
        apiKeyVerifyError = nil
        defer { isVerifyingAPIKey = false }

        let httpClient = OrgoHTTPClient(apiKeyProvider: { trimmed })
        let probeService = OrgoCatalogService(httpClient: httpClient)
        do {
            let loaded = try await probeService.listWorkspaces()
            try credentialStore.saveAPIKey(trimmed)
            apiKeyDraft = ""
            hasAPIKeyOnFile = true
            workspaces = loaded
        } catch let error as RemoteTransportError {
            apiKeyVerifyError = error.errorDescription ?? "Couldn't verify the API key."
        } catch {
            apiKeyVerifyError = "Couldn't verify: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func replaceAPIKey() {
        hasAPIKeyOnFile = false
        apiKeyDraft = ""
        apiKeyVerifyError = nil
        workspaces = []
        workspaceLoadError = nil
    }

    @MainActor
    private func loadWorkspaces() async {
        isLoadingWorkspaces = true
        workspaceLoadError = nil
        defer { isLoadingWorkspaces = false }

        do {
            workspaces = try await catalogService.listWorkspaces()
        } catch let error as RemoteTransportError {
            workspaceLoadError = error.errorDescription ?? "Couldn't load workspaces."
            workspaces = []
        } catch {
            workspaceLoadError = "Couldn't load workspaces: \(error.localizedDescription)"
            workspaces = []
        }
    }

    @MainActor
    private func createComputer() async {
        guard let workspace = selectedWorkspace else { return }
        let trimmedName = newComputerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isCreatingComputer = true
        createComputerError = nil
        defer { isCreatingComputer = false }

        do {
            let created = try await catalogService.createComputer(
                workspaceID: workspace.id,
                computerName: trimmedName
            )
            await loadWorkspaces()
            if case .orgo(var cfg) = draft.transport {
                cfg.computerId = created.id
                draft.transport = .orgo(cfg)
            }
            showCreateComputerForm = false
            newComputerName = ""
        } catch let error as RemoteTransportError {
            createComputerError = error.errorDescription ?? "Couldn't create the computer."
        } catch {
            createComputerError = "Couldn't create: \(error.localizedDescription)"
        }
    }

    // MARK: - Validation + helpers

    private var parsedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }

    private var isDraftValid: Bool {
        validationMessage == nil
    }

    private var validationMessage: String? {
        if draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name is required."
        }

        switch draft.transport {
        case .ssh:
            let hasValidPort = portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedPort != nil
            var candidate = draft
            candidate.sshPort = parsedPort
            if candidate.trimmedAlias == nil && candidate.trimmedHost == nil {
                return "Add an SSH alias or host."
            }
            if !hasValidPort {
                return "Enter a valid SSH port from 1 to 65535."
            }
            return candidate.validationError

        case .orgo:
            if !hasAPIKeyOnFile {
                return "Verify and save an Orgo API key before continuing."
            }
            return draft.validationError
        }
    }

    private var hermesProfileBinding: Binding<String> {
        Binding {
            draft.hermesProfile ?? ""
        } set: { newValue in
            draft.hermesProfile = newValue
        }
    }
}

struct EditorField<Content: View>: View {
    @Environment(\.os1Theme) private var theme

    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(label))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionHintRow: View {
    @Environment(\.os1Theme) private var theme

    let title: String
    let detail: String

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(title))
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)

                Text(L10n.string(detail))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ExampleValueRow: View {
    @Environment(\.os1Theme) private var theme

    let label: String
    let value: String

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(label))
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)

                Text(value)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
            }
        }
    }
}
