import Foundation

@MainActor
final class TerminalSession: ObservableObject, @unchecked Sendable {
    let connection: ConnectionProfile
    private let driver: any TerminalDriver

    @Published var terminalTitle: String
    @Published var currentDirectory: String?
    @Published var exitCode: Int32?
    @Published var didStart = false
    @Published private(set) var launchToken = UUID()
    @Published private(set) var isRunning = false

    init(
        connection: ConnectionProfile,
        sshTransport: SSHTransport,
        orgoTransport: OrgoTransport,
        startupCommandLine: String? = nil
    ) {
        self.connection = connection
        self.terminalTitle = "\(connection.label) · \(connection.resolvedHermesProfileName)"

        switch connection.transport {
        case .ssh:
            let sshArguments = sshTransport.shellArguments(
                for: connection,
                startupCommandLine: startupCommandLine
            )
            self.driver = TerminalViewHost(sshArguments: sshArguments)
        case .orgo(let cfg):
            self.driver = OrgoTerminalDriver(
                computerId: cfg.computerId,
                orgoTransport: orgoTransport
            )
        }

        driver.setEventHandlers(
            onProcessStart: { [weak self] in
                self?.markStarted()
            },
            onTitleChange: { [weak self] title in
                self?.updateTitle(title)
            },
            onDirectoryChange: { [weak self] directory in
                self?.currentDirectory = directory
            },
            onProcessExit: { [weak self] exitCode in
                self?.markExited(exitCode)
            }
        )
    }

    deinit {
        driver.terminate()
    }

    func markStarted() {
        didStart = true
        isRunning = true
        exitCode = nil
    }

    func updateTitle(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        terminalTitle = title
    }

    func markExited(_ code: Int32?) {
        isRunning = false
        exitCode = code
    }

    func requestReconnect() {
        currentDirectory = nil
        exitCode = nil
        launchToken = UUID()
    }

    func mount(in container: TerminalMountContainerView, appearance: TerminalThemeAppearance, isActive: Bool) {
        driver.mount(
            in: container,
            appearance: appearance,
            isActive: isActive,
            launchToken: launchToken
        )
    }

    func unmount(from container: TerminalMountContainerView) {
        driver.unmount(from: container)
    }

    func stop() {
        driver.terminate()
        isRunning = false
        currentDirectory = nil
    }
}
