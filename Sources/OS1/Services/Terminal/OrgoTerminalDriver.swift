import AppKit
import Foundation
@preconcurrency import SwiftTerm

@MainActor
final class OrgoTerminalDriver: NSObject, TerminalDriver, TerminalViewDelegate {
    private let computerId: String
    private let orgoTransport: OrgoTransport
    private let hostView: OrgoTerminalHostView

    private var startedLaunchToken: UUID?
    private var scheduledLaunchToken: UUID?
    private var appliedAppearance: TerminalThemeAppearance?

    private var onProcessStart: (() -> Void)?
    private var onTitleChange: ((String) -> Void)?
    private var onDirectoryChange: ((String?) -> Void)?
    private var onProcessExit: ((Int32?) -> Void)?

    private var connectionTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private var terminalCols: Int = 80
    private var terminalRows: Int = 24

    init(computerId: String, orgoTransport: OrgoTransport, urlSession: URLSession = .shared) {
        self.computerId = computerId
        self.orgoTransport = orgoTransport
        self.urlSession = urlSession
        self.hostView = OrgoTerminalHostView()
        super.init()
        hostView.terminalView.terminalDelegate = self
    }

    deinit {
        connectionTask?.cancel()
        pingTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - TerminalDriver

    func setEventHandlers(
        onProcessStart: @escaping () -> Void,
        onTitleChange: @escaping (String) -> Void,
        onDirectoryChange: @escaping (String?) -> Void,
        onProcessExit: @escaping (Int32?) -> Void
    ) {
        self.onProcessStart = onProcessStart
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onProcessExit = onProcessExit
    }

    func mount(
        in container: TerminalMountContainerView,
        appearance: TerminalThemeAppearance,
        isActive: Bool,
        launchToken: UUID
    ) {
        container.mount(hostView)
        applyAppearance(appearance)
        setActive(isActive)
        scheduleStartIfNeeded(launchToken: launchToken)
    }

    func unmount(from container: TerminalMountContainerView) {
        container.unmountHostedView()
    }

    nonisolated func terminate() {
        Task { @MainActor [weak self] in
            self?.terminateOnMainThread()
        }
    }

    // MARK: - TerminalViewDelegate (user input + resize)

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            self?.handleSizeChanged(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.onTitleChange?(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.onDirectoryChange?(directory)
        }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let chunk = Data(data)
        Task { @MainActor [weak self] in
            self?.sendInputBytes(chunk)
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        Task { @MainActor in
            guard let text = String(data: content, encoding: .utf8) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // MARK: - Lifecycle helpers

    private func scheduleStartIfNeeded(launchToken: UUID) {
        guard startedLaunchToken != launchToken else { return }
        guard scheduledLaunchToken != launchToken else { return }
        scheduledLaunchToken = launchToken

        Task { @MainActor [weak self] in
            self?.startIfNeeded(launchToken: launchToken)
        }
    }

    private func startIfNeeded(launchToken: UUID) {
        scheduledLaunchToken = nil
        guard startedLaunchToken != launchToken else { return }
        startedLaunchToken = launchToken

        // Tear down any existing connection (reconnect path).
        connectionTask?.cancel()
        pingTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        connectionTask = Task { [weak self] in
            await self?.runWebSocketSession()
        }
    }

    private func handleSizeChanged(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        sendResizeMessage(cols: cols, rows: rows)
    }

    private func sendInputBytes(_ data: Data) {
        guard let task = webSocketTask else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            // Non-UTF-8 input is rare on a terminal; drop and log.
            return
        }
        let payload: [String: Any] = ["type": "input", "data": text]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        Task {
            try? await task.send(.data(encoded))
        }
    }

    private func sendResizeMessage(cols: Int, rows: Int) {
        guard let task = webSocketTask else { return }
        let payload: [String: Any] = ["type": "resize", "cols": cols, "rows": rows]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        Task {
            try? await task.send(.data(encoded))
        }
    }

    private func sendPing() {
        guard let task = webSocketTask else { return }
        let payload: [String: Any] = ["type": "ping"]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        Task {
            try? await task.send(.data(encoded))
        }
    }

    private func applyAppearance(_ appearance: TerminalThemeAppearance) {
        guard appliedAppearance != appearance else { return }
        appliedAppearance = appearance
        hostView.apply(appearance: appearance)
    }

    private func setActive(_ isActive: Bool) {
        hostView.isHidden = !isActive
        if !isActive {
            hostView.window?.makeFirstResponder(nil)
        } else {
            hostView.window?.makeFirstResponder(hostView.terminalView)
        }
    }

    @MainActor
    private func terminateOnMainThread() {
        scheduledLaunchToken = nil
        startedLaunchToken = nil
        connectionTask?.cancel()
        pingTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - WebSocket session

    private func runWebSocketSession() async {
        // Resolve endpoint (URL + VNC password) — may call ensure-running on
        // a suspended VM. Failures show up in the terminal as a one-line error.
        let endpoint: OrgoTerminalEndpoint
        do {
            endpoint = try await orgoTransport.resolveTerminalEndpoint(
                computerId: computerId,
                cols: terminalCols,
                rows: terminalRows
            )
        } catch {
            await feedErrorAndExit("Could not reach the Orgo VM: \(error.localizedDescription)\r\n")
            return
        }

        await MainActor.run { [weak self] in
            self?.onProcessStart?()
        }

        // Open the websocket.
        let task = urlSession.webSocketTask(with: endpoint.webSocketURL)
        await MainActor.run { [weak self] in
            self?.webSocketTask = task
        }
        task.resume()

        // Start keep-alive ping every 10s.
        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run { [weak self] in
                    self?.sendPing()
                }
            }
        }
        await MainActor.run { [weak self] in
            self?.pingTask = pinger
        }

        // Receive loop. Terminates when the server closes or we cancel.
        var observedExitCode: Int32?
        receiveLoop: while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if Task.isCancelled { return }
                await feedErrorAndExit("\r\nTerminal connection closed: \(error.localizedDescription)\r\n")
                pinger.cancel()
                return
            }

            let payload: Data
            switch message {
            case .data(let data):
                payload = data
            case .string(let string):
                payload = Data(string.utf8)
            @unknown default:
                continue
            }

            guard let parsed = try? JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any],
                  let type = parsed["type"] as? String else {
                continue
            }

            switch type {
            case "output":
                if let text = parsed["data"] as? String {
                    let bytes = Array(text.utf8)
                    await MainActor.run { [weak self] in
                        self?.feedToTerminal(bytes)
                    }
                }
            case "exit":
                observedExitCode = (parsed["code"] as? Int).map { Int32($0) }
                break receiveLoop
            case "error":
                let messageText = parsed["message"] as? String ?? "Terminal error"
                await MainActor.run { [weak self] in
                    self?.feedToTerminal(Array("\r\n[orgo] \(messageText)\r\n".utf8))
                }
            case "pong", "ping":
                continue
            default:
                continue
            }
        }

        pinger.cancel()
        await MainActor.run { [weak self] in
            self?.webSocketTask = nil
            self?.onProcessExit?(observedExitCode)
        }
    }

    private func feedToTerminal(_ bytes: [UInt8]) {
        hostView.terminalView.feed(byteArray: bytes[...])
    }

    private func feedErrorAndExit(_ text: String) async {
        await MainActor.run { [weak self] in
            self?.feedToTerminal(Array(text.utf8))
            self?.onProcessExit?(-1)
        }
    }
}

// MARK: - Host view (TerminalView, not LocalProcessTerminalView)

@MainActor
final class OrgoTerminalHostView: NSView {
    let terminalView = SwiftTerm.TerminalView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(appearance: TerminalThemeAppearance) {
        let backgroundColor = appearance.backgroundColor.nsColor
        let foregroundColor = appearance.foregroundColor.nsColor

        layer?.backgroundColor = backgroundColor.cgColor
        terminalView.nativeBackgroundColor = backgroundColor
        terminalView.nativeForegroundColor = foregroundColor
        terminalView.selectedTextBackgroundColor = foregroundColor.withAlphaComponent(0.28)
        terminalView.caretColor = foregroundColor
        terminalView.caretTextColor = backgroundColor
        terminalView.installColors(appearance.ansiPalette.map(Self.makeTerminalColor(from:)))
    }

    private static func makeTerminalColor(from themeColor: TerminalThemeColor) -> SwiftTerm.Color {
        let color = themeColor.nsColor.usingColorSpace(.deviceRGB) ?? .black
        return SwiftTerm.Color(
            red: UInt16(color.redComponent * 65535),
            green: UInt16(color.greenComponent * 65535),
            blue: UInt16(color.blueComponent * 65535)
        )
    }
}
