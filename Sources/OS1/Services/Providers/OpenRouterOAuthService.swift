import AppKit
import CryptoKit
import Foundation

/// Errors surfaced by the OpenRouter OAuth flow.
enum OpenRouterOAuthError: LocalizedError {
    case alreadyInProgress
    case unsupportedCallback(URL)
    case missingCode
    case cancelled
    case timeout
    case exchangeFailed(detail: String)
    case malformedResponse(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "An OpenRouter sign-in is already in progress."
        case .unsupportedCallback(let url):
            return "Got an unexpected URL back from OpenRouter: \(url.absoluteString)"
        case .missingCode:
            return "OpenRouter didn't return an authorization code."
        case .cancelled:
            return "OpenRouter sign-in was cancelled."
        case .timeout:
            return "OpenRouter sign-in didn't complete in time."
        case .exchangeFailed(let detail):
            return "OpenRouter rejected the code exchange. \(detail)"
        case .malformedResponse(let message):
            return "OpenRouter response wasn't shaped as expected: \(message)"
        case .transport(let message):
            return "Couldn't reach OpenRouter: \(message)"
        }
    }
}

/// Handles the "Sign in with OpenRouter" button in the Providers tab.
///
/// Flow:
///   1. `beginAuth()` generates a fresh code_verifier (RFC 7636 §4.1) +
///      S256 code_challenge, builds the auth URL, opens it in the
///      user's default browser, and returns an awaiting Task.
///   2. macOS hands the `os1://oauth/openrouter?code=…` redirect to
///      `OS1App` via `.onOpenURL`. AppState forwards it here through
///      `handleCallback(_:)`.
///   3. We POST to `https://openrouter.ai/api/v1/auth/keys` with the
///      original verifier; OpenRouter returns `{key: "sk-or-v1-…"}`.
///   4. The continuation in (1) resolves with that key.
///
/// Single in-flight session at a time — opening a second auth before
/// the first either completes or times out throws `.alreadyInProgress`.
@MainActor
final class OpenRouterOAuthService {
    static let callbackScheme = "os1"
    static let callbackHost = "oauth"
    static let callbackPath = "/openrouter"
    static let authBaseURL = URL(string: "https://openrouter.ai/auth")!
    static let exchangeURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    /// Reasonable upper bound. Five minutes covers "user got distracted
    /// mid-auth" without leaving a stale verifier in memory forever.
    static let timeoutSeconds: TimeInterval = 300

    struct Result: Equatable {
        let apiKey: String
        let userId: String?
    }

    private let urlSession: URLSession
    private let urlOpener: @MainActor (URL) -> Void

    private var inFlight: Pending?

    init(
        urlSession: URLSession = .shared,
        urlOpener: @escaping @MainActor (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.urlSession = urlSession
        self.urlOpener = urlOpener
    }

    /// True while a sign-in is in flight (browser open, awaiting callback).
    var isInProgress: Bool { inFlight != nil }

    /// Builds the auth URL, opens it in the user's browser, and waits
    /// for the redirect. Throws on cancel, timeout, or exchange failure.
    func beginAuth() async throws -> Result {
        if inFlight != nil { throw OpenRouterOAuthError.alreadyInProgress }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.makeCodeChallenge(from: verifier)
        let callbackURL = Self.callbackURL()
        let authURL = Self.makeAuthURL(callbackURL: callbackURL, codeChallenge: challenge)

        return try await withCheckedThrowingContinuation { continuation in
            // Set up the pending state BEFORE opening the browser, so
            // the callback (which can race in <100ms on a logged-in
            // user) finds something to resolve.
            let pending = Pending(verifier: verifier, continuation: continuation)
            inFlight = pending

            // Watchdog — if the user closes the browser tab without
            // authorizing we don't want the verifier to live forever.
            // The cancellation check matters: when handleCallback or
            // cancel() cancels this task, `try?` swallows the throw
            // from sleep, so without the guard we'd still call
            // failPending — and if the user has since started a fresh
            // auth, that fail would resolve the *new* pending with a
            // spurious timeout.
            pending.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                self?.failPending(with: .timeout)
            }

            urlOpener(authURL)
        }
    }

    /// Receives the URL macOS hands us via `.onOpenURL`. Returns true
    /// iff the URL was consumed (so the caller can ignore it elsewhere).
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.callbackScheme,
              url.host?.lowercased() == Self.callbackHost,
              url.path == Self.callbackPath else {
            return false
        }
        guard let pending = inFlight else {
            // No one's waiting — drop the URL silently. Probably a
            // duplicate redirect after the user already finished.
            return true
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first(where: { $0.name == "code" })?.value

        guard let code, !code.isEmpty else {
            failPending(with: .missingCode)
            return true
        }

        // Detach the pending state so a second callback can't double-resume.
        inFlight = nil
        pending.timeoutTask?.cancel()

        Task { [weak self] in
            await self?.exchange(code: code, verifier: pending.verifier, continuation: pending.continuation)
        }
        return true
    }

    /// Cancels the in-flight flow (e.g. user pressed "Cancel" in the UI).
    func cancel() {
        failPending(with: .cancelled)
    }

    // MARK: - Internals

    /// Class so the watchdog Task can assign back into `timeoutTask`
    /// after the parent stored the Pending in `inFlight`. Reference
    /// semantics also mean cancelling on one path is observed on the
    /// other (handleCallback may take ownership before the watchdog
    /// fires; both must see the same task handle).
    private final class Pending {
        let verifier: String
        let continuation: CheckedContinuation<Result, Error>
        var timeoutTask: Task<Void, Never>?

        init(verifier: String, continuation: CheckedContinuation<Result, Error>) {
            self.verifier = verifier
            self.continuation = continuation
        }
    }

    private func failPending(with error: OpenRouterOAuthError) {
        guard let pending = inFlight else { return }
        inFlight = nil
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func exchange(
        code: String,
        verifier: String,
        continuation: CheckedContinuation<Result, Error>
    ) async {
        struct Body: Encodable {
            let code: String
            let code_challenge_method: String
            let code_verifier: String
        }

        var request = URLRequest(url: Self.exchangeURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONEncoder().encode(
                Body(code: code, code_challenge_method: "S256", code_verifier: verifier)
            )
        } catch {
            continuation.resume(throwing: OpenRouterOAuthError.malformedResponse("Couldn't encode exchange body."))
            return
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            continuation.resume(throwing: OpenRouterOAuthError.transport(error.localizedDescription))
            return
        }

        guard let http = response as? HTTPURLResponse else {
            continuation.resume(throwing: OpenRouterOAuthError.transport("Non-HTTP response."))
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            continuation.resume(throwing: OpenRouterOAuthError.exchangeFailed(detail: Self.extractError(from: data)))
            return
        }

        struct ExchangeResponse: Decodable {
            let key: String?
            let user_id: String?
        }
        do {
            let payload = try JSONDecoder().decode(ExchangeResponse.self, from: data)
            guard let key = payload.key, !key.isEmpty else {
                continuation.resume(throwing: OpenRouterOAuthError.malformedResponse("Missing `key` field."))
                return
            }
            continuation.resume(returning: Result(apiKey: key, userId: payload.user_id))
        } catch {
            continuation.resume(throwing: OpenRouterOAuthError.malformedResponse(error.localizedDescription))
        }
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

// MARK: - PKCE primitives

extension OpenRouterOAuthService {
    /// Builds a `os1://oauth/openrouter` callback URL — registered in
    /// `Info.plist` under `CFBundleURLSchemes`.
    static func callbackURL() -> URL {
        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = callbackHost
        components.path = callbackPath
        return components.url!
    }

    static func makeAuthURL(callbackURL: URL, codeChallenge: String) -> URL {
        var components = URLComponents(url: authBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    /// RFC 7636 §4.1 — 43-character verifier from the unreserved set.
    static func makeCodeVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // Fallback: use UUIDs as entropy. Unlikely in practice but
            // still spec-legal so long as we land in the unreserved set.
            let fallback = UUID().uuidString + UUID().uuidString
            return Data(fallback.utf8).base64URLEncodedString()
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// RFC 7636 §4.2 — `S256` challenge derived from the verifier.
    static func makeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    /// base64url per RFC 4648 §5 — `+/` → `-_`, no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
