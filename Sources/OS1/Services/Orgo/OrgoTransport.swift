import Foundation

// MARK: - Wire types

private struct BashRequest: Encodable {
    let command: String
}

private struct BashResponse: Decodable {
    let success: Bool
    let output: String
}

private struct ExecRequest: Encodable {
    let code: String
    let timeout: Int
}

private struct ExecResponse: Decodable {
    let success: Bool
    let output: String
    let timeout: Bool
}

private struct EnsureRunningResponse: Decodable {}

private struct ComputerInfoResponse: Decodable {
    let id: String?
    let fly_instance_id: String?
    let url: String?
    let status: String?
}

private struct VNCPasswordResponse: Decodable {
    let password: String
}

// MARK: - Direct VM connection

struct DirectVMConnection: Sendable, Equatable {
    let baseURL: URL
    let vncPassword: String
}

struct OrgoTerminalEndpoint: Sendable, Equatable {
    let webSocketURL: URL
    let vncPassword: String
}

struct OrgoVNCEndpoint: Sendable, Equatable {
    let webSocketURL: URL
    let vncPassword: String
}

private actor DirectVMCache {
    private var connections: [String: DirectVMConnection] = [:]

    func get(_ id: String) -> DirectVMConnection? { connections[id] }
    func set(_ id: String, _ value: DirectVMConnection) { connections[id] = value }
    func evict(_ id: String) { connections.removeValue(forKey: id) }
}

// MARK: - OrgoTransport

final class OrgoTransport: RemoteTransport, @unchecked Sendable {
    private let httpClient: OrgoHTTPClient
    private let urlSession: URLSession
    private let directVMCache = DirectVMCache()

    init(httpClient: OrgoHTTPClient, urlSession: URLSession = .shared) {
        self.httpClient = httpClient
        self.urlSession = urlSession
    }

    convenience init(apiKeyProvider: @escaping @Sendable () -> String?) {
        self.init(httpClient: OrgoHTTPClient(apiKeyProvider: apiKeyProvider))
    }

    // MARK: - RemoteTransport

    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?,
        allocateTTY: Bool
    ) async throws -> RemoteCommandResult {
        let computerId = try requireComputerId(from: connection)

        // Orgo's /bash hardcodes exit_code: 0, so we wrap every command with a
        // per-call UUID-nonce sentinel and parse the trailing line for the
        // real exit code. The nonce eliminates collision risk if the command
        // output happens to contain the literal marker prefix.
        let sentinelMarker = OrgoTransport.makeSentinelMarker()
        let wrapped: String
        if let standardInput {
            // /bash has no stdin parameter; pipe via base64 heredoc so binary
            // and shell-special bytes survive intact.
            let base64 = standardInput.base64EncodedString()
            wrapped = "{ printf '%s' '\(base64)' | base64 -d | \(remoteCommand); printf '\\n\(sentinelMarker):%d\\n' \"$?\"; } 2>&1"
        } else {
            wrapped = "{ \(remoteCommand); printf '\\n\(sentinelMarker):%d\\n' \"$?\"; } 2>&1"
        }

        let response: BashResponse = try await performBashOrExec(
            computerId: computerId,
            pathSuffix: "bash",
            body: BashRequest(command: wrapped),
            timeout: 90
        )

        let (cleanedOutput, parsedExitCode) = parseSentinelTrailer(
            from: response.output,
            sentinelMarker: sentinelMarker
        )

        // If the sentinel never landed (server rejected the wrapped command,
        // killed it, etc.), fall back to the response's success flag.
        let exitCode: Int32
        if let parsed = parsedExitCode {
            exitCode = parsed
        } else if response.success {
            exitCode = 0
        } else {
            exitCode = 1
        }

        return RemoteCommandResult(
            stdout: cleanedOutput,
            stderr: "",
            exitCode: exitCode
        )
    }

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response {
        try await runPython(
            on: connection,
            pythonScript: pythonScript,
            serverTimeoutSeconds: 60,
            responseType: responseType
        )
    }

    /// Like `executeJSON`, but lets the caller bump the server-side /exec
    /// timeout up to the platform's 300s ceiling. Use this for legitimate
    /// long-running ops (e.g. installing Hermes Agent) that would never
    /// finish under the 60s default. The HTTP timeout is sized to the
    /// server timeout plus a 30s buffer.
    ///
    /// Bypasses the platform proxy by default and goes directly to the
    /// VM, since the proxy enforces its own ~30s request timeout that
    /// any long-running op will blow through.
    func executeLongPython<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        serverTimeoutSeconds: Int,
        responseType: Response.Type
    ) async throws -> Response {
        let clamped = min(max(serverTimeoutSeconds, 1), 300)
        return try await runPython(
            on: connection,
            pythonScript: pythonScript,
            serverTimeoutSeconds: clamped,
            preferDirect: true,
            responseType: responseType
        )
    }

    private func runPython<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        serverTimeoutSeconds: Int,
        preferDirect: Bool = false,
        responseType: Response.Type
    ) async throws -> Response {
        let computerId = try requireComputerId(from: connection)

        let result: ExecResponse = try await performBashOrExec(
            computerId: computerId,
            pathSuffix: "exec",
            body: ExecRequest(code: pythonScript, timeout: serverTimeoutSeconds),
            timeout: TimeInterval(serverTimeoutSeconds + 30),
            preferDirect: preferDirect
        )

        guard result.success else {
            // Empirically, /exec returns success=false with the traceback in
            // `output` for Python errors, and success=false with empty
            // `output` when the server-side timeout fires (the `timeout`
            // boolean is unreliable — was observed false during a real
            // timeout).
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if !trimmed.isEmpty {
                detail = trimmed
            } else {
                detail = "Orgo /exec failed with no output (likely timeout)."
            }
            throw RemoteTransportError.remoteFailure(detail)
        }

        guard let data = result.output.data(using: .utf8) else {
            throw RemoteTransportError.invalidResponse("Orgo /exec output was not valid UTF-8.")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteTransportError.invalidResponse(
                "Failed to decode Orgo /exec JSON: \(error.localizedDescription)\n\n\(result.output)"
            )
        }
    }

    // validateSuccessfulExit comes from RemoteTransport's protocol-extension
    // default implementation; OrgoTransport doesn't need a custom override.

    // MARK: - VM lifecycle

    /// Resolves the websocket terminal endpoint for a computer.
    /// `wss://<fly_instance_id>.orgo.dev/terminal?token=<vncPassword>&cols=<n>&rows=<n>`.
    /// Reuses the same direct-VM resolution + cache that the HTTP fallback
    /// path uses.
    func resolveTerminalEndpoint(
        computerId: String,
        cols: Int,
        rows: Int
    ) async throws -> OrgoTerminalEndpoint {
        let direct = try await resolveDirectVMConnection(computerId: computerId)
        guard var components = URLComponents(url: direct.baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteTransportError.invalidConnection("Couldn't parse direct VM URL.")
        }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/terminal"
        components.queryItems = [
            URLQueryItem(name: "token", value: direct.vncPassword),
            URLQueryItem(name: "cols", value: String(cols)),
            URLQueryItem(name: "rows", value: String(rows))
        ]
        guard let url = components.url else {
            throw RemoteTransportError.invalidConnection("Couldn't build terminal WebSocket URL.")
        }
        return OrgoTerminalEndpoint(webSocketURL: url, vncPassword: direct.vncPassword)
    }

    /// Resolves a websockify endpoint for the VM's VNC server. The Fly
    /// instance hosts a websockify bridge at `/websockify` that translates
    /// WebSocket frames to VNC TCP, gated by the VNC password as a token.
    /// The returned URL is consumed by noVNC's RFB client (running inside
    /// a `WKWebView`) to render the VM's screen.
    func resolveVNCEndpoint(computerId: String) async throws -> OrgoVNCEndpoint {
        let direct = try await resolveDirectVMConnection(computerId: computerId)
        guard var components = URLComponents(url: direct.baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteTransportError.invalidConnection("Couldn't parse direct VM URL.")
        }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/websockify"
        components.queryItems = [
            URLQueryItem(name: "token", value: direct.vncPassword)
        ]
        guard let url = components.url else {
            throw RemoteTransportError.invalidConnection("Couldn't build VNC WebSocket URL.")
        }
        return OrgoVNCEndpoint(webSocketURL: url, vncPassword: direct.vncPassword)
    }

    /// Wakes a suspended VM. Idempotent — safe to call on already-running VMs.
    func ensureRunning(computerId: String) async throws {
        let _: EnsureRunningResponse = try await httpClient.post(
            path: "computers/\(computerId)/ensure-running",
            body: [String: String](),
            timeout: 30
        )
    }

    // MARK: - Proxy → direct fallback

    /// Tries the platform proxy first. On a 5xx that looks like a VM-routing
    /// problem (suspended VM, stale port, ECONNREFUSED), falls back to the
    /// direct VM URL `https://<fly_instance_id>.orgo.dev/<path>` with the
    /// VNC password as the bearer token. Caches the resolved direct
    /// connection per computer.
    private func performBashOrExec<Request: Encodable, Response: Decodable>(
        computerId: String,
        pathSuffix: String,
        body: Request,
        timeout: TimeInterval,
        preferDirect: Bool = false
    ) async throws -> Response {
        // For known long-running ops, skip the proxy entirely — the platform
        // enforces a ~30s request timeout there that any long op will blow
        // through, costing the user a wasted 30s wait before fallback.
        if preferDirect {
            let direct = try await resolveDirectVMConnection(computerId: computerId)
            do {
                return try await directPost(
                    connection: direct,
                    path: pathSuffix,
                    body: body,
                    timeout: timeout
                )
            } catch {
                await directVMCache.evict(computerId)
                throw error
            }
        }

        do {
            return try await httpClient.post(
                path: "computers/\(computerId)/\(pathSuffix)",
                body: body,
                timeout: timeout
            )
        } catch let proxyError as RemoteTransportError where OrgoTransport.shouldFallbackToDirect(proxyError) {
            let direct = try await resolveDirectVMConnection(computerId: computerId)
            do {
                return try await directPost(
                    connection: direct,
                    path: pathSuffix,
                    body: body,
                    timeout: timeout
                )
            } catch {
                // Direct also failed — evict so a next call resolves fresh
                // endpoints (port can change after VM restart). Surface this
                // error so the user sees the most recent failure.
                await directVMCache.evict(computerId)
                throw error
            }
        }
    }

    private static func shouldFallbackToDirect(_ error: RemoteTransportError) -> Bool {
        guard case .remoteFailure(let message) = error else { return false }
        // OrgoHTTPClient formats 5xx as "Orgo <status>: <detail>".
        guard message.hasPrefix("Orgo 5") else { return false }
        let lower = message.lowercased()
        return lower.contains("econnrefused")
            || lower.contains("etimedout")
            || lower.contains("502")
            || lower.contains("503")
            || lower.contains("504")
            || lower.contains("bad gateway")
            || lower.contains("gateway timeout")
            || lower.contains("service unavailable")
            // The platform proxy enforces its own ~30s request timeout.
            // Long /exec calls (e.g. Hermes install) blow through it even
            // when the VM is healthy. Going direct sidesteps the proxy.
            || lower.contains("timeout")
    }

    private func resolveDirectVMConnection(computerId: String) async throws -> DirectVMConnection {
        if let cached = await directVMCache.get(computerId) {
            return cached
        }

        // Wake the VM if needed before resolving endpoints.
        try? await ensureRunning(computerId: computerId)

        // fly_instance_id drives the HTTPS subdomain — `<id>.orgo.dev`.
        let info: ComputerInfoResponse = try await httpClient.get(
            path: "computers/\(computerId)",
            timeout: 15
        )
        guard let flyId = info.fly_instance_id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !flyId.isEmpty else {
            throw RemoteTransportError.invalidResponse(
                "Computer has no fly_instance_id; cannot reach the VM directly."
            )
        }
        guard let baseURL = URL(string: "https://\(flyId).orgo.dev") else {
            throw RemoteTransportError.invalidResponse(
                "Couldn't build direct VM URL for fly_instance_id \(flyId)."
            )
        }

        // VNC password is the bearer token for direct VM API calls.
        let vnc: VNCPasswordResponse = try await httpClient.get(
            path: "computers/\(computerId)/vnc-password",
            timeout: 15
        )

        let connection = DirectVMConnection(baseURL: baseURL, vncPassword: vnc.password)
        await directVMCache.set(computerId, connection)
        return connection
    }

    private func directPost<Request: Encodable, Response: Decodable>(
        connection: DirectVMConnection,
        path: String,
        body: Request,
        timeout: TimeInterval
    ) async throws -> Response {
        let url = connection.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(connection.vncPassword)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw RemoteTransportError.localFailure(
                "Direct VM request failed: \(error.localizedDescription)"
            )
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw RemoteTransportError.invalidResponse("Direct VM returned non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300) ?? ""
            throw RemoteTransportError.remoteFailure(
                "Direct VM \(http.statusCode): \(preview)"
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteTransportError.invalidResponse(
                "Failed to decode direct VM response: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private func requireComputerId(from connection: ConnectionProfile) throws -> String {
        guard case .orgo(let cfg) = connection.transport else {
            throw RemoteTransportError.invalidConnection(
                "OrgoTransport requires an Orgo connection profile."
            )
        }
        let trimmed = cfg.computerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteTransportError.invalidConnection(
                "Orgo connection profile has no computer ID."
            )
        }
        return trimmed
    }

    private static func makeSentinelMarker() -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "__ORGO_RC_\(nonce)__"
    }

    private func parseSentinelTrailer(
        from rawOutput: String,
        sentinelMarker: String
    ) -> (cleanedOutput: String, exitCode: Int32?) {
        // Match the LAST occurrence of `\n<marker>:N` where N is an integer,
        // anchored at the end. The leading newline ensures we ignore inline
        // appearances of the marker string in the command's own output.
        let escapedMarker = NSRegularExpression.escapedPattern(for: sentinelMarker)
        let pattern = "\\n\(escapedMarker):(-?\\d+)\\s*\\Z"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (rawOutput, nil)
        }
        let nsRange = NSRange(rawOutput.startIndex..., in: rawOutput)
        guard let match = regex.firstMatch(in: rawOutput, options: [], range: nsRange) else {
            return (rawOutput, nil)
        }
        guard match.numberOfRanges >= 2,
              let codeRange = Range(match.range(at: 1), in: rawOutput),
              let exitCode = Int32(rawOutput[codeRange]) else {
            return (rawOutput, nil)
        }
        guard let trailerRange = Range(match.range, in: rawOutput) else {
            return (rawOutput, nil)
        }
        let cleaned = String(rawOutput[..<trailerRange.lowerBound])
        return (cleaned, exitCode)
    }
}
