import SwiftUI

/// Compose sheet — handles both new messages and replies. Posts via
/// `MailInboxViewModel.send` (fresh) or `.reply` (in-thread). Looks
/// like the rest of the OS1 sheet chrome (coral surface, glass
/// dividers, hairline footer divider).
struct MailComposeSheet: View {
    @ObservedObject var viewModel: MailInboxViewModel
    let context: MailInboxViewModel.ComposeContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.os1Theme) private var theme

    @State private var toField: String
    @State private var subjectField: String
    @State private var bodyField: String
    @State private var isSending = false
    @State private var isSavingDraft = false
    @State private var sendError: String?

    init(viewModel: MailInboxViewModel, context: MailInboxViewModel.ComposeContext) {
        self.viewModel = viewModel
        self.context = context

        switch context {
        case .fresh:
            _toField = State(initialValue: "")
            _subjectField = State(initialValue: "")
            _bodyField = State(initialValue: "")
        case .replying(let message):
            // Pre-fill recipients from the original sender; subject
            // gets the canonical "Re: " prefix; body left blank for
            // the user.
            let sender = message.from?.firstIndex(of: "<").flatMap { idx in
                message.from?[message.from!.index(after: idx)..<(message.from!.firstIndex(of: ">") ?? message.from!.endIndex)]
            }.map(String.init) ?? message.from ?? ""
            _toField = State(initialValue: sender)
            let originalSubject = message.subject ?? ""
            let prefix = originalSubject.lowercased().hasPrefix("re:") ? "" : "Re: "
            _subjectField = State(initialValue: prefix + originalSubject)
            _bodyField = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HermesPageHeader(
                        title: title,
                        subtitle: subtitle
                    )

                    if let error = sendError {
                        Text(error)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    HermesSurfacePanel(title: "Recipients") {
                        EditorField(label: toField.isEmpty ? "To" : "To (comma-separated for multiple)") {
                            TextField(L10n.string("recipient@example.com"), text: $toField)
                                .os1Underlined()
                                .disabled(isSending)
                        }
                    }

                    HermesSurfacePanel(title: "Subject") {
                        TextField(L10n.string("Subject"), text: $subjectField)
                            .os1Underlined()
                            .disabled(isSending)
                    }

                    HermesSurfacePanel(title: "Message") {
                        TextEditor(text: $bodyField)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.os1OnCoralPrimary)
                            .font(.os1Body)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(Color.os1GlassFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .disabled(isSending)
                    }

                    if let from = viewModel.activeInboxAddress {
                        Text(L10n.string("Sending from %@", from))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(theme.palette.coral)

            footerActions
        }
        .frame(minWidth: 620, minHeight: 540)
        .background(theme.palette.coral)
    }

    private var title: String {
        switch context {
        case .fresh:    return L10n.string("New message")
        case .replying: return L10n.string("Reply")
        }
    }

    private var subtitle: String {
        switch context {
        case .fresh:
            return L10n.string("Send an email from your AgentMail inbox.")
        case .replying(let message):
            if let subject = message.subject, !subject.isEmpty {
                return L10n.string("Replying to \"%@\"", subject)
            }
            return L10n.string("Replying in this thread.")
        }
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button(L10n.string("Cancel")) {
                viewModel.cancelCompose()
                dismiss()
            }
            .buttonStyle(.os1Secondary)
            .keyboardShortcut(.cancelAction)
            .disabled(isSending || isSavingDraft)

            Spacer()

            Button {
                Task { await saveDraft() }
            } label: {
                if isSavingDraft {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string("Saving…"))
                    }
                } else {
                    Label(L10n.string("Save as draft"), systemImage: "tray.and.arrow.down")
                }
            }
            .buttonStyle(.os1Secondary)
            .disabled(isSending || isSavingDraft || !hasAnythingToSave)
            .help(L10n.string("Save this message to your Drafts folder without sending."))

            Button {
                Task { await submit() }
            } label: {
                if isSending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string("Sending…"))
                    }
                } else {
                    Text(submitLabel)
                }
            }
            .buttonStyle(.os1Primary)
            .keyboardShortcut(.defaultAction)
            .disabled(isSending || isSavingDraft || !canSubmit)
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

    /// Drafts can be partial — save is enabled as long as there's any
    /// content at all. Avoids stashing entirely-empty stub drafts.
    private var hasAnythingToSave: Bool {
        !toField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subjectField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var submitLabel: String {
        switch context {
        case .fresh:    return L10n.string("Send")
        case .replying: return L10n.string("Reply")
        }
    }

    private var canSubmit: Bool {
        let trimmedTo = toField.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = bodyField.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedTo.isEmpty && !trimmedBody.isEmpty
    }

    private func submit() async {
        guard !isSending, canSubmit else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        let recipients = parsedRecipients()
        let subject = subjectField.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyField.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch context {
            case .fresh:
                _ = try await viewModel.send(
                    to: recipients,
                    subject: subject,
                    body: body
                )
            case .replying(let message):
                _ = try await viewModel.reply(
                    to: message.message_id,
                    body: body,
                    recipients: recipients
                )
            }
            viewModel.cancelCompose()
            dismiss()
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveDraft() async {
        guard !isSavingDraft, !isSending, hasAnythingToSave else { return }
        isSavingDraft = true
        sendError = nil
        defer { isSavingDraft = false }

        let recipients = parsedRecipients()
        let subject = subjectField.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyField.trimmingCharacters(in: .whitespacesAndNewlines)

        // For replies, pass through the source message so the draft
        // gets in_reply_to / references and stays in the right thread
        // when later sent.
        let source: AgentMailMessage? = {
            if case .replying(let message) = context { return message }
            return nil
        }()

        do {
            _ = try await viewModel.saveAsDraft(
                to: recipients,
                subject: subject,
                body: body,
                replyingTo: source
            )
            viewModel.cancelCompose()
            dismiss()
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func parsedRecipients() -> [String] {
        toField
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
