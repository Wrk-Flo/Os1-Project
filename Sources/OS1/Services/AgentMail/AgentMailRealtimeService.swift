import Foundation

/// Live event delivery for AgentMail. Opens a WebSocket to
/// `wss://ws.agentmail.to/v0`, subscribes to events for the active
/// inbox, and forwards new-message / sent / delivered events to the
/// view layer so the UI refreshes without a click.
///
/// Connection lifecycle is owned by the service: callers say "start
/// subscribing for this inbox + key" via `subscribe(...)`, and
/// `unsubscribe()` to tear down. Reconnects with exponential backoff
/// on transient failures (capped at 60s). Cleanly closes when the
/// caller stops needing it (Mail tab unmounts, profile switches, key
/// disconnects).
final class AgentMailRealtimeService: @unchecked Sendable {
    enum Event: Equatable {
        case opened
        case subscribed(inboxIds: [String])
        case messageReceived(inboxId: String?, messageId: String?)
        case messageSent(inboxId: String?, messageId: String?)
        case messageDelivered(inboxId: String?, messageId: String?)
        case otherEvent(type: String)
        case closed(reason: String?)
        case failed(reason: String)
    }

    private let baseURL: URL
    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "AgentMailRealtimeService", qos: .utility)

    /// Mutable per-subscription state. Guarded by `queue`.
    private var task: URLSessionWebSocketTask?
    private var listenTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var currentSubscription: Subscription?
    private var currentBackoff: UInt64 = 1_000_000_000   // 1s, doubles to 60s
    private var isStopped = true

    private struct Subscription {
        let apiKey: String
        let inboxIds: [String]
        let eventTypes: [String]
        let onEvent: @Sendable (Event) -> Void
    }

    init(
        baseURL: URL = URL(string: "wss://ws.agentmail.to/v0")!,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    deinit { unsubscribe() }

    // MARK: - Public

    /// Replaces any active subscription with a new one. Safe to call
    /// repeatedly when the user switches inboxes or profiles.
    func subscribe(
        apiKey: String,
        inboxIds: [String],
        eventTypes: [String] = ["message.received", "message.sent", "message.delivered"],
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.tearDownLocked()
            self.isStopped = false
            self.currentBackoff = 1_000_000_000
            self.currentSubscription = Subscription(
                apiKey: apiKey,
                inboxIds: inboxIds,
                eventTypes: eventTypes,
                onEvent: onEvent
            )
            self.connectLocked()
        }
    }

    /// Closes the current subscription. Idempotent.
    func unsubscribe() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.currentSubscription = nil
            self.tearDownLocked()
        }
    }

    // MARK: - Connection lifecycle (run on queue)

    private func connectLocked() {
        guard let subscription = currentSubscription, !isStopped else { return }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "api_key", value: subscription.apiKey)]
        guard let url = components.url else { return }

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Notify caller we opened (used by the view-model to flip a
        // "live" indicator on the inbox UI).
        subscription.onEvent(.opened)

        // Send the subscribe envelope. AgentMail accepts both `inbox_ids`
        // (snake_case, REST style) and `inboxIds` (camelCase, SDK
        // style); we go with snake_case to match the AsyncAPI spec.
        let payload: [String: Any] = [
            "type": "subscribe",
            "inbox_ids": subscription.inboxIds,
            "event_types": subscription.eventTypes
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            task.send(.string(json)) { [weak self] error in
                if let error {
                    self?.handleFailure(reason: "subscribe send: \(error.localizedDescription)")
                }
            }
        }

        listenTask = Task { [weak self] in
            await self?.listenLoop(task: task)
        }
        startPinging(task: task)
    }

    private func tearDownLocked() {
        listenTask?.cancel()
        listenTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func startPinging(task: URLSessionWebSocketTask) {
        // Periodic ping keeps the connection alive through NAT timeouts
        // and detects dead sockets faster than waiting for a read error.
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // 30s
                if Task.isCancelled { return }
                task.sendPing { error in
                    if let error {
                        self?.handleFailure(reason: "ping failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func listenLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                handleMessage(message)
            } catch {
                handleFailure(reason: "receive: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let value): text = value
        case .data(let data):    text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:        return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // AgentMail's events use either `type` ("subscribed") or `event`
        // ("message.received") to identify themselves; tolerate both.
        let eventType = (json["type"] as? String) ?? (json["event"] as? String) ?? ""
        let onEvent = queue.sync { currentSubscription?.onEvent }
        guard let onEvent else { return }

        switch eventType.lowercased() {
        case "subscribed":
            let inboxIds = (json["inbox_ids"] as? [String])
                ?? (json["inboxIds"] as? [String])
                ?? []
            onEvent(.subscribed(inboxIds: inboxIds))
        case "message_received", "message.received":
            onEvent(.messageReceived(
                inboxId: extractInboxId(from: json),
                messageId: extractMessageId(from: json)
            ))
        case "message_sent", "message.sent":
            onEvent(.messageSent(
                inboxId: extractInboxId(from: json),
                messageId: extractMessageId(from: json)
            ))
        case "message_delivered", "message.delivered":
            onEvent(.messageDelivered(
                inboxId: extractInboxId(from: json),
                messageId: extractMessageId(from: json)
            ))
        case "error":
            let reason = (json["message"] as? String) ?? "AgentMail event server reported an error."
            onEvent(.failed(reason: reason))
        default:
            onEvent(.otherEvent(type: eventType))
        }
    }

    private func extractInboxId(from json: [String: Any]) -> String? {
        if let messageObj = json["message"] as? [String: Any] {
            return (messageObj["inbox_id"] as? String) ?? (messageObj["inboxId"] as? String)
        }
        return (json["inbox_id"] as? String) ?? (json["inboxId"] as? String)
    }

    private func extractMessageId(from json: [String: Any]) -> String? {
        if let messageObj = json["message"] as? [String: Any] {
            return (messageObj["message_id"] as? String) ?? (messageObj["messageId"] as? String) ?? (messageObj["id"] as? String)
        }
        return (json["message_id"] as? String) ?? (json["messageId"] as? String)
    }

    private func handleFailure(reason: String) {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            let onEvent = self.currentSubscription?.onEvent
            self.tearDownLocked()
            onEvent?(.failed(reason: reason))
            self.scheduleReconnectLocked()
        }
    }

    private func scheduleReconnectLocked() {
        guard !isStopped, currentSubscription != nil else { return }
        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, 60_000_000_000)   // cap 60s

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            self?.queue.async {
                guard let self, !self.isStopped else { return }
                self.connectLocked()
            }
        }
    }
}
