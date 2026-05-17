import SwiftUI
@preconcurrency import WebKit

/// Live desktop view for providers that expose a noVNC-compatible endpoint.
/// SSH hosts have no remote framebuffer, so this section is hidden unless the
/// active connection advertises visual desktop capability.
///
/// Architecture mirrors `jxspam/orgo-wrapper`: a `WKWebView` hosts a
/// bundled `vnc.html` running noVNC; Swift resolves a provider-neutral desktop
/// endpoint and forwards it through `evaluateJavaScript`. Status flows back via
/// a `WKScriptMessageHandler`.
struct DesktopView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    @State private var status: VNCStatus = .idle
    @State private var endpoint: DesktopEndpoint?
    @State private var resolveTask: Task<Void, Never>?
    @State private var retryDelay: UInt64 = 5_000_000_000  // 5s, doubles to 60s
    @State private var retryTask: Task<Void, Never>?
    @State private var lastError: String = ""

    var body: some View {
        Group {
            if let target = activeDesktopTarget {
                content(target: target)
            } else {
                noConnectionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.coral)
        .onChange(of: activeDesktopTarget) { _, newTarget in
            if let newTarget {
                resolve(target: newTarget)
            } else {
                tearDown()
            }
        }
        .onAppear {
            if let target = activeDesktopTarget, endpoint == nil {
                resolve(target: target)
            }
        }
        .onDisappear { tearDown() }
    }

    // MARK: - Header / chrome

    private func content(target: DesktopTarget) -> some View {
        VStack(spacing: 0) {
            header(target: target)

            ZStack {
                if let endpoint {
                    VNCWebView(
                        endpoint: endpoint,
                        onStatus: handleStatus
                    )
                    .background(Color.black)
                } else {
                    Color.black
                }

                if shouldShowOverlay {
                    overlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(target: DesktopTarget) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text(L10n.string("Desktop"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text("·")
                .foregroundStyle(theme.palette.onCoralMuted)

            Text(target.displayName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            statusBadge

            Button {
                manualReconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.os1Icon)
            .help(L10n.string("Reconnect"))
            .disabled(status == .connecting || status == .loading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(theme.palette.coral)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.onCoralMuted.opacity(0.18))
                .frame(height: 1)
        }
    }

    private var statusBadge: some View {
        HermesBadge(
            text: status.displayText,
            tint: .os1OnCoralPrimary,
            systemImage: status.systemImage
        )
    }

    private var overlay: some View {
        ZStack {
            Color.black.opacity(status == .connected ? 0 : 0.7)

            switch status {
            case .loading, .connecting, .resolving:
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.palette.onCoralPrimary)
            case .disconnected:
                disconnectedOverlay
            case .error:
                errorOverlay
            case .idle, .connected:
                EmptyView()
            }
        }
        .allowsHitTesting(status != .connected)
    }

    private var disconnectedOverlay: some View {
        VStack(spacing: 10) {
            Text(lastError.isEmpty ? L10n.string("Disconnected") : lastError)
                .os1Style(theme.typography.body)
                .foregroundStyle(.white.opacity(0.85))

            Button(L10n.string("Reconnect")) { manualReconnect() }
                .buttonStyle(.os1Primary)
        }
    }

    private var errorOverlay: some View {
        VStack(spacing: 10) {
            Text(lastError.isEmpty ? L10n.string("Connection error") : lastError)
                .os1Style(theme.typography.body)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            Button(L10n.string("Retry")) { manualReconnect() }
                .buttonStyle(.os1Primary)
        }
    }

    private var noConnectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)

            Text(L10n.string("No desktop provider selected"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text(L10n.string("Pick a host with desktop capability from the Host tab to view the desktop."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }

    // MARK: - Connection lifecycle

    private var activeDesktopTarget: DesktopTarget? {
        appState.desktopEndpointResolver.target(for: appState.activeConnection)
    }

    private var shouldShowOverlay: Bool {
        status != .connected
    }

    private func resolve(target: DesktopTarget) {
        cancelRetryTask()
        resolveTask?.cancel()
        status = .resolving
        lastError = ""
        endpoint = nil

        let resolver = appState.desktopEndpointResolver
        resolveTask = Task { @MainActor in
            do {
                let resolved = try await resolver.resolveEndpoint(for: target)
                guard !Task.isCancelled else { return }
                self.endpoint = resolved
                // status flips to .connecting / .connected via the JS bridge
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .error
                self.lastError = (error as NSError).localizedDescription
                scheduleRetry(target: target)
            }
        }
    }

    private func handleStatus(_ message: VNCStatusMessage) {
        switch message.status {
        case "loading":
            status = .loading
        case "connecting":
            status = .connecting
        case "connected":
            status = .connected
            lastError = ""
            retryDelay = 5_000_000_000
            cancelRetryTask()
        case "disconnected":
            status = .disconnected
            if let err = message.error { lastError = err }
            if let target = activeDesktopTarget { scheduleRetry(target: target) }
        case "error":
            status = .error
            if let err = message.error { lastError = err }
            if let target = activeDesktopTarget { scheduleRetry(target: target) }
        default:
            break
        }
    }

    private func scheduleRetry(target: DesktopTarget) {
        cancelRetryTask()
        let delay = retryDelay
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            // Exponential backoff capped at 60s.
            self.retryDelay = min(delay * 2, 60_000_000_000)
            self.resolve(target: target)
        }
    }

    private func manualReconnect() {
        retryDelay = 5_000_000_000
        cancelRetryTask()
        if let target = activeDesktopTarget {
            resolve(target: target)
        }
    }

    private func cancelRetryTask() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func tearDown() {
        resolveTask?.cancel()
        resolveTask = nil
        cancelRetryTask()
        endpoint = nil
        status = .idle
        lastError = ""
    }
}

// MARK: - Status model

enum VNCStatus: Equatable {
    case idle
    case resolving
    case loading
    case connecting
    case connected
    case disconnected
    case error

    var displayText: String {
        switch self {
        case .idle:         return L10n.string("Idle")
        case .resolving:    return L10n.string("Resolving")
        case .loading:      return L10n.string("Loading")
        case .connecting:   return L10n.string("Connecting")
        case .connected:    return L10n.string("Connected")
        case .disconnected: return L10n.string("Disconnected")
        case .error:        return L10n.string("Error")
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .resolving, .loading, .connecting:
            return "circle.dotted"
        case .connected:
            return "checkmark.circle.fill"
        case .disconnected:
            return "exclamationmark.circle"
        case .error:
            return "xmark.octagon"
        }
    }
}

struct VNCStatusMessage: Decodable {
    let status: String
    let error: String?
}

// MARK: - WKWebView host

private struct VNCWebView: NSViewRepresentable {
    let endpoint: DesktopEndpoint
    let onStatus: (VNCStatusMessage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "vncStatus")
        config.userContentController = userContentController

        let prefs = WKPreferences()
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        config.preferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // transparent over our coral
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        context.coordinator.webView = webView
        context.coordinator.endpoint = endpoint
        loadVNCPage(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus

        // If the websockify URL or password changed, push a new connect call;
        // the page itself stays mounted so we don't tear down the WebView.
        if context.coordinator.endpoint != endpoint {
            context.coordinator.endpoint = endpoint
            if context.coordinator.didFinishInitialLoad {
                context.coordinator.dispatchConnect()
            }
        }
    }

    private func loadVNCPage(into webView: WKWebView, coordinator: Coordinator) {
        guard let url = Self.bundledVNCHTML() else {
            coordinator.onStatus(VNCStatusMessage(status: "error", error: "vnc.html missing from app bundle"))
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private static func bundledVNCHTML() -> URL? {
        // Prefer Bundle.module (SPM resource bundle) but fall back to main
        // for the macOS .app — both exist depending on build path.
        if let url = Bundle.module.url(forResource: "vnc", withExtension: "html") {
            return url
        }
        return Bundle.main.url(forResource: "vnc", withExtension: "html")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onStatus: (VNCStatusMessage) -> Void
        var endpoint: DesktopEndpoint?
        weak var webView: WKWebView?
        var didFinishInitialLoad = false

        init(onStatus: @escaping (VNCStatusMessage) -> Void) {
            self.onStatus = onStatus
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "vncStatus" else { return }
            // The body is a JSON-compatible dictionary the page sent.
            guard let body = message.body as? [String: Any] else { return }
            let status = body["status"] as? String ?? "error"
            let error = body["error"] as? String
            onStatus(VNCStatusMessage(status: status, error: error))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinishInitialLoad = true
            dispatchConnect()
        }

        func dispatchConnect() {
            guard let webView, let endpoint else { return }
            // Pass URL + password through JSON.stringify so any quoting in the
            // password doesn't break the JS expression.
            let payload: [String: String] = [
                "wsUrl": endpoint.webSocketURL.absoluteString,
                "password": endpoint.password,
            ]
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
            else {
                onStatus(VNCStatusMessage(status: "error", error: "Failed to encode VNC config"))
                return
            }
            let js = """
            (function() {
              try {
                var cfg = \(json);
                window.vncBridge.connect(cfg.wsUrl, cfg.password);
              } catch (e) {
                window.webkit.messageHandlers.vncStatus.postMessage({ status: 'error', error: String(e) });
              }
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] _, error in
                if let error {
                    self?.onStatus(VNCStatusMessage(status: "error", error: error.localizedDescription))
                }
            }
        }
    }
}
