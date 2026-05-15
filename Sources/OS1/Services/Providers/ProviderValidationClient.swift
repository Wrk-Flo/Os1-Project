import Foundation

/// Errors surfaced when the user pastes a key and we ping the provider
/// to make sure it works before we push it onto the host.
enum ProviderValidationError: LocalizedError {
    case skipped(reason: String)
    case invalidAPIKey(detail: String)
    case forbidden(detail: String)
    case rateLimited
    case http(status: Int, detail: String)
    case transport(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .skipped(let reason):
            return reason
        case .invalidAPIKey(let detail):
            let head = "API key was rejected."
            return detail.isEmpty ? head : "\(head) \(detail)"
        case .forbidden(let detail):
            let head = "API key authenticated but isn't allowed to list models."
            return detail.isEmpty ? head : "\(head) \(detail)"
        case .rateLimited:
            return "Provider rate-limited the validation request — try again in a moment."
        case .http(let status, let detail):
            return "Provider returned HTTP \(status). \(detail)"
        case .transport(let message):
            return "Couldn't reach the provider: \(message)"
        case .malformedResponse(let message):
            return "Provider response wasn't shaped as expected: \(message)"
        }
    }
}

/// Result of validating a key against a provider's `/models` endpoint.
struct ProviderValidationResult: Equatable, Sendable {
    let models: [ProviderModelSummary]
    let wasSkipped: Bool

    static let skipped = ProviderValidationResult(models: [], wasSkipped: true)
}

/// Pings a provider's `/models` endpoint with the user's API key.
/// Used at "Save key" time so we never push a known-bad key into the
/// host's `~/.hermes/.env`, and reused later to refresh the model
/// catalog on demand.
struct ProviderValidationClient: Sendable {
    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func validate(apiKey: String, against entry: ProviderCatalogEntry) async throws -> ProviderValidationResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderValidationError.invalidAPIKey(detail: "Paste your API key first.")
        }

        switch entry.validation {
        case .skip(let reason):
            return ProviderValidationResult(models: [], wasSkipped: true).withReasonLogged(reason)

        case .modelsEndpoint(let path):
            let url = entry.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            var request = URLRequest(url: url, timeoutInterval: 25)
            request.httpMethod = "GET"
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // OpenRouter ranks calls per app; harmless on every other
            // provider since unknown headers are ignored.
            request.setValue("https://os1.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("OS1 Mac", forHTTPHeaderField: "X-Title")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await urlSession.data(for: request)
            } catch {
                throw ProviderValidationError.transport(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ProviderValidationError.transport("Non-HTTP response.")
            }

            switch http.statusCode {
            case 200..<300:
                do {
                    let payload = try JSONDecoder().decode(ProviderModelListResponse.self, from: data)
                    return ProviderValidationResult(models: payload.data, wasSkipped: false)
                } catch {
                    // Some providers nest models under different keys.
                    // Don't fail validation just because we can't parse —
                    // the 200 itself proves the key works. Return empty.
                    return ProviderValidationResult(models: [], wasSkipped: false)
                }
            case 401:
                throw ProviderValidationError.invalidAPIKey(detail: Self.extractError(from: data))
            case 403:
                throw ProviderValidationError.forbidden(detail: Self.extractError(from: data))
            case 429:
                throw ProviderValidationError.rateLimited
            default:
                throw ProviderValidationError.http(status: http.statusCode, detail: Self.extractError(from: data))
            }
        }
    }

    private static func extractError(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let msg = error["message"] as? String { return msg }
            if let error = json["error"] as? String { return error }
            if let msg = json["message"] as? String { return msg }
            if let detail = json["detail"] as? String { return detail }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(280)
            .description ?? ""
    }
}

private extension ProviderValidationResult {
    /// No-op extension; placeholder to keep call-site readable. Reason
    /// strings are surface-only (not logged or persisted) but having
    /// the call clarifies why we returned `.skipped`.
    func withReasonLogged(_ reason: String) -> ProviderValidationResult {
        _ = reason
        return self
    }
}
