import Foundation

// MARK: - Wire types

/// Sign-up request. AgentMail's API uses snake_case field names.
private struct SignUpRequest: Encodable {
    let human_email: String
    let username: String
}

private struct SignUpResponse: Decodable {
    let api_key: String
    let inbox_id: String?
    let organization_id: String?
}

private struct VerifyRequest: Encodable {
    let otp_code: String
}

private struct EmptyResponse: Decodable {}

private struct InboxesListResponse: Decodable {
    let inboxes: [InboxSummary]?
    let count: Int?
}

private struct CreateInboxRequest: Encodable {
    let username: String?
    let display_name: String?
    let client_id: String?
}

struct AgentMailInboxSummary: Decodable, Equatable, Identifiable {
    let inbox_id: String
    let display_name: String?
    let domain: String?

    var id: String { inbox_id }
}

private typealias InboxSummary = AgentMailInboxSummary

// MARK: - Messages

/// Compact message record returned by `inboxes/{id}/messages` listings.
/// Full body is fetched separately via `getMessage`.
struct AgentMailMessageSummary: Decodable, Equatable, Identifiable {
    let message_id: String
    let thread_id: String?
    let inbox_id: String?
    let from: String?
    let to: [String]?
    let cc: [String]?
    let subject: String?
    let preview: String?
    let extracted_text: String?
    let timestamp: String?
    let labels: [String]?
    let created_at: String?
    let updated_at: String?
    let size: Int?

    var id: String { message_id }

    /// Best-effort one-line preview for the inbox row. Falls back from
    /// `preview` → `extracted_text` (truncated) → empty.
    var displayPreview: String {
        if let p = preview, !p.isEmpty {
            return p
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        if let t = extracted_text, !t.isEmpty {
            return t
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// True if AgentMail tagged this message as outgoing. Used for the
    /// Inbox/Sent folder split since AgentMail doesn't apply an "inbox"
    /// label to received messages — Sent has its own label, and we
    /// derive Inbox as the complement.
    var isSent: Bool {
        labels?.contains(where: { $0.lowercased() == "sent" }) ?? false
    }

    /// Splits `from` strings of the form `"Display Name <email@host>"`
    /// into a display name + email pair for prettier rendering. Falls
    /// back to the raw string when there's no `<...>`.
    var fromDisplayName: String {
        guard let from else { return "" }
        if let openIdx = from.firstIndex(of: "<"),
           openIdx > from.startIndex {
            let name = from[..<openIdx]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return fromEmail
    }

    var fromEmail: String {
        guard let from else { return "" }
        if let openIdx = from.firstIndex(of: "<"),
           let closeIdx = from.firstIndex(of: ">"),
           openIdx < closeIdx {
            return String(from[from.index(after: openIdx)..<closeIdx])
        }
        return from
    }
}

/// Full message detail. Includes body in both text and HTML forms when
/// available, plus attachment metadata.
struct AgentMailMessage: Decodable, Equatable, Identifiable {
    let message_id: String
    let thread_id: String?
    let inbox_id: String?
    let from: String?
    let to: [String]?
    let cc: [String]?
    let bcc: [String]?
    let reply_to: [String]?
    let subject: String?
    let text: String?
    let html: String?
    let extracted_text: String?
    let extracted_html: String?
    let preview: String?
    let timestamp: String?
    let labels: [String]?
    let attachments: [AgentMailAttachmentSummary]?
    let in_reply_to: String?
    let references: [String]?

    var id: String { message_id }
}

struct AgentMailAttachmentSummary: Decodable, Equatable, Identifiable {
    let attachment_id: String
    let filename: String?
    let content_type: String?
    let size: Int?

    var id: String { attachment_id }
}

private struct AgentMailMessagesListResponse: Decodable {
    let messages: [AgentMailMessageSummary]?
    let count: Int?
    let next_page_token: String?
}

private struct AgentMailSendRequest: Encodable {
    let to: [String]
    let cc: [String]?
    let bcc: [String]?
    let subject: String
    let text: String?
    let html: String?
    let reply_to: [String]?
    let labels: [String]?
}

private struct AgentMailReplyRequest: Encodable {
    let to: [String]?
    let cc: [String]?
    let bcc: [String]?
    let text: String?
    let html: String?
    let labels: [String]?
}

// MARK: - Drafts

/// Compact draft record returned by `inboxes/{id}/drafts` listings.
/// AgentMail auto-applies the `scheduled` label to drafts with a future
/// `send_at`, so the same model handles both regular drafts and
/// scheduled sends (visually distinguished by `send_at` presence).
struct AgentMailDraftSummary: Decodable, Equatable, Identifiable {
    let draft_id: String
    let inbox_id: String?
    let thread_id: String?
    let to: [String]?
    let cc: [String]?
    let subject: String?
    let preview: String?
    let send_at: String?           // ISO 8601 timestamp when this draft is scheduled to send
    let send_status: String?       // "scheduled", "sent", "failed", etc. (when send_at is set)
    let labels: [String]?
    let created_at: String?
    let updated_at: String?

    var id: String { draft_id }

    /// True if this draft is set to auto-send at a future time.
    var isScheduled: Bool {
        (send_at?.isEmpty == false) && (send_status?.lowercased() != "sent")
    }

    /// One-line preview, falling back from `preview` to truncated body.
    var displayPreview: String {
        if let p = preview, !p.isEmpty {
            return p
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}

/// Full draft detail. Includes both text and html bodies plus
/// attachment metadata.
struct AgentMailDraft: Decodable, Equatable, Identifiable {
    let draft_id: String
    let inbox_id: String?
    let thread_id: String?
    let to: [String]?
    let cc: [String]?
    let bcc: [String]?
    let reply_to: [String]?
    let subject: String?
    let text: String?
    let html: String?
    let in_reply_to: String?
    let references: [String]?
    let send_at: String?
    let send_status: String?
    let labels: [String]?
    let attachments: [AgentMailAttachmentSummary]?
    let created_at: String?
    let updated_at: String?

    var id: String { draft_id }
}

private struct AgentMailDraftsListResponse: Decodable {
    let drafts: [AgentMailDraftSummary]?
    let count: Int?
    let next_page_token: String?
}

private struct AgentMailCreateDraftRequest: Encodable {
    let to: [String]?
    let cc: [String]?
    let bcc: [String]?
    let subject: String?
    let text: String?
    let html: String?
    let in_reply_to: String?
    let references: [String]?
    let send_at: String?
    let labels: [String]?
}

// MARK: - Errors

enum AgentMailError: LocalizedError, Equatable {
    /// The provided email already has an AgentMail account — sign-up is
    /// rejected for already-signed-up addresses. Caller should fall through
    /// to BYOK.
    case emailAlreadyRegistered(message: String)

    /// OTP verification failed (wrong code, expired).
    case invalidOTP(message: String)

    /// API key rejected (used by BYOK validation).
    case invalidAPIKey

    /// Network or other transport-level failure.
    case transport(String)

    /// Unexpected non-2xx response that isn't covered above.
    case remote(status: Int, message: String)

    /// Invalid input from the caller (e.g. empty username).
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .emailAlreadyRegistered(let message):
            return "This email is already registered with AgentMail. \(message.isEmpty ? "Use the existing-account path instead." : message)"
        case .invalidOTP(let message):
            return message.isEmpty ? "Invalid OTP code." : message
        case .invalidAPIKey:
            return "AgentMail rejected this API key. Double-check it from console.agentmail.to."
        case .transport(let message):
            return "AgentMail request failed: \(message)"
        case .remote(let status, let message):
            return "AgentMail returned \(status): \(message)"
        case .invalidInput(let message):
            return message
        }
    }
}

// MARK: - HTTP client

/// Minimal HTTP client for AgentMail's REST API at `https://api.agentmail.to`.
/// Mirrors the shape of `OrgoHTTPClient`. Auth is `Bearer <api_key>` for
/// authenticated routes; the sign-up route is unauthenticated.
struct AgentMailHTTPClient: Sendable {
    static let defaultBaseURL = URL(string: "https://api.agentmail.to")!

    let baseURL: URL
    let urlSession: URLSession

    init(
        baseURL: URL = AgentMailHTTPClient.defaultBaseURL,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        bearerKey: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerKey {
            request.setValue("Bearer \(bearerKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request)
    }

    func get<Response: Decodable>(
        path: String,
        query: [String: String] = [:],
        bearerKey: String,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw AgentMailError.invalidInput("Couldn't build URL for path \(path).")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerKey)", forHTTPHeaderField: "Authorization")
        return try await execute(request)
    }

    func delete(
        path: String,
        bearerKey: String,
        timeout: TimeInterval = 30
    ) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(bearerKey)", forHTTPHeaderField: "Authorization")
        let _: EmptyResponse = try await execute(request)
    }

    private func execute<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw AgentMailError.transport(error.localizedDescription)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw AgentMailError.transport("Non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.extractMessage(from: data)
            switch http.statusCode {
            case 401:
                throw AgentMailError.invalidAPIKey
            case 409:
                throw AgentMailError.emailAlreadyRegistered(message: detail)
            case 400:
                let lower = detail.lowercased()
                if lower.contains("already") && (lower.contains("registered") || lower.contains("exists") || lower.contains("signed up")) {
                    throw AgentMailError.emailAlreadyRegistered(message: detail)
                }
                if lower.contains("otp") || lower.contains("verification") {
                    throw AgentMailError.invalidOTP(message: detail)
                }
                throw AgentMailError.remote(status: http.statusCode, message: detail)
            default:
                throw AgentMailError.remote(status: http.statusCode, message: detail)
            }
        }

        if Response.self == EmptyResponse.self {
            // Don't try to decode empty success bodies (verify often returns 204/{}).
            return EmptyResponse() as! Response
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AgentMailError.transport("Failed to decode AgentMail response: \(error.localizedDescription)")
        }
    }

    private static func extractMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail", "error_description"] {
                if let value = json[key] as? String, !value.isEmpty { return value }
            }
            if let nested = json["error"] as? [String: Any], let msg = nested["message"] as? String {
                return msg
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(280)
            .description ?? ""
    }
}

// MARK: - Service

/// High-level operations the Mail tab needs. Stateless — credentials and
/// account metadata are stored separately in `AgentMailCredentialStore` /
/// `AgentMailAccountStore`. The view-model layer coordinates them.
struct AgentMailService: Sendable {
    private let http: AgentMailHTTPClient

    init(http: AgentMailHTTPClient = AgentMailHTTPClient()) {
        self.http = http
    }

    /// Programmatic agent sign-up. Creates a new AgentMail account under the
    /// provided email (which receives a 6-digit OTP) and returns the
    /// generated API key + default inbox.
    ///
    /// Throws `.emailAlreadyRegistered` when the email already has an
    /// account at console.agentmail.to — caller should route to BYOK.
    func signUp(humanEmail: String, username: String) async throws -> AgentMailSignUpResult {
        let trimmedEmail = humanEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, trimmedEmail.contains("@") else {
            throw AgentMailError.invalidInput("Enter a valid email address.")
        }
        guard !trimmedUsername.isEmpty else {
            throw AgentMailError.invalidInput("Enter a username for the agent inbox.")
        }

        let body = SignUpRequest(human_email: trimmedEmail, username: trimmedUsername)
        let response: SignUpResponse = try await http.post(path: "agent/sign-up", body: body)
        return AgentMailSignUpResult(
            apiKey: response.api_key,
            primaryInboxId: response.inbox_id,
            organizationId: response.organization_id,
            humanEmail: trimmedEmail
        )
    }

    /// Verifies the OTP code emailed to the human. After success, the API
    /// key returned by sign-up has full permissions.
    func verify(apiKey: String, otpCode: String) async throws {
        let trimmedOTP = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOTP.isEmpty else {
            throw AgentMailError.invalidInput("Enter the OTP code from your email.")
        }
        let body = VerifyRequest(otp_code: trimmedOTP)
        let _: EmptyResponse = try await http.post(path: "agent/verify", body: body, bearerKey: apiKey)
    }

    /// Validates a BYOK API key by listing inboxes. Returns the inbox list on
    /// success; throws `.invalidAPIKey` on 401.
    func validateAPIKey(_ apiKey: String) async throws -> [AgentMailInboxSummary] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentMailError.invalidInput("Paste your AgentMail API key.")
        }
        return try await listInboxes(apiKey: trimmed)
    }

    /// Returns every inbox under the account associated with the API key.
    /// Used by the Mail tab's inbox switcher so users can view any inbox
    /// without changing their agent's primary inbox.
    func listInboxes(apiKey: String, limit: Int = 100) async throws -> [AgentMailInboxSummary] {
        let response: InboxesListResponse = try await http.get(
            path: "v0/inboxes",
            query: ["limit": "\(limit)"],
            bearerKey: apiKey
        )
        return response.inboxes ?? []
    }

    /// Creates a new inbox under the account associated with `apiKey`.
    /// Username becomes the local part of the inbox address
    /// (`<username>@agentmail.to` on the default domain).
    func createInbox(
        apiKey: String,
        username: String?,
        displayName: String?,
        clientId: String? = nil
    ) async throws -> AgentMailInboxSummary {
        let body = CreateInboxRequest(
            username: username?.trimmingCharacters(in: .whitespacesAndNewlines),
            display_name: displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            client_id: clientId
        )
        return try await http.post(
            path: "v0/inboxes",
            body: body,
            bearerKey: apiKey
        )
    }

    // MARK: - Inbox browsing

    /// Lists messages in an inbox, optionally filtered by labels
    /// (`["sent"]` for the Sent folder, `["inbox"]` for the default
    /// view, etc.). Returns oldest-first or newest-first per
    /// `ascending`. Defaults: 50 items, newest first.
    func listMessages(
        apiKey: String,
        inboxId: String,
        labels: [String]? = nil,
        limit: Int = 50,
        ascending: Bool = false,
        before: String? = nil,
        after: String? = nil,
        pageToken: String? = nil,
        includeSpam: Bool = false
    ) async throws -> [AgentMailMessageSummary] {
        var query: [String: String] = [
            "limit": "\(limit)",
            "ascending": ascending ? "true" : "false"
        ]
        if let labels, !labels.isEmpty {
            query["labels"] = labels.joined(separator: ",")
        }
        if let before { query["before"] = before }
        if let after { query["after"] = after }
        if let pageToken { query["page_token"] = pageToken }
        if includeSpam { query["include_spam"] = "true" }

        let response: AgentMailMessagesListResponse = try await http.get(
            path: "v0/inboxes/\(inboxId)/messages",
            query: query,
            bearerKey: apiKey
        )
        return response.messages ?? []
    }

    /// Fetches the full body + attachment metadata of a message.
    func getMessage(
        apiKey: String,
        inboxId: String,
        messageId: String
    ) async throws -> AgentMailMessage {
        try await http.get(
            path: "v0/inboxes/\(inboxId)/messages/\(messageId)",
            bearerKey: apiKey
        )
    }

    /// Sends a brand-new email from an inbox. Either `text` or `html`
    /// (or both) must be provided.
    func sendMessage(
        apiKey: String,
        inboxId: String,
        to: [String],
        subject: String,
        text: String? = nil,
        html: String? = nil,
        cc: [String]? = nil,
        bcc: [String]? = nil,
        replyTo: [String]? = nil,
        labels: [String]? = nil
    ) async throws -> AgentMailMessage {
        guard !to.isEmpty else {
            throw AgentMailError.invalidInput("At least one recipient is required.")
        }
        guard !(text?.isEmpty ?? true) || !(html?.isEmpty ?? true) else {
            throw AgentMailError.invalidInput("Message body is empty.")
        }
        let body = AgentMailSendRequest(
            to: to,
            cc: cc?.isEmpty == true ? nil : cc,
            bcc: bcc?.isEmpty == true ? nil : bcc,
            subject: subject,
            text: text,
            html: html,
            reply_to: replyTo,
            labels: labels
        )
        return try await http.post(
            path: "v0/inboxes/\(inboxId)/messages/send",
            body: body,
            bearerKey: apiKey
        )
    }

    // MARK: - Drafts

    /// Lists drafts in an inbox, optionally filtered by labels (e.g.
    /// `["scheduled"]` to surface scheduled sends only).
    func listDrafts(
        apiKey: String,
        inboxId: String,
        labels: [String]? = nil,
        limit: Int = 100,
        ascending: Bool = false,
        pageToken: String? = nil
    ) async throws -> [AgentMailDraftSummary] {
        var query: [String: String] = [
            "limit": "\(limit)",
            "ascending": ascending ? "true" : "false"
        ]
        if let labels, !labels.isEmpty {
            query["labels"] = labels.joined(separator: ",")
        }
        if let pageToken { query["page_token"] = pageToken }
        let response: AgentMailDraftsListResponse = try await http.get(
            path: "v0/inboxes/\(inboxId)/drafts",
            query: query,
            bearerKey: apiKey
        )
        return response.drafts ?? []
    }

    /// Creates a new draft in an inbox. Both `text` and `html` may be
    /// empty — drafts are explicitly allowed to be partial. For
    /// scheduled sends, set `send_at` to an ISO 8601 future timestamp;
    /// AgentMail auto-applies the `scheduled` label.
    func createDraft(
        apiKey: String,
        inboxId: String,
        to: [String]? = nil,
        cc: [String]? = nil,
        bcc: [String]? = nil,
        subject: String? = nil,
        text: String? = nil,
        html: String? = nil,
        inReplyTo: String? = nil,
        references: [String]? = nil,
        sendAt: String? = nil,
        labels: [String]? = nil
    ) async throws -> AgentMailDraft {
        let body = AgentMailCreateDraftRequest(
            to: (to?.isEmpty ?? true) ? nil : to,
            cc: (cc?.isEmpty ?? true) ? nil : cc,
            bcc: (bcc?.isEmpty ?? true) ? nil : bcc,
            subject: subject?.isEmpty == true ? nil : subject,
            text: text?.isEmpty == true ? nil : text,
            html: html?.isEmpty == true ? nil : html,
            in_reply_to: inReplyTo,
            references: references,
            send_at: sendAt,
            labels: labels
        )
        return try await http.post(
            path: "v0/inboxes/\(inboxId)/drafts",
            body: body,
            bearerKey: apiKey
        )
    }

    /// Fetches the full body + attachments of a draft.
    func getDraft(
        apiKey: String,
        inboxId: String,
        draftId: String
    ) async throws -> AgentMailDraft {
        try await http.get(
            path: "v0/inboxes/\(inboxId)/drafts/\(draftId)",
            bearerKey: apiKey
        )
    }

    /// Sends a previously-saved draft immediately, regardless of any
    /// `send_at` schedule. Returns the resulting message record.
    func sendDraft(
        apiKey: String,
        inboxId: String,
        draftId: String
    ) async throws -> AgentMailMessage {
        let body: [String: String] = [:]   // empty body — endpoint takes no params
        return try await http.post(
            path: "v0/inboxes/\(inboxId)/drafts/\(draftId)/send",
            body: body,
            bearerKey: apiKey
        )
    }

    /// Deletes a draft. For scheduled sends this also cancels the send.
    func deleteDraft(
        apiKey: String,
        inboxId: String,
        draftId: String
    ) async throws {
        try await http.delete(
            path: "v0/inboxes/\(inboxId)/drafts/\(draftId)",
            bearerKey: apiKey
        )
    }

    /// Replies to an existing message in its thread. Recipients default
    /// to "reply to the original sender" if `to` is omitted.
    func replyToMessage(
        apiKey: String,
        inboxId: String,
        messageId: String,
        to: [String]? = nil,
        cc: [String]? = nil,
        bcc: [String]? = nil,
        text: String? = nil,
        html: String? = nil,
        labels: [String]? = nil
    ) async throws -> AgentMailMessage {
        guard !(text?.isEmpty ?? true) || !(html?.isEmpty ?? true) else {
            throw AgentMailError.invalidInput("Reply body is empty.")
        }
        let body = AgentMailReplyRequest(
            to: to,
            cc: cc?.isEmpty == true ? nil : cc,
            bcc: bcc?.isEmpty == true ? nil : bcc,
            text: text,
            html: html,
            labels: labels
        )
        return try await http.post(
            path: "v0/inboxes/\(inboxId)/messages/\(messageId)/reply",
            body: body,
            bearerKey: apiKey
        )
    }
}

struct AgentMailSignUpResult: Equatable {
    let apiKey: String
    let primaryInboxId: String?
    let organizationId: String?
    let humanEmail: String
}
