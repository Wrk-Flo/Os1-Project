import Foundation
import SwiftUI

/// Drives the configured-state mail browser: folder selection, message
/// list, message detail, and compose. Distinct from `MailSetupViewModel`
/// (which handles auth/key flow) so each file stays focused.
///
/// Active inbox is sourced from `AgentMailAccountStore.account`. When
/// the user switches hosts, the auto-swap in setup view-model swaps
/// which account is active, and this view-model re-fetches against the
/// new inbox.
@MainActor
final class MailInboxViewModel: ObservableObject {
    /// Built-in folders. Maps to AgentMail's label-based filtering.
    enum Folder: String, CaseIterable, Identifiable, Equatable {
        case inbox
        case sent
        case drafts        // surfaced via labels=["drafts"]; full Drafts API in a later checkpoint
        case all

        var id: String { rawValue }
        var title: String {
            switch self {
            case .inbox:  return "Inbox"
            case .sent:   return "Sent"
            case .drafts: return "Drafts"
            case .all:    return "All Mail"
            }
        }
        var systemImage: String {
            switch self {
            case .inbox:  return "tray.fill"
            case .sent:   return "paperplane.fill"
            case .drafts: return "doc.fill"
            case .all:    return "tray.2.fill"
            }
        }
        /// Server-side label filter. AgentMail auto-applies `sent` to
        /// outbound messages but does NOT apply an `inbox` label to
        /// received ones — there's no symmetric server-side filter for
        /// inbox/all. We compensate with client-side filtering below.
        var serverLabelFilter: [String]? {
            switch self {
            case .sent:   return ["sent"]
            case .drafts: return ["scheduled"]   // scheduled drafts are auto-labeled
            case .inbox, .all: return nil
            }
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    @Published var selectedFolder: Folder = .inbox
    @Published private(set) var messages: [AgentMailMessageSummary] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published var selectedMessageId: String?
    @Published private(set) var selectedMessage: AgentMailMessage?
    @Published private(set) var detailLoadState: LoadState = .idle

    // Drafts state (separate path: AgentMail's drafts API is distinct
    // from messages — different endpoints, different shape, different
    // actions like Send-Now / Delete).
    @Published private(set) var drafts: [AgentMailDraftSummary] = []
    @Published var selectedDraftId: String?
    @Published private(set) var selectedDraft: AgentMailDraft?
    @Published private(set) var draftDetailLoadState: LoadState = .idle
    @Published var draftActionError: String?

    // Search query (client-side filter — AgentMail has no server-side
    // free-text search yet; semantic search is "under development" per
    // their docs). Applied to whatever's currently loaded in `messages`
    // or `drafts`.
    @Published var searchQuery: String = ""

    // Inbox switcher state — separate from `account.primaryInboxId`,
    // which is the agent's canonical inbox. Users can VIEW any inbox
    // in their AgentMail account without changing the agent's default.
    @Published private(set) var availableInboxes: [AgentMailInboxSummary] = []
    @Published private(set) var selectedInboxId: String?
    @Published private(set) var inboxesLoadState: LoadState = .idle

    // Compose sheet state
    @Published var composeContext: ComposeContext?

    /// Drives the compose sheet. `.fresh` for a brand-new message;
    /// `.replying(...)` pre-populates To/Subject from the source message
    /// so the user just types the body. The sheet closes when this is
    /// reset to nil.
    enum ComposeContext: Identifiable, Equatable {
        case fresh
        case replying(to: AgentMailMessage)

        var id: String {
            switch self {
            case .fresh:                       return "fresh"
            case .replying(let message):       return "reply-\(message.message_id)"
            }
        }
    }

    private let credentialStore: AgentMailCredentialStore
    private let accountStore: AgentMailAccountStore
    private let service: AgentMailService
    private let realtimeService: AgentMailRealtimeService?

    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var inboxesTask: Task<Void, Never>?
    private var draftDetailTask: Task<Void, Never>?
    private var currentProfileId: String?

    /// Whether the live event subscription is currently active. Drives
    /// the small "Live" indicator next to the folder name so the user
    /// can tell new mail will land without a refresh.
    @Published private(set) var isLiveConnected = false

    init(
        credentialStore: AgentMailCredentialStore,
        accountStore: AgentMailAccountStore,
        service: AgentMailService = AgentMailService(),
        realtimeService: AgentMailRealtimeService? = nil
    ) {
        self.credentialStore = credentialStore
        self.accountStore = accountStore
        self.service = service
        self.realtimeService = realtimeService
    }

    deinit {
        realtimeService?.unsubscribe()
    }

    // MARK: - Active context

    func setActiveProfile(_ profileId: String?) {
        if currentProfileId == profileId { return }
        currentProfileId = profileId
        // Tear down the prior subscription before resetting state — the
        // new profile may use a different API key entirely.
        stopLive()
        // Wipe the in-memory view; the new account's data loads in.
        messages = []
        selectedMessageId = nil
        selectedMessage = nil
        loadState = .idle
        detailLoadState = .idle
        drafts = []
        selectedDraftId = nil
        selectedDraft = nil
        draftDetailLoadState = .idle
        draftActionError = nil
        searchQuery = ""
        // Reset inbox switcher to the new profile's primary inbox.
        availableInboxes = []
        inboxesLoadState = .idle
        selectedInboxId = accountStore.account?.primaryInboxId
    }

    // MARK: - Inbox switcher

    /// Fetches every inbox under the account so the switcher in the
    /// folder pane has them all to offer. Keeps the current selection
    /// stable (e.g. "Orgo") if the user switches between profiles
    /// where the same inbox exists.
    func loadInboxes() {
        guard let credentials = currentCredentials() else {
            inboxesLoadState = .failed(message: "Configure AgentMail first.")
            return
        }
        inboxesTask?.cancel()
        inboxesLoadState = .loading

        inboxesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inboxes = try await self.service.listInboxes(apiKey: credentials.apiKey)
                try Task.checkCancellation()
                self.availableInboxes = inboxes
                self.inboxesLoadState = .loaded
                // If the current selection isn't in the list (e.g.,
                // first load before primaryInboxId was synced), fall
                // back to the primary or the first available.
                if let id = self.selectedInboxId, !inboxes.contains(where: { $0.inbox_id == id }) {
                    self.selectedInboxId = self.accountStore.account?.primaryInboxId ?? inboxes.first?.inbox_id
                } else if self.selectedInboxId == nil {
                    self.selectedInboxId = self.accountStore.account?.primaryInboxId ?? inboxes.first?.inbox_id
                }
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.inboxesLoadState = .failed(message: message)
            }
        }
    }

    /// Switches which inbox the message list / detail panes are
    /// reading from. Doesn't change the agent's primary inbox — just
    /// the UI's view.
    func selectInbox(_ inboxId: String) {
        guard selectedInboxId != inboxId else { return }
        selectedInboxId = inboxId
        messages = []
        selectedMessageId = nil
        selectedMessage = nil
        loadState = .idle
        detailLoadState = .idle
        refresh()
        startLive()   // re-subscribe against the new inbox
    }

    // MARK: - Real-time updates

    /// Opens (or replaces) the AgentMail WebSocket subscription for
    /// the active inbox. Called automatically on Mail-tab appear and
    /// whenever the active inbox or profile changes.
    func startLive() {
        guard let realtimeService else { return }
        guard let credentials = currentCredentials() else {
            realtimeService.unsubscribe()
            isLiveConnected = false
            return
        }
        realtimeService.subscribe(
            apiKey: credentials.apiKey,
            inboxIds: [credentials.inboxId]
        ) { [weak self] event in
            // Hop to main actor — service callbacks fire on a utility queue.
            Task { @MainActor [weak self] in
                self?.handleLiveEvent(event)
            }
        }
    }

    func stopLive() {
        realtimeService?.unsubscribe()
        isLiveConnected = false
    }

    private func handleLiveEvent(_ event: AgentMailRealtimeService.Event) {
        switch event {
        case .opened:
            // Connection is open but not yet acknowledged by the server.
            // Don't flip the indicator until we get `subscribed`.
            break
        case .subscribed:
            isLiveConnected = true
        case .messageReceived(let inboxId, _):
            // Refresh the list when an event lands for the inbox we're
            // viewing. For other inboxes (e.g., a different one in the
            // user's account), ignore — the inbox-switcher will pick up
            // changes when the user navigates there.
            if shouldRefreshForEvent(inboxId: inboxId) { refresh() }
        case .messageSent, .messageDelivered:
            if selectedFolder == .sent || selectedFolder == .all {
                refresh()
            }
        case .otherEvent:
            break
        case .closed, .failed:
            isLiveConnected = false
            // The service auto-reconnects with backoff, so we don't
            // surface failures here. The indicator just goes dark
            // until the next `subscribed` event.
        }
    }

    private func shouldRefreshForEvent(inboxId: String?) -> Bool {
        guard let active = selectedInboxId else { return true }
        guard let inboxId else { return true }   // unknown — be permissive
        return inboxId == active
    }

    func selectFolder(_ folder: Folder) {
        guard selectedFolder != folder else { return }
        selectedFolder = folder
        selectedMessageId = nil
        selectedMessage = nil
        selectedDraftId = nil
        selectedDraft = nil
        searchQuery = ""
        refresh()
    }

    // MARK: - Compose

    func startCompose() {
        composeContext = .fresh
    }

    func startReply(to message: AgentMailMessage) {
        composeContext = .replying(to: message)
    }

    func cancelCompose() {
        composeContext = nil
    }

    /// Returns the inbox address currently being viewed. Used by the
    /// compose sheet's "From" line so it matches what the user sees in
    /// the message list above.
    var activeInboxAddress: String? {
        activeViewingInboxId
    }

    // MARK: - Message list

    /// Loads the message or drafts list for the currently-selected folder
    /// against the active inbox. Drafts route through the dedicated
    /// drafts API (separate endpoints, distinct shape, supports
    /// send-now/delete actions). Cancels any prior in-flight load.
    func refresh() {
        guard let credentials = currentCredentials() else {
            loadState = .failed(message: "Configure AgentMail first.")
            return
        }
        if selectedFolder == .drafts {
            refreshDrafts(credentials: credentials)
        } else {
            refreshMessages(credentials: credentials)
        }
    }

    private func refreshMessages(credentials: ResolvedCredentials) {
        listTask?.cancel()
        loadState = .loading

        listTask = Task { [weak self, selectedFolder] in
            guard let self else { return }
            do {
                let raw = try await self.service.listMessages(
                    apiKey: credentials.apiKey,
                    inboxId: credentials.inboxId,
                    labels: selectedFolder.serverLabelFilter,
                    limit: 100
                )
                try Task.checkCancellation()
                // Client-side split so the Inbox folder shows received
                // mail (no `sent` label) and All Mail shows everything.
                let filtered: [AgentMailMessageSummary]
                switch selectedFolder {
                case .inbox: filtered = raw.filter { !$0.isSent }
                case .sent, .drafts, .all: filtered = raw
                }
                self.messages = filtered
                self.loadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.loadState = .failed(message: message)
            }
        }
    }

    private func refreshDrafts(credentials: ResolvedCredentials) {
        listTask?.cancel()
        loadState = .loading

        listTask = Task { [weak self] in
            guard let self else { return }
            do {
                let drafts = try await self.service.listDrafts(
                    apiKey: credentials.apiKey,
                    inboxId: credentials.inboxId,
                    limit: 100
                )
                try Task.checkCancellation()
                self.drafts = drafts
                self.loadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.loadState = .failed(message: message)
            }
        }
    }

    // MARK: - Message detail

    func selectMessage(_ messageId: String?) {
        selectedMessageId = messageId
        selectedMessage = nil
        guard let messageId else {
            detailLoadState = .idle
            return
        }
        loadDetail(for: messageId)
    }

    private func loadDetail(for messageId: String) {
        guard let credentials = currentCredentials() else { return }
        detailTask?.cancel()
        detailLoadState = .loading

        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.service.getMessage(
                    apiKey: credentials.apiKey,
                    inboxId: credentials.inboxId,
                    messageId: messageId
                )
                try Task.checkCancellation()
                guard self.selectedMessageId == messageId else { return }
                self.selectedMessage = message
                self.detailLoadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.detailLoadState = .failed(message: message)
            }
        }
    }

    // MARK: - Send / reply

    /// Sends a new message from the active inbox. Returns the saved
    /// message on success so the caller can refresh.
    func send(
        to: [String],
        subject: String,
        body: String
    ) async throws -> AgentMailMessage {
        guard let credentials = currentCredentials() else {
            throw AgentMailError.invalidInput("AgentMail isn't configured.")
        }
        let message = try await service.sendMessage(
            apiKey: credentials.apiKey,
            inboxId: credentials.inboxId,
            to: to,
            subject: subject,
            text: body
        )
        // Refresh the Sent folder if we're viewing it; otherwise the
        // user can refresh manually.
        if selectedFolder == .sent {
            refresh()
        }
        return message
    }

    /// Stashes whatever the user has typed into the compose sheet as a
    /// draft. Both `to` and body may be empty — AgentMail allows partial
    /// drafts. When the active compose context is a reply, threading
    /// headers (in_reply_to / references) are preserved so the eventual
    /// send lands in the right thread.
    func saveAsDraft(
        to: [String],
        subject: String,
        body: String,
        replyingTo source: AgentMailMessage? = nil
    ) async throws -> AgentMailDraft {
        guard let credentials = currentCredentials() else {
            throw AgentMailError.invalidInput("AgentMail isn't configured.")
        }
        let inReplyTo = source?.message_id
        let references: [String]? = source.map { msg in
            // If the source message already references prior messages,
            // chain through; otherwise start a fresh references list
            // with just the source's id.
            if let existing = msg.references, !existing.isEmpty {
                return existing + [msg.message_id]
            }
            return [msg.message_id]
        }
        let draft = try await service.createDraft(
            apiKey: credentials.apiKey,
            inboxId: credentials.inboxId,
            to: to,
            subject: subject,
            text: body,
            inReplyTo: inReplyTo,
            references: references
        )
        // Refresh the Drafts folder if currently viewing it so the
        // newly-saved draft appears.
        if selectedFolder == .drafts {
            refresh()
        }
        return draft
    }

    /// Replies to a message in the current detail view.
    func reply(
        to messageId: String,
        body: String,
        recipients: [String]?
    ) async throws -> AgentMailMessage {
        guard let credentials = currentCredentials() else {
            throw AgentMailError.invalidInput("AgentMail isn't configured.")
        }
        let result = try await service.replyToMessage(
            apiKey: credentials.apiKey,
            inboxId: credentials.inboxId,
            messageId: messageId,
            to: recipients,
            text: body
        )
        // Re-fetch the thread state by refreshing the message detail.
        if selectedMessageId == messageId {
            loadDetail(for: messageId)
        }
        return result
    }

    // MARK: - Helpers

    // MARK: - Search & filtered accessors

    /// `messages` after applying the current search query (case-insensitive
    /// match against from / subject / preview). Empty query returns all.
    var filteredMessages: [AgentMailMessageSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return messages }
        return messages.filter { msg in
            (msg.from?.lowercased().contains(q) ?? false)
                || (msg.subject?.lowercased().contains(q) ?? false)
                || msg.displayPreview.lowercased().contains(q)
                || (msg.to?.contains(where: { $0.lowercased().contains(q) }) ?? false)
        }
    }

    var filteredDrafts: [AgentMailDraftSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return drafts }
        return drafts.filter { draft in
            (draft.subject?.lowercased().contains(q) ?? false)
                || draft.displayPreview.lowercased().contains(q)
                || (draft.to?.contains(where: { $0.lowercased().contains(q) }) ?? false)
        }
    }

    // MARK: - Draft selection + actions

    func selectDraft(_ draftId: String?) {
        selectedDraftId = draftId
        selectedDraft = nil
        guard let draftId else {
            draftDetailLoadState = .idle
            return
        }
        loadDraftDetail(for: draftId)
    }

    private func loadDraftDetail(for draftId: String) {
        guard let credentials = currentCredentials() else { return }
        draftDetailTask?.cancel()
        draftDetailLoadState = .loading

        draftDetailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await self.service.getDraft(
                    apiKey: credentials.apiKey,
                    inboxId: credentials.inboxId,
                    draftId: draftId
                )
                try Task.checkCancellation()
                guard self.selectedDraftId == draftId else { return }
                self.selectedDraft = draft
                self.draftDetailLoadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.draftDetailLoadState = .failed(message: message)
            }
        }
    }

    /// Sends a saved draft immediately (overrides any `send_at` schedule).
    func sendDraftNow(_ draftId: String) async {
        guard let credentials = currentCredentials() else { return }
        draftActionError = nil
        do {
            _ = try await service.sendDraft(
                apiKey: credentials.apiKey,
                inboxId: credentials.inboxId,
                draftId: draftId
            )
            // Drop selection + refresh the drafts folder.
            if selectedDraftId == draftId {
                selectedDraftId = nil
                selectedDraft = nil
            }
            refresh()
        } catch {
            draftActionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Deletes a draft. Also cancels its scheduled send if applicable.
    func deleteDraft(_ draftId: String) async {
        guard let credentials = currentCredentials() else { return }
        draftActionError = nil
        do {
            try await service.deleteDraft(
                apiKey: credentials.apiKey,
                inboxId: credentials.inboxId,
                draftId: draftId
            )
            if selectedDraftId == draftId {
                selectedDraftId = nil
                selectedDraft = nil
            }
            refresh()
        } catch {
            draftActionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private struct ResolvedCredentials {
        let apiKey: String
        let inboxId: String
    }

    private func currentCredentials() -> ResolvedCredentials? {
        guard let apiKey = credentialStore.loadAPIKey(forProfileId: currentProfileId) else {
            return nil
        }
        // Prefer the user's manual selection (when they've picked one
        // from the switcher); fall back to the account's primary inbox.
        let inboxId = selectedInboxId ?? accountStore.account?.primaryInboxId
        guard let resolved = inboxId, !resolved.isEmpty else { return nil }
        return ResolvedCredentials(apiKey: apiKey, inboxId: resolved)
    }

    /// Public read of the active inbox so the compose sheet's "From"
    /// hint shows whichever inbox the user is actually viewing.
    var activeViewingInboxId: String? {
        selectedInboxId ?? accountStore.account?.primaryInboxId
    }
}
