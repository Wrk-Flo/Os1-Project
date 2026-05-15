import SwiftUI

/// Modal sheet for one provider's "Connect" action. Two paths:
///   - paste-key: visible for every provider; pings the provider's
///     `/models` endpoint to validate before saving.
///   - "Sign in with X": only OpenRouter today. Launches the PKCE
///     flow; the resulting key flows through the same validate+save
///     pipeline as a paste.
struct ProviderConnectSheet: View {
    @ObservedObject var viewModel: ProvidersViewModel
    @Environment(\.os1Theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let entry: ProviderCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if entry.supportsOAuth {
                oauthSection
                divider
            }

            pasteKeySection

            if let error = viewModel.connectFlowError {
                HermesValidationMessage(text: error)
            }

            footer
        }
        .padding(24)
        .frame(width: 520)
        .background(theme.palette.coral)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.palette.glassFill)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Connect %@", entry.displayName))
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string(entry.tagline))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(entry.dashboardURL)
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.string("Get key"))
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                }
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralSecondary)
            }
            .buttonStyle(.plain)
            .help(L10n.string(entry.dashboardURL.absoluteString))
        }
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("Recommended"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            Button {
                Task { await viewModel.signInWithOpenRouter() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.oauthInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.palette.onCoralPrimary)
                    } else {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(viewModel.oauthInProgress
                         ? L10n.string("Waiting for browser…")
                         : L10n.string("Sign in with OpenRouter"))
                }
            }
            .buttonStyle(.os1Primary)
            .disabled(viewModel.oauthInProgress)

            Text(L10n.string("Opens openrouter.ai in your browser. After you authorize, OS1 receives a per-app key and stores it in Keychain — your account password never touches the app."))
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(theme.palette.onCoralMuted.opacity(0.25))
                .frame(height: 1)
            Text(L10n.string("or"))
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralMuted)
            Rectangle()
                .fill(theme.palette.onCoralMuted.opacity(0.25))
                .frame(height: 1)
        }
    }

    private var pasteKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Paste API key"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            SecureField(L10n.string(entry.keyPrefixHint), text: $viewModel.apiKeyDraft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.palette.glassFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                }
                .disabled(viewModel.connectFlowState == .validating || viewModel.connectFlowState == .saving)

            Text(L10n.string("Stored in macOS Keychain on this Mac. Push to a remote host with the row's Install action."))
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L10n.string("Cancel")) {
                viewModel.closeConnectSheet()
                dismiss()
            }
            .buttonStyle(.os1Secondary)
            .disabled(viewModel.connectFlowState == .validating || viewModel.connectFlowState == .saving)

            Button {
                Task {
                    await viewModel.saveAPIKey()
                    if viewModel.selectedProvider == nil {
                        dismiss()
                    }
                }
            } label: {
                if viewModel.connectFlowState == .validating || viewModel.connectFlowState == .saving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string(viewModel.connectFlowState == .validating ? "Validating…" : "Saving…"))
                    }
                } else {
                    Text(L10n.string("Save key"))
                }
            }
            .buttonStyle(.os1Primary)
            .disabled(viewModel.apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                      || viewModel.connectFlowState == .validating
                      || viewModel.connectFlowState == .saving)
        }
    }
}
