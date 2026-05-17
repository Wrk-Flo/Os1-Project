import Foundation
import Testing
@testable import OS1

private final class StubDesktopEndpointResolver: DesktopEndpointResolving, @unchecked Sendable {
    var targetResult: DesktopTarget?
    var resolvedTargets: [DesktopTarget] = []

    init(targetResult: DesktopTarget? = nil) {
        self.targetResult = targetResult
    }

    func target(for connection: ConnectionProfile?) -> DesktopTarget? {
        targetResult
    }

    func resolveEndpoint(for target: DesktopTarget) async throws -> DesktopEndpoint {
        resolvedTargets.append(target)
        return DesktopEndpoint(
            target: target,
            webSocketURL: URL(string: "wss://vm.example.com/websockify?token=redacted")!,
            password: "redacted"
        )
    }
}

struct DesktopEndpointResolvingTests {
    @Test
    func desktopTargetIDIncludesProviderAndResource() {
        let target = DesktopTarget(providerID: "orgo", resourceID: "vm_123", displayName: "vm_123")

        #expect(target.id == "orgo:vm_123")
    }

    @Test
    func desktopEndpointPreservesTargetURLAndPassword() {
        let target = DesktopTarget(providerID: "orgo", resourceID: "vm_123", displayName: "vm_123")
        let endpoint = DesktopEndpoint(
            target: target,
            webSocketURL: URL(string: "wss://fly.orgo.dev/websockify?token=secret")!,
            password: "secret"
        )

        #expect(endpoint.target == target)
        #expect(endpoint.webSocketURL.scheme == "wss")
        #expect(endpoint.webSocketURL.path == "/websockify")
        #expect(endpoint.password == "secret")
    }

    @Test
    func stubResolverMapsConfiguredTargetToEndpoint() async throws {
        let target = DesktopTarget(providerID: "orgo", resourceID: "vm_123", displayName: "vm_123")
        let resolver = StubDesktopEndpointResolver(targetResult: target)

        let endpoint = try await resolver.resolveEndpoint(for: target)

        #expect(resolver.target(for: nil) == target)
        #expect(resolver.resolvedTargets == [target])
        #expect(endpoint.target == target)
    }
}
