import Foundation

/// Errors raised by the Composio MCP client.
enum ComposioMCPError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey(detail: String)
    case transport(String)
    case rpc(code: Int, message: String)
    case malformedResponse(String)
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Composio API key configured."
        case .invalidAPIKey(let detail):
            let prefix = "Composio rejected the API key."
            let hint = "Grab your personal consumer key (ck_...) from dashboard.composio.dev and paste it on the Connectors tab."
            return [prefix, detail.isEmpty ? nil : "Server said: \(detail)", hint]
                .compactMap { $0 }
                .joined(separator: " ")
        case .transport(let message):
            return "Composio request failed: \(message)"
        case .rpc(let code, let message):
            return "Composio MCP error \(code): \(message)"
        case .malformedResponse(let message):
            return "Composio returned an unexpected response: \(message)"
        case .toolError(let message):
            return "Composio tool reported an error: \(message)"
        }
    }
}

// MARK: - JSON-RPC envelope

private struct JSONRPCRequest<Args: Encodable>: Encodable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: Params

    struct Params: Encodable {
        let name: String
        let arguments: Args
    }

    init(id: Int, toolName: String, arguments: Args) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = "tools/call"
        self.params = Params(name: toolName, arguments: arguments)
    }
}

private struct JSONRPCResponse: Decodable {
    let jsonrpc: String?
    let id: JSONRPCID?
    let result: MCPResult?
    let error: JSONRPCError?
}

/// JSON-RPC ids can be int OR string OR null per spec; tolerate any.
private struct JSONRPCID: Decodable {
    init(from decoder: Decoder) throws {
        let _ = try decoder.singleValueContainer()
    }
}

private struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

private struct MCPResult: Decodable {
    let content: [MCPContent]?
    let isError: Bool?
    let structuredContent: AnyDecodableValue?

    /// Returns the JSON payload Composio embeds in the first text
    /// content block, decoded as `T`. Composio's tool-call handlers
    /// JSON-stringify their responses into a single `text` block, so we
    /// re-decode that string as our typed model.
    func decodePayload<T: Decodable>(as type: T.Type) throws -> T {
        guard let blocks = content, !blocks.isEmpty else {
            throw ComposioMCPError.malformedResponse("Empty content array.")
        }
        // Prefer text blocks; fall back to first block if shape differs.
        let text = blocks.first(where: { ($0.type ?? "") == "text" })?.text
            ?? blocks.first?.text
        guard let payload = text else {
            throw ComposioMCPError.malformedResponse("No text in content blocks.")
        }
        guard let data = payload.data(using: .utf8) else {
            throw ComposioMCPError.malformedResponse("Non-UTF8 text payload.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ComposioMCPError.malformedResponse("Failed to decode tool payload: \(error.localizedDescription)")
        }
    }
}

private struct MCPContent: Decodable {
    let type: String?
    let text: String?
}

private struct AnyDecodableValue: Decodable {
    init(from decoder: Decoder) throws {
        let _ = try decoder.singleValueContainer()
    }
}

// MARK: - Client

/// Thin JSON-RPC client for Composio's hosted MCP server at
/// `connect.composio.dev/mcp`. Authenticates with the user's personal
/// "For You" API key (`x-consumer-api-key` header) — the same key the
/// agent uses on the VM.
///
/// We don't run the full MCP handshake (`initialize` →
/// `notifications/initialized`) because Composio's hosted server
/// accepts `tools/call` directly. If that ever changes, add a one-shot
/// initialize on first call gated by a flag.
final class ComposioMCPClient: @unchecked Sendable {
    static let defaultBaseURL = URL(string: "https://connect.composio.dev/mcp")!

    let baseURL: URL
    let apiKeyProvider: @Sendable () -> String?
    let urlSession: URLSession

    private let counterLock = NSLock()
    private var nextRequestId: Int = 1

    init(
        baseURL: URL = ComposioMCPClient.defaultBaseURL,
        apiKeyProvider: @escaping @Sendable () -> String?,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.urlSession = urlSession
    }

    /// Calls a single Composio meta-tool by slug (e.g.
    /// `COMPOSIO_MANAGE_CONNECTIONS`) with typed args, and decodes the
    /// embedded JSON payload as the requested response type.
    func callTool<Args: Encodable, Response: Decodable>(
        name: String,
        arguments: Args,
        responseType: Response.Type,
        timeout: TimeInterval = 60
    ) async throws -> Response {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw ComposioMCPError.missingAPIKey
        }

        let id = makeRequestId()
        let envelope = JSONRPCRequest(id: id, toolName: name, arguments: arguments)
        let body: Data
        do {
            body = try JSONEncoder().encode(envelope)
        } catch {
            throw ComposioMCPError.malformedResponse("Encoding request: \(error.localizedDescription)")
        }

        var request = URLRequest(url: baseURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // MCP servers may stream via SSE; we accept both and parse
        // whichever the server returns.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-consumer-api-key")
        request.httpBody = body

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw ComposioMCPError.transport(error.localizedDescription)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw ComposioMCPError.transport("Non-HTTP response.")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ComposioMCPError.invalidAPIKey(detail: Self.extractError(from: data))
        }

        guard (200..<300).contains(http.statusCode) else {
            throw ComposioMCPError.rpc(code: http.statusCode, message: Self.extractError(from: data))
        }

        // Composio's hosted MCP returns a regular JSON body for
        // tools/call. Parse the JSON-RPC envelope first.
        let envelopeResponse: JSONRPCResponse
        do {
            envelopeResponse = try Self.decodeRPCEnvelope(from: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        } catch {
            throw ComposioMCPError.malformedResponse("Decoding RPC envelope: \(error.localizedDescription)")
        }

        if let rpcError = envelopeResponse.error {
            throw ComposioMCPError.rpc(code: rpcError.code, message: rpcError.message)
        }

        guard let result = envelopeResponse.result else {
            throw ComposioMCPError.malformedResponse("Missing `result` in JSON-RPC response.")
        }

        if result.isError == true {
            // Surface whatever error text the tool produced.
            let detail = (result.content?.first?.text) ?? "Tool returned isError=true."
            throw ComposioMCPError.toolError(detail)
        }

        return try result.decodePayload(as: Response.self)
    }

    // MARK: - Internals

    private func makeRequestId() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        let id = nextRequestId
        nextRequestId &+= 1
        return id
    }

    /// Decodes the JSON-RPC body. If the response was server-sent
    /// events (Composio occasionally streams), pull the first `data:`
    /// line and decode that. Most calls return inline JSON though.
    private static func decodeRPCEnvelope(from data: Data, contentType: String?) throws -> JSONRPCResponse {
        let decoder = JSONDecoder()
        if let contentType, contentType.contains("text/event-stream"),
           let raw = String(data: data, encoding: .utf8) {
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if let payloadData = payload.data(using: .utf8),
                   let envelope = try? decoder.decode(JSONRPCResponse.self, from: payloadData) {
                    return envelope
                }
            }
        }
        return try decoder.decode(JSONRPCResponse.self, from: data)
    }

    private static func extractError(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let msg = error["message"] as? String { return msg }
            if let msg = json["message"] as? String { return msg }
            if let detail = json["detail"] as? String { return detail }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(280)
            .description ?? ""
    }
}
