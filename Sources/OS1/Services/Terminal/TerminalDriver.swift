import AppKit
import Foundation

/// Drives a single terminal session for one connection. SSHTerminalDriver
/// (the existing process-spawning code in TerminalViewHost) and
/// OrgoTerminalDriver (new, websocket-backed) both adopt this so
/// TerminalSession doesn't have to know which transport is in play.
@MainActor
protocol TerminalDriver: AnyObject, Sendable {
    func setEventHandlers(
        onProcessStart: @escaping () -> Void,
        onTitleChange: @escaping (String) -> Void,
        onDirectoryChange: @escaping (String?) -> Void,
        onProcessExit: @escaping (Int32?) -> Void
    )

    /// Mounts the terminal view in the container, applies appearance, and
    /// schedules a launch for the given launch token (idempotent — if the
    /// session is already running this token, no-op).
    func mount(
        in container: TerminalMountContainerView,
        appearance: TerminalThemeAppearance,
        isActive: Bool,
        launchToken: UUID
    )

    func unmount(from container: TerminalMountContainerView)

    /// Stops the session permanently. Must be safe to call from deinit
    /// (i.e. nonisolated-callable in practice).
    nonisolated func terminate()
}
