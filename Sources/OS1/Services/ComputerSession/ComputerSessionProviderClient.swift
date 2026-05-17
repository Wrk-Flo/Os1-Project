import Foundation

enum ComputerSessionServiceError: LocalizedError, Equatable {
    case invalidRequest(String)
    case providerUnavailable(ComputerSessionProvider)
    case unsupportedProviderPreference(ComputerSessionProviderPreference)
    case providerNotImplemented(ComputerSessionProvider)
    case sessionNotFound(String)
    case approvalNotFound(String)
    case approvalAlreadyResolved(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            message
        case .providerUnavailable(let provider):
            "Computer session provider is unavailable: \(provider.rawValue)."
        case .unsupportedProviderPreference(let preference):
            "Computer session provider preference is unsupported: \(preference.rawValue)."
        case .providerNotImplemented(let provider):
            "Computer session provider is not implemented yet: \(provider.rawValue)."
        case .sessionNotFound(let sessionId):
            "Computer session was not found: \(sessionId)."
        case .approvalNotFound(let approvalId):
            "Computer session approval was not found: \(approvalId)."
        case .approvalAlreadyResolved(let approvalId):
            "Computer session approval is already resolved: \(approvalId)."
        }
    }
}

protocol ComputerSessionProviderClient: Sendable {
    var provider: ComputerSessionProvider { get }
    var isAvailable: Bool { get }

    func start(request: ComputerSessionRequest) async throws -> ComputerSessionResponse
    func status(sessionId: String) async throws -> ComputerSessionResponse
    func stop(sessionId: String) async throws -> ComputerSessionResponse
}

extension ComputerSessionProviderClient {
    var isAvailable: Bool { true }
}
