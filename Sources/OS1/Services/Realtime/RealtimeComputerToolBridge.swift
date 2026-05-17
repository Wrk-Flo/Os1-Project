import Foundation

struct RealtimeComputerTool: Encodable, Sendable {
    let type = "function"
    let name: String
    let description: String
    let parameters: AnyEncodable
}

struct RealtimeComputerToolCallResult: Encodable, Sendable {
    let isError: Bool
    let content: AnyEncodable
}

struct RealtimeComputerToolProviderStatus: Encodable, Equatable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
    let status: String
}

struct RealtimeComputerToolList: Sendable {
    let tools: [RealtimeComputerTool]
    let providers: [RealtimeComputerToolProviderStatus]
    let hasProviderError: Bool
}

enum RealtimeComputerToolBridgeError: LocalizedError, Equatable {
    case unsupportedTool(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            "Realtime computer tool is unsupported: \(name)."
        }
    }
}

protocol RealtimeComputerToolProviding: AnyObject {
    var providerID: String { get }
    var displayName: String { get }
    var unavailableStatus: String { get }
    var isConfigured: Bool { get }

    func canHandleTool(name: String) -> Bool
    func listRealtimeTools() async throws -> [RealtimeComputerTool]
    func callTool(name: String, arguments: [String: Any]) async throws -> RealtimeComputerToolCallResult
}

final class RealtimeComputerToolBridge: @unchecked Sendable {
    private let providers: [any RealtimeComputerToolProviding]
    private let allowedProviderIDs: Set<String>

    init(
        providers: [any RealtimeComputerToolProviding] = [],
        allowedProviderIDs: Set<String> = ["orgo"]
    ) {
        self.providers = providers
        self.allowedProviderIDs = allowedProviderIDs
    }

    convenience init(
        orgoAPIKeyProvider: @escaping @Sendable () -> String?,
        orgoDefaultComputerIDProvider: @escaping @Sendable () -> String?,
        isOrgoEnabledProvider: @escaping @Sendable () -> Bool = { true }
    ) {
        self.init(providers: [
            RealtimeOrgoMCPBridge(
                apiKeyProvider: orgoAPIKeyProvider,
                defaultComputerIDProvider: orgoDefaultComputerIDProvider,
                isEnabledProvider: isOrgoEnabledProvider
            ),
        ], allowedProviderIDs: ["orgo"])
    }

    func listTools() async -> RealtimeComputerToolList {
        var tools: [RealtimeComputerTool] = []
        var statuses: [RealtimeComputerToolProviderStatus] = []
        var hasProviderError = false

        for provider in providers {
            guard allowedProviderIDs.contains(provider.providerID) else { continue }

            guard provider.isConfigured else {
                statuses.append(
                    RealtimeComputerToolProviderStatus(
                        id: provider.providerID,
                        name: provider.displayName,
                        enabled: false,
                        status: provider.unavailableStatus
                    )
                )
                continue
            }

            do {
                let providerTools = try await provider.listRealtimeTools()
                let ownedTools = providerTools.filter { provider.canHandleTool(name: $0.name) }
                tools.append(contentsOf: ownedTools)
                statuses.append(
                    RealtimeComputerToolProviderStatus(
                        id: provider.providerID,
                        name: provider.displayName,
                        enabled: true,
                        status: "\(provider.displayName) ready: \(ownedTools.count) tools"
                    )
                )
            } catch {
                hasProviderError = true
                statuses.append(
                    RealtimeComputerToolProviderStatus(
                        id: provider.providerID,
                        name: provider.displayName,
                        enabled: false,
                        status: error.localizedDescription
                    )
                )
            }
        }

        return RealtimeComputerToolList(
            tools: tools,
            providers: statuses,
            hasProviderError: hasProviderError
        )
    }

    func canHandleTool(name: String) -> Bool {
        configuredProvider(forToolName: name) != nil
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> RealtimeComputerToolCallResult {
        guard let provider = configuredProvider(forToolName: name) else {
            throw RealtimeComputerToolBridgeError.unsupportedTool(name)
        }
        let listedTools = try await provider.listRealtimeTools()
        guard listedTools.contains(where: { $0.name == name && provider.canHandleTool(name: $0.name) }) else {
            throw RealtimeComputerToolBridgeError.unsupportedTool(name)
        }

        return try await provider.callTool(name: name, arguments: arguments)
    }

    private func configuredProvider(forToolName name: String) -> (any RealtimeComputerToolProviding)? {
        providers.first { provider in
            allowedProviderIDs.contains(provider.providerID) && provider.isConfigured && provider.canHandleTool(name: name)
        }
    }
}

extension AnyEncodable: @unchecked Sendable {}
