import Foundation

struct RemoteCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum RemoteTransportError: LocalizedError {
    case invalidConnection(String)
    case launchFailure(String)
    case localFailure(String)
    case remoteFailure(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidConnection(let message),
             .launchFailure(let message),
             .localFailure(let message),
             .remoteFailure(let message),
             .invalidResponse(let message):
            message
        }
    }
}

protocol RemoteTransport: Sendable {
    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?,
        allocateTTY: Bool
    ) async throws -> RemoteCommandResult

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response

    func validateSuccessfulExit(_ result: RemoteCommandResult, for connection: ConnectionProfile?) throws
}

extension RemoteTransport {
    func validateSuccessfulExit(_ result: RemoteCommandResult, for connection: ConnectionProfile? = nil) throws {
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? stdout : stderr
            let message = detail.isEmpty ? "Remote command failed with exit code \(result.exitCode)." : detail
            throw RemoteTransportError.remoteFailure(message)
        }
    }
}
