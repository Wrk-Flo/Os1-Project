import Foundation

struct DesktopTarget: Equatable, Hashable, Sendable, Identifiable {
    var providerID: String
    var resourceID: String
    var displayName: String

    var id: String {
        "\(providerID):\(resourceID)"
    }
}

struct DesktopEndpoint: Equatable, Sendable {
    var target: DesktopTarget
    var webSocketURL: URL
    var password: String
}

protocol DesktopEndpointResolving: Sendable {
    func target(for connection: ConnectionProfile?) -> DesktopTarget?
    func resolveEndpoint(for target: DesktopTarget) async throws -> DesktopEndpoint
}

final class OrgoDesktopEndpointResolver: DesktopEndpointResolving, @unchecked Sendable {
    private let orgoTransport: OrgoTransport

    init(orgoTransport: OrgoTransport) {
        self.orgoTransport = orgoTransport
    }

    func target(for connection: ConnectionProfile?) -> DesktopTarget? {
        guard let connection,
              case .orgo(let config) = connection.transport else {
            return nil
        }

        let computerId = config.computerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !computerId.isEmpty else { return nil }

        return DesktopTarget(
            providerID: "orgo",
            resourceID: computerId,
            displayName: computerId
        )
    }

    func resolveEndpoint(for target: DesktopTarget) async throws -> DesktopEndpoint {
        guard target.providerID == "orgo" else {
            throw RemoteTransportError.invalidConnection(
                "Desktop provider is unsupported: \(target.providerID)."
            )
        }

        let endpoint = try await orgoTransport.resolveVNCEndpoint(computerId: target.resourceID)
        return DesktopEndpoint(
            target: target,
            webSocketURL: endpoint.webSocketURL,
            password: endpoint.vncPassword
        )
    }
}
