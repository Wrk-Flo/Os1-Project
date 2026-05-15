import Foundation

/// Routes RemoteTransport calls to the right backend based on the connection's
/// transport kind. Lets services hold a single `any RemoteTransport` while the
/// app supports SSH and Orgo profiles side by side.
final class MultiplexedRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let sshBackend: any RemoteTransport
    private let orgoBackend: any RemoteTransport

    init(ssh: any RemoteTransport, orgo: any RemoteTransport) {
        self.sshBackend = ssh
        self.orgoBackend = orgo
    }

    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?,
        allocateTTY: Bool
    ) async throws -> RemoteCommandResult {
        try await backend(for: connection).execute(
            on: connection,
            remoteCommand: remoteCommand,
            standardInput: standardInput,
            allocateTTY: allocateTTY
        )
    }

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response {
        try await backend(for: connection).executeJSON(
            on: connection,
            pythonScript: pythonScript,
            responseType: responseType
        )
    }

    func validateSuccessfulExit(_ result: RemoteCommandResult, for connection: ConnectionProfile?) throws {
        // Delegate to the backend that handled the call, so SSH-specific error
        // messages stay attached to SSH connections.
        if let connection {
            try backend(for: connection).validateSuccessfulExit(result, for: connection)
        } else {
            // No connection context — fall back to the protocol's default impl.
            // Calling the protocol-extension default requires upcasting through
            // the existential, which Swift handles automatically.
            try (sshBackend as any RemoteTransport).validateSuccessfulExit(result, for: nil)
        }
    }

    private func backend(for connection: ConnectionProfile) -> any RemoteTransport {
        switch connection.transport {
        case .ssh: sshBackend
        case .orgo: orgoBackend
        }
    }
}
