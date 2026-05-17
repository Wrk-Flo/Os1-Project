import Foundation
import Testing
@testable import OS1

struct OrgoDesktopEndpointResolverTests {
    @Test
    func sshProfileHasNoDesktopTarget() {
        let resolver = OrgoDesktopEndpointResolver(
            orgoTransport: OrgoTransport(apiKeyProvider: { nil })
        )
        let profile = ConnectionProfile(
            label: "SSH",
            transport: .ssh(SSHConfig(alias: "os1-hermes-dev", user: "hermes"))
        )

        #expect(resolver.target(for: profile) == nil)
    }

    @Test
    func orgoProfileWithoutComputerHasNoDesktopTarget() {
        let resolver = OrgoDesktopEndpointResolver(
            orgoTransport: OrgoTransport(apiKeyProvider: { nil })
        )
        let profile = ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig(workspaceId: "ws_123", computerId: "  "))
        )

        #expect(resolver.target(for: profile) == nil)
    }

    @Test
    func orgoProfileMapsComputerToDesktopTarget() throws {
        let resolver = OrgoDesktopEndpointResolver(
            orgoTransport: OrgoTransport(apiKeyProvider: { nil })
        )
        let profile = ConnectionProfile(
            label: "Orgo",
            transport: .orgo(OrgoConfig(workspaceId: "ws_123", computerId: " computer_123 "))
        )

        let target = try #require(resolver.target(for: profile))

        #expect(target.providerID == "orgo")
        #expect(target.resourceID == "computer_123")
        #expect(target.displayName == "computer_123")
    }
}
