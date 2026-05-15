import AppKit
import SwiftUI

/// Vertical-split layout that draws its drag handle in the warm OS1
/// palette instead of macOS's default cool-grey divider, which reads as a
/// black/charcoal line on coral. Used for the root sidebar/detail split
/// in `RootView`.
struct OS1HSplitView<Primary: View, Detail: View>: NSViewRepresentable {
    let primary: Primary
    let detail: Detail

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.primary = primary()
        self.detail = detail()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = OS1WarmDividerSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let primaryHost = NSHostingView(rootView: primary)
        let detailHost = NSHostingView(rootView: detail)

        primaryHost.translatesAutoresizingMaskIntoConstraints = false
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        primaryHost.clipsToBounds = true
        detailHost.clipsToBounds = true

        splitView.addArrangedSubview(primaryHost)
        splitView.addArrangedSubview(detailHost)

        context.coordinator.primaryHost = primaryHost
        context.coordinator.detailHost = detailHost
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.primaryHost?.rootView = primary
        context.coordinator.detailHost?.rootView = detail
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var primaryHost: NSHostingView<Primary>?
        var detailHost: NSHostingView<Detail>?
    }
}

/// NSSplitView subclass that paints the divider with a warm tan tint
/// instead of the system cool-grey. The fill is subtle — about 22 %
/// alpha — so the handle is visible but doesn't read as a hard line on
/// coral. Shared by OS1HSplitView (root) and HermesPersistentHSplitView
/// (per-section split panels) so dividers stay consistent.
final class OS1WarmDividerSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        NSColor(
            deviceRed: 180.0 / 255.0,
            green: 145.0 / 255.0,
            blue: 120.0 / 255.0,
            alpha: 0.22
        ).setFill()
        rect.fill()
    }
}
