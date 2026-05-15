import Foundation

/// High-level Composio operations the Connectors UI needs, backed by
/// the MCP server at `connect.composio.dev/mcp`. The same server, the
/// same key, the same protocol the agent on the VM uses — so users
/// only ever have to manage one credential.
struct ComposioToolkitService: Sendable {
    let mcp: ComposioMCPClient

    init(mcp: ComposioMCPClient) {
        self.mcp = mcp
    }

    // MARK: - Curated toolkit list
    //
    // Composio supports 1,000+ apps. We surface a small popular subset
    // up-front; everything else stays accessible through the agent's
    // own meta-tools when it needs them. Slugs match Composio's
    // canonical names (note `agent_mail` with an underscore).

    static let curatedToolkits: [ComposioToolkitMeta] = [
        .init(slug: "agent_mail",     name: "AgentMail",       description: "Per-agent email inboxes with full send/receive."),
        .init(slug: "gmail",          name: "Gmail",            description: "Send, read, label, and search Gmail."),
        .init(slug: "slack",          name: "Slack",            description: "Post messages, manage channels, search history."),
        .init(slug: "notion",         name: "Notion",           description: "Pages, databases, and rich-text content."),
        .init(slug: "linear",         name: "Linear",           description: "Issues, projects, and team workflows."),
        .init(slug: "github",         name: "GitHub",           description: "Repos, PRs, issues, code search."),
        .init(slug: "googlecalendar", name: "Google Calendar",  description: "Events, scheduling, availability."),
        .init(slug: "googledrive",    name: "Google Drive",     description: "Files, folders, and document operations."),
    ]

    // MARK: - Tool wrappers

    /// Lists all connected accounts across the curated toolkit set in
    /// a single batched call. Composio's MANAGE_CONNECTIONS handles
    /// multiple toolkits per request, returning per-toolkit status +
    /// per-account details.
    func listConnections(slugs: [String] = curatedToolkits.map(\.slug)) async throws -> ComposioManageConnectionsPayload {
        struct Args: Encodable {
            let toolkits: [Operation]
            struct Operation: Encodable {
                let name: String
                let action: String
            }
        }
        let args = Args(toolkits: slugs.map { Args.Operation(name: $0, action: "list") })
        let envelope: ComposioMCPEnvelope<ComposioManageConnectionsPayload> = try await mcp.callTool(
            name: "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: args,
            responseType: ComposioMCPEnvelope<ComposioManageConnectionsPayload>.self
        )
        return envelope.payload
    }

    /// Initiates an OAuth flow for one toolkit. The response includes a
    /// redirect URL that OS1 opens in the browser; the user authorizes,
    /// and the next refresh of `listConnections` reflects the new
    /// active account. Optional alias becomes the human-readable label
    /// (e.g. "personal", "work").
    func initiateConnection(slug: String, alias: String? = nil) async throws -> ComposioInitiateConnectionPayload {
        struct Args: Encodable {
            let toolkits: [Operation]
            struct Operation: Encodable {
                let name: String
                let action: String
                let alias: String?
            }
        }
        let args = Args(toolkits: [Args.Operation(name: slug, action: "add", alias: alias)])
        let envelope: ComposioMCPEnvelope<ComposioInitiatePayloadWrapper> = try await mcp.callTool(
            name: "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: args,
            responseType: ComposioMCPEnvelope<ComposioInitiatePayloadWrapper>.self
        )
        // The "add" response shape mirrors `list` but with one toolkit
        // and a redirect URL embedded somewhere on the account or at
        // the toolkit level. We unwrap defensively.
        if let toolkitResult = envelope.payload.results?[slug] ?? envelope.payload.results?.values.first {
            return ComposioInitiateConnectionPayload(
                toolkit: toolkitResult.toolkit ?? slug,
                connected_account_id: toolkitResult.accounts?.first?.id,
                redirect_url: toolkitResult.redirect_url,
                auth_link: toolkitResult.auth_link
            )
        }
        return ComposioInitiateConnectionPayload(toolkit: slug, connected_account_id: nil, redirect_url: nil, auth_link: nil)
    }

    /// Removes a connected account by id.
    func removeConnection(slug: String, accountId: String) async throws {
        struct Args: Encodable {
            let toolkits: [Operation]
            struct Operation: Encodable {
                let name: String
                let action: String
                let account_id: String
            }
        }
        let args = Args(toolkits: [Args.Operation(name: slug, action: "remove", account_id: accountId)])
        let _: ComposioMCPEnvelope<ComposioGenericPayload> = try await mcp.callTool(
            name: "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: args,
            responseType: ComposioMCPEnvelope<ComposioGenericPayload>.self
        )
    }

    /// Polls until the freshly-initiated connection becomes ACTIVE or
    /// the timeout elapses. Used right after `initiateConnection` once
    /// the user is in the browser.
    func waitForActiveConnection(
        slug: String,
        accountId: String?,
        timeoutSeconds: TimeInterval = 300
    ) async throws -> ComposioConnectedAccountSummary {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var pollIntervalNS: UInt64 = 2_000_000_000
        while Date() < deadline {
            try Task.checkCancellation()
            let payload = try await listConnections(slugs: [slug])
            if let toolkitResult = payload.results?[slug] {
                if let target = toolkitResult.accounts?.first(where: { acct in
                    if let accountId { return acct.id == accountId }
                    return acct.status?.lowercased() == "active"
                }), target.status?.lowercased() == "active" {
                    return target
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNS)
            pollIntervalNS = min(pollIntervalNS + 500_000_000, 5_000_000_000)
        }
        throw ComposioMCPError.transport("Timed out waiting for OAuth completion.")
    }
}

// MARK: - Internal payload helpers

/// `add`-action variant of the per-toolkit result that also includes
/// the redirect URL Composio returns alongside the new connection
/// record.
private struct ComposioInitiatePayloadWrapper: Decodable {
    let message: String?
    let results: [String: AddedToolkitResult]?
    let summary: ComposioConnectionsSummary?

    struct AddedToolkitResult: Decodable {
        let toolkit: String?
        let status: String?
        let accounts: [ComposioConnectedAccountSummary]?
        let redirect_url: String?
        let auth_link: String?
    }
}

/// Used when we don't care about the response shape (e.g. `remove`).
private struct ComposioGenericPayload: Decodable {
    let message: String?
}
