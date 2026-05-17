import Foundation

@MainActor
protocol TerminalDriverMaking: AnyObject, Sendable {
    func makeDriver(
        for connection: ConnectionProfile,
        startupCommandLine: String?
    ) -> any TerminalDriver
}

@MainActor
final class TerminalDriverFactory: TerminalDriverMaking, @unchecked Sendable {
    private let sshTransport: SSHTransport
    private let orgoTransport: OrgoTransport

    init(sshTransport: SSHTransport, orgoTransport: OrgoTransport) {
        self.sshTransport = sshTransport
        self.orgoTransport = orgoTransport
    }

    func makeDriver(
        for connection: ConnectionProfile,
        startupCommandLine: String? = nil
    ) -> any TerminalDriver {
        switch connection.transport {
        case .ssh:
            let sshArguments = sshTransport.shellArguments(
                for: connection,
                startupCommandLine: startupCommandLine
            )
            return TerminalViewHost(sshArguments: sshArguments)
        case .orgo(let config):
            return OrgoTerminalDriver(
                computerId: config.computerId,
                orgoTransport: orgoTransport
            )
        }
    }
}
