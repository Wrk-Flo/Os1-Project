import Foundation

/// Live snapshot of the gateway and per-platform connection state, as
/// read from `~/.hermes/gateway_state.json` written by `hermes gateway
/// run`. Decoded permissively — every field optional, partial writes
/// happen mid-tick and would otherwise blow up the Doctor tab.
struct GatewayStateSnapshot: Decodable, Equatable, Sendable {
    let pid: Int?
    let kind: String?
    let gateway_state: String?
    let exit_reason: String?
    let restart_requested: Bool?
    let active_agents: Int?
    let platforms: [String: PlatformState]?
    let updated_at: String?

    /// True if the runtime field reports the gateway as actively running
    /// (vs. starting / stopping / errored).
    var isRunning: Bool {
        gateway_state?.lowercased() == "running"
    }

    /// Returns true iff EVERY platform present is in the connected
    /// state. Returns nil when the platforms dict is missing.
    var allPlatformsConnected: Bool? {
        guard let platforms, !platforms.isEmpty else { return nil }
        return platforms.values.allSatisfy { $0.isConnected }
    }

    /// Pulls a specific platform's state, lower-cased for safe comparison.
    func platform(_ name: String) -> PlatformState? {
        platforms?[name]
    }

    /// Decode permissively — return nil for any failure rather than
    /// throwing, since partial writes from the live gateway are normal.
    static func decode(from raw: String?) -> GatewayStateSnapshot? {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GatewayStateSnapshot.self, from: data)
    }
}

struct PlatformState: Decodable, Equatable, Sendable {
    let state: String?
    let error_code: String?
    let error_message: String?
    let updated_at: String?

    var isConnected: Bool {
        state?.lowercased() == "connected"
    }

    var isConnecting: Bool {
        let s = state?.lowercased()
        return s == "connecting" || s == "starting"
    }

    var hasError: Bool {
        let s = state?.lowercased()
        return s == "error" || s == "failed" || (error_message?.isEmpty == false)
    }
}
