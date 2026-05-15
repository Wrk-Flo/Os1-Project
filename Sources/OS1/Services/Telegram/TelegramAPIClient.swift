import Foundation

enum TelegramAPIError: LocalizedError {
    case invalidToken
    case revokedToken(message: String)
    case transport(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Telegram rejected this token. Double-check it from @BotFather."
        case .revokedToken(let message):
            return "Telegram says this token isn't valid: \(message)"
        case .transport(let message):
            return "Couldn't reach Telegram: \(message)"
        case .malformed(let message):
            return "Telegram returned an unexpected response: \(message)"
        }
    }
}

/// Minimal client for Telegram's Bot API at `api.telegram.org/bot<token>`.
/// Only used to validate the token + pull the bot's display name before
/// we hand the token off to Hermes' gateway. The agent itself does all
/// runtime polling via python-telegram-bot.
struct TelegramAPIClient: Sendable {
    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Calls `getMe` to confirm the token is real, active, and not
    /// revoked. Returns the bot's identity record. Throws
    /// `.invalidToken` for 401/404, `.revokedToken` when the API
    /// explicitly says so, `.transport` for network failures.
    func getMe(token: String) async throws -> TelegramBotInfo {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramAPIError.invalidToken }
        // Token format is `<numeric_id>:<alphanumeric_secret>`. Catch
        // shape errors before the network roundtrip.
        guard trimmed.contains(":"), trimmed.split(separator: ":").count == 2 else {
            throw TelegramAPIError.invalidToken
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(trimmed)/getMe") else {
            throw TelegramAPIError.malformed("Couldn't build URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            throw TelegramAPIError.transport(error.localizedDescription)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw TelegramAPIError.transport("Non-HTTP response.")
        }

        // Telegram returns 401/404 for bad tokens with a JSON body that
        // includes a `description`. Map those to .invalidToken so the
        // UI shows a clean message.
        let envelope: TelegramAPIEnvelope<TelegramBotInfo>
        do {
            envelope = try JSONDecoder().decode(TelegramAPIEnvelope<TelegramBotInfo>.self, from: data)
        } catch {
            if http.statusCode == 401 || http.statusCode == 404 {
                throw TelegramAPIError.invalidToken
            }
            throw TelegramAPIError.malformed("Decode: \(error.localizedDescription)")
        }

        if !envelope.ok {
            let detail = envelope.description ?? "Unknown error"
            if http.statusCode == 401 || http.statusCode == 404 {
                throw TelegramAPIError.invalidToken
            }
            throw TelegramAPIError.revokedToken(message: detail)
        }

        guard let bot = envelope.result else {
            throw TelegramAPIError.malformed("Missing `result` in response.")
        }
        return bot
    }
}
