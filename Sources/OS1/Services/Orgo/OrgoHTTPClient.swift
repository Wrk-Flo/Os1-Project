import Foundation

struct OrgoHTTPClient: Sendable {
    static let defaultBaseURL = URL(string: "https://www.orgo.ai/api")!

    let baseURL: URL
    let apiKeyProvider: @Sendable () -> String?
    let urlSession: URLSession

    init(
        baseURL: URL = OrgoHTTPClient.defaultBaseURL,
        apiKeyProvider: @escaping @Sendable () -> String?,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.urlSession = urlSession
    }

    func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        timeout: TimeInterval = 60
    ) async throws -> Response {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw RemoteTransportError.invalidConnection("No Orgo API key configured.")
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw RemoteTransportError.localFailure("Orgo HTTP request failed: \(error.localizedDescription)")
        }

        try OrgoHTTPClient.validateHTTPStatus(urlResponse, data: data)

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteTransportError.invalidResponse(
                "Failed to decode Orgo response: \(error.localizedDescription)"
            )
        }
    }

    func get<Response: Decodable>(
        path: String,
        query: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> Response {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw RemoteTransportError.invalidConnection("No Orgo API key configured.")
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw RemoteTransportError.invalidConnection("Could not build Orgo URL for \(path).")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw RemoteTransportError.localFailure("Orgo HTTP request failed: \(error.localizedDescription)")
        }

        try OrgoHTTPClient.validateHTTPStatus(urlResponse, data: data)

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteTransportError.invalidResponse(
                "Failed to decode Orgo response: \(error.localizedDescription)"
            )
        }
    }

    private static func validateHTTPStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteTransportError.invalidResponse("Orgo returned a non-HTTP response.")
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        let detail = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
        switch http.statusCode {
        case 401, 403:
            throw RemoteTransportError.invalidConnection("Orgo authentication failed: \(detail)")
        case 404:
            throw RemoteTransportError.invalidConnection("Orgo resource not found: \(detail)")
        default:
            throw RemoteTransportError.remoteFailure("Orgo \(http.statusCode): \(detail)")
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        struct Envelope: Decodable {
            let error: String?
            let message: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.error ?? envelope.message
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}
