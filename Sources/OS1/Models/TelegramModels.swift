import Foundation

/// Bot info returned by Telegram's `getMe` endpoint. Used for both
/// token validation (a successful call confirms the token is real and
/// active) and surfacing the bot's display name / @username in the UI.
struct TelegramBotInfo: Decodable, Equatable {
    let id: Int64
    let is_bot: Bool?
    let first_name: String?
    let username: String?
    let can_join_groups: Bool?
    let can_read_all_group_messages: Bool?
    let supports_inline_queries: Bool?

    /// Convenience: `@username` if available, falling back to first_name or id.
    var displayHandle: String {
        if let username, !username.isEmpty { return "@\(username)" }
        if let first_name, !first_name.isEmpty { return first_name }
        return "bot \(id)"
    }
}

/// Telegram Bot API wraps every response in `{ ok, result, description }`.
struct TelegramAPIEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
    let error_code: Int?
}
