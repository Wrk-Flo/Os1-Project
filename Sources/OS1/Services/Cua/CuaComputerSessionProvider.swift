import Foundation

struct CuaComputerSessionConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var baseURL: URL?
    var defaultMaxMinutes: Int

    init(
        isEnabled: Bool = false,
        baseURL: URL? = nil,
        defaultMaxMinutes: Int = ComputerSessionRequest.defaultMaxMinutes
    ) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.defaultMaxMinutes = ComputerSessionRequest.clampedMinutes(defaultMaxMinutes)
    }
}

final class CuaComputerSessionProvider: ComputerSessionProviderClient, @unchecked Sendable {
    let provider: ComputerSessionProvider = .cua
    private let config: CuaComputerSessionConfig
    private let credentialStore: CuaCredentialStore?

    init(
        config: CuaComputerSessionConfig = CuaComputerSessionConfig(),
        credentialStore: CuaCredentialStore? = nil
    ) {
        self.config = config
        self.credentialStore = credentialStore
    }

    var isAvailable: Bool {
        config.isEnabled && credentialStore?.hasAPIKey == true
    }

    func start(request: ComputerSessionRequest) async throws -> ComputerSessionResponse {
        guard isAvailable else {
            throw ComputerSessionServiceError.providerUnavailable(.cua)
        }

        throw ComputerSessionServiceError.providerNotImplemented(.cua)
    }

    func status(sessionId: String) async throws -> ComputerSessionResponse {
        throw ComputerSessionServiceError.sessionNotFound(sessionId)
    }

    func stop(sessionId: String) async throws -> ComputerSessionResponse {
        throw ComputerSessionServiceError.sessionNotFound(sessionId)
    }
}
