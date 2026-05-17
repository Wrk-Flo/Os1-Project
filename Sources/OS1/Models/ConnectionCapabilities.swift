import Foundation

struct ConnectionCapabilities: Equatable, Sendable {
    var supportsHermesRemote: Bool
    var supportsInteractiveTerminal: Bool
    var supportsVisualDesktop: Bool
    var supportsRealtimeComputerTools: Bool
    var supportsManagedHermesInstall: Bool

    init(
        supportsHermesRemote: Bool,
        supportsInteractiveTerminal: Bool,
        supportsVisualDesktop: Bool,
        supportsRealtimeComputerTools: Bool,
        supportsManagedHermesInstall: Bool
    ) {
        self.supportsHermesRemote = supportsHermesRemote
        self.supportsInteractiveTerminal = supportsInteractiveTerminal
        self.supportsVisualDesktop = supportsVisualDesktop
        self.supportsRealtimeComputerTools = supportsRealtimeComputerTools
        self.supportsManagedHermesInstall = supportsManagedHermesInstall
    }
}

extension ConnectionProfile {
    var capabilities: ConnectionCapabilities {
        switch transport {
        case .ssh:
            ConnectionCapabilities(
                supportsHermesRemote: true,
                supportsInteractiveTerminal: true,
                supportsVisualDesktop: false,
                supportsRealtimeComputerTools: false,
                supportsManagedHermesInstall: false
            )
        case .orgo:
            ConnectionCapabilities(
                supportsHermesRemote: true,
                supportsInteractiveTerminal: true,
                supportsVisualDesktop: true,
                supportsRealtimeComputerTools: true,
                supportsManagedHermesInstall: true
            )
        }
    }
}
