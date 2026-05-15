import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Cold-start boot animation. The visual is the OS-1 web app's
/// InfinityLoader (`nickvasilescu/OS-1` → `src/components/InfinityLoader.js`)
/// rendered verbatim in a WKWebView so the helix → ring morph, the
/// chaotic wobble, and the audio cue are byte-for-byte the original.
/// The bundled `boot.html` harness loads `infinity-loader.js`,
/// `three.module.min.js`, and `init_sound.mp3` from the SwiftPM
/// resource bundle and signals back via `webkit.messageHandlers.boot`
/// when the animation is done (or the user taps to skip).
struct BootAnimationView: View {
    var onFinished: () -> Void

    var body: some View {
        BootWebView(onFinished: onFinished)
            .ignoresSafeArea()
            // Fallback if the WebView fails to paint — matches the
            // top/bottom band of the OS-1 cream gradient (#d4bc9a).
            .background(Color(red: 0xd4/255.0, green: 0xbc/255.0, blue: 0x9a/255.0))
    }
}

private struct BootWebView: NSViewRepresentable {
    var onFinished: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "boot")
        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Custom scheme handler. WKWebView blocks ES-module loading from
        // file:// URLs (modules are treated as cross-origin), so we serve
        // the bundled boot harness through `os1-boot://app/<filename>`
        // instead. This also lets us hand back proper MIME types.
        let handler = BootSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: "os1-boot")
        context.coordinator.schemeHandler = handler

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator

        guard let url = URL(string: "os1-boot://app/boot.html") else {
            DispatchQueue.main.async { context.coordinator.fireFinishedOnce() }
            return webView
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onFinished: () -> Void
        var schemeHandler: BootSchemeHandler?
        private var didFinish = false
        private var safetyTimer: DispatchWorkItem?

        init(onFinished: @escaping () -> Void) {
            self.onFinished = onFinished
            super.init()
            // Belt-and-suspenders: if the JS hangs (GPU error, missing
            // audio resource), we still tear the boot screen down. Sized
            // for the full 14.16 s init sound + 4 s load lead-in + ~2 s
            // of helix→ring lead + ~1.2 s of morph/fade, with margin.
            let work = DispatchWorkItem { [weak self] in self?.fireFinishedOnce() }
            self.safetyTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 22.0, execute: work)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                let payload = message.body as? [String: Any],
                let event = payload["event"] as? String
            else { return }

            switch event {
            case "finished", "skipped":
                fireFinishedOnce()
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fireFinishedOnce()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fireFinishedOnce()
        }

        func fireFinishedOnce() {
            guard !didFinish else { return }
            didFinish = true
            safetyTimer?.cancel()
            onFinished()
        }
    }
}

final class BootSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let resourceRoot = Bundle.module.resourceURL
        else {
            urlSchemeTask.didFailWithError(
                NSError(domain: "BootSchemeHandler", code: -1)
            )
            return
        }

        // os1-boot://app/<filename> → <resourceRoot>/<filename>. The
        // SwiftPM bundle flattens the Boot/ subdirectory at build time,
        // so a basename lookup is correct.
        let filename = (url.path as NSString).lastPathComponent
        let fileURL = resourceRoot.appendingPathComponent(filename)

        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(
                NSError(
                    domain: "BootSchemeHandler",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Missing boot resource: \(filename)"]
                )
            )
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType(for: filename),
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-store"
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js":   return "application/javascript; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        case "mp3":  return "audio/mpeg"
        default:
            if let type = UTType(filenameExtension: (filename as NSString).pathExtension),
               let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }
}
