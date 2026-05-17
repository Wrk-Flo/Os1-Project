import Foundation
import Testing
@testable import OS1

private final class StubTerminalDriver: TerminalDriver, @unchecked Sendable {
    func setEventHandlers(
        onProcessStart: @escaping () -> Void,
        onTitleChange: @escaping (String) -> Void,
        onDirectoryChange: @escaping (String?) -> Void,
        onProcessExit: @escaping (Int32?) -> Void
    ) {}

    func mount(
        in container: TerminalMountContainerView,
        appearance: TerminalThemeAppearance,
        isActive: Bool,
        launchToken: UUID
    ) {}

    func unmount(from container: TerminalMountContainerView) {}

    nonisolated func terminate() {}
}

private final class RecordingTerminalDriverFactory: TerminalDriverMaking, @unchecked Sendable {
    struct Request: Equatable {
        var connection: ConnectionProfile
        var startupCommandLine: String?
    }

    private(set) var requests: [Request] = []

    func makeDriver(
        for connection: ConnectionProfile,
        startupCommandLine: String?
    ) -> any TerminalDriver {
        requests.append(Request(connection: connection, startupCommandLine: startupCommandLine))
        return StubTerminalDriver()
    }
}

struct TerminalDriverFactoryTests {
    @Test
    @MainActor
    func factoryCreatesSSHDriverForSSHProfile() {
        let factory = TerminalDriverFactory(
            sshTransport: SSHTransport(paths: AppPaths()),
            orgoTransport: OrgoTransport(apiKeyProvider: { nil })
        )
        let profile = ConnectionProfile(
            label: "SSH",
            transport: .ssh(SSHConfig(alias: "os1-hermes-dev", user: "hermes"))
        )

        let driver = factory.makeDriver(for: profile, startupCommandLine: "pwd")

        #expect(driver is TerminalViewHost)
    }

    @Test
    @MainActor
    func factoryCreatesOrgoDriverForOrgoProfile() {
        let factory = TerminalDriverFactory(
            sshTransport: SSHTransport(paths: AppPaths()),
            orgoTransport: OrgoTransport(apiKeyProvider: { nil })
        )
        let profile = ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig(workspaceId: "ws_123", computerId: "computer_123"))
        )

        let driver = factory.makeDriver(for: profile, startupCommandLine: nil)

        #expect(driver is OrgoTerminalDriver)
    }

    @Test
    @MainActor
    func workspaceStoreUsesInjectedFactoryWhenAddingTabs() {
        let factory = RecordingTerminalDriverFactory()
        let workspace = TerminalWorkspaceStore(driverFactory: factory)
        let profile = ConnectionProfile(
            label: "SSH",
            transport: .ssh(SSHConfig(alias: "os1-hermes-dev", user: "hermes"))
        )

        let tab = workspace.addCommandTab(for: profile, commandLine: "hermes status")

        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs.first?.id == tab.id)
        #expect(workspace.selectedTabID == tab.id)
        #expect(factory.requests == [
            RecordingTerminalDriverFactory.Request(
                connection: profile,
                startupCommandLine: "hermes status"
            )
        ])
    }
}
