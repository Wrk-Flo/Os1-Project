import Foundation
import Testing
@testable import OS1

private enum StubRealtimeToolError: LocalizedError {
    case failed

    var errorDescription: String? {
        "stub provider failed"
    }
}

private final class StubRealtimeComputerToolProvider: RealtimeComputerToolProviding, @unchecked Sendable {
    let providerID: String
    let displayName: String
    let unavailableStatus: String
    var isConfigured: Bool
    var tools: [RealtimeComputerTool]
    var callResult: RealtimeComputerToolCallResult
    var listShouldFail = false
    var lastCallName: String?
    var lastArgumentValue: String?

    init(
        providerID: String = "orgo",
        displayName: String = "Orgo MCP",
        unavailableStatus: String = "unavailable",
        isConfigured: Bool = true,
        tools: [RealtimeComputerTool] = [
            RealtimeComputerTool(
                name: "orgo_screenshot",
                description: "Take a screenshot.",
                parameters: AnyEncodable(["type": "object", "properties": [:]])
            )
        ],
        callResult: RealtimeComputerToolCallResult = RealtimeComputerToolCallResult(
            isError: false,
            content: AnyEncodable([["type": "text", "text": "ok"]])
        )
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.unavailableStatus = unavailableStatus
        self.isConfigured = isConfigured
        self.tools = tools
        self.callResult = callResult
    }

    func canHandleTool(name: String) -> Bool {
        name.hasPrefix("\(providerID)_")
    }

    func listRealtimeTools() async throws -> [RealtimeComputerTool] {
        if listShouldFail {
            throw StubRealtimeToolError.failed
        }
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> RealtimeComputerToolCallResult {
        lastCallName = name
        lastArgumentValue = arguments["value"] as? String
        return callResult
    }
}

struct RealtimeComputerToolBridgeTests {
    @Test
    func defaultBridgeIgnoresUnallowedProviders() async {
        let provider = StubRealtimeComputerToolProvider(
            providerID: "cua",
            displayName: "Cua",
            unavailableStatus: "Cua realtime tools are not exposed yet",
            isConfigured: false
        )
        let bridge = RealtimeComputerToolBridge(providers: [provider])

        let result = await bridge.listTools()

        #expect(result.tools.isEmpty)
        #expect(result.providers.isEmpty)
        #expect(!result.hasProviderError)
        #expect(!bridge.canHandleTool(name: "cua_screenshot"))

        await #expect(throws: RealtimeComputerToolBridgeError.unsupportedTool("cua_screenshot")) {
            _ = try await bridge.callTool(name: "cua_screenshot", arguments: [:])
        }
        #expect(provider.lastCallName == nil)
    }

    @Test
    func reportsExplicitlyAllowedUnavailableProvidersWithoutExposingTools() async {
        let provider = StubRealtimeComputerToolProvider(
            providerID: "cua",
            displayName: "Cua",
            unavailableStatus: "Cua realtime tools are not exposed yet",
            isConfigured: false
        )
        let bridge = RealtimeComputerToolBridge(
            providers: [provider],
            allowedProviderIDs: ["cua"]
        )

        let result = await bridge.listTools()

        #expect(result.tools.isEmpty)
        #expect(result.providers == [
            RealtimeComputerToolProviderStatus(
                id: "cua",
                name: "Cua",
                enabled: false,
                status: "Cua realtime tools are not exposed yet"
            )
        ])
        #expect(!result.hasProviderError)
        #expect(!bridge.canHandleTool(name: "cua_screenshot"))

        await #expect(throws: RealtimeComputerToolBridgeError.unsupportedTool("cua_screenshot")) {
            _ = try await bridge.callTool(name: "cua_screenshot", arguments: [:])
        }
        #expect(provider.lastCallName == nil)
    }

    @Test
    func aggregatesConfiguredProviderToolsAndStatus() async {
        let provider = StubRealtimeComputerToolProvider()
        let bridge = RealtimeComputerToolBridge(providers: [provider])

        let result = await bridge.listTools()

        #expect(result.tools.map(\.name) == ["orgo_screenshot"])
        #expect(result.providers == [
            RealtimeComputerToolProviderStatus(
                id: "orgo",
                name: "Orgo MCP",
                enabled: true,
                status: "Orgo MCP ready: 1 tools"
            )
        ])
        #expect(!result.hasProviderError)
    }

    @Test
    func filtersListedToolsToProviderOwnedNames() async {
        let provider = StubRealtimeComputerToolProvider(
            tools: [
                RealtimeComputerTool(
                    name: "orgo_screenshot",
                    description: "Take a screenshot.",
                    parameters: AnyEncodable(["type": "object", "properties": [:]])
                ),
                RealtimeComputerTool(
                    name: "cua_screenshot",
                    description: "Take a screenshot.",
                    parameters: AnyEncodable(["type": "object", "properties": [:]])
                ),
            ]
        )
        let bridge = RealtimeComputerToolBridge(providers: [provider])

        let result = await bridge.listTools()

        #expect(result.tools.map(\.name) == ["orgo_screenshot"])
        #expect(result.providers == [
            RealtimeComputerToolProviderStatus(
                id: "orgo",
                name: "Orgo MCP",
                enabled: true,
                status: "Orgo MCP ready: 1 tools"
            )
        ])
        #expect(!bridge.canHandleTool(name: "cua_screenshot"))
    }

    @Test
    func marksConfiguredProviderListFailuresWithoutLeakingTools() async {
        let provider = StubRealtimeComputerToolProvider()
        provider.listShouldFail = true
        let bridge = RealtimeComputerToolBridge(providers: [provider])

        let result = await bridge.listTools()

        #expect(result.tools.isEmpty)
        #expect(result.providers == [
            RealtimeComputerToolProviderStatus(
                id: "orgo",
                name: "Orgo MCP",
                enabled: false,
                status: "stub provider failed"
            )
        ])
        #expect(result.hasProviderError)
    }

    @Test
    func dispatchesToolCallsByProviderOwnedPrefix() async throws {
        let provider = StubRealtimeComputerToolProvider()
        let bridge = RealtimeComputerToolBridge(providers: [provider])

        let result = try await bridge.callTool(
            name: "orgo_screenshot",
            arguments: ["value": "capture"]
        )

        #expect(!result.isError)
        #expect(provider.lastCallName == "orgo_screenshot")
        #expect(provider.lastArgumentValue == "capture")
    }

    @Test
    func rejectsUnknownToolNamesBeforeProviderCall() async {
        let bridge = RealtimeComputerToolBridge(providers: [
            StubRealtimeComputerToolProvider(providerID: "orgo")
        ])

        await #expect(throws: RealtimeComputerToolBridgeError.unsupportedTool("cua_screenshot")) {
            _ = try await bridge.callTool(name: "cua_screenshot", arguments: [:])
        }
    }

    @Test
    func rejectsProviderOwnedNamesThatWereNotListed() async {
        let provider = StubRealtimeComputerToolProvider(
            tools: [
                RealtimeComputerTool(
                    name: "orgo_screenshot",
                    description: "Take a screenshot.",
                    parameters: AnyEncodable(["type": "object", "properties": [:]])
                )
            ]
        )
        let bridge = RealtimeComputerToolBridge(providers: [provider])

        await #expect(throws: RealtimeComputerToolBridgeError.unsupportedTool("orgo_shell")) {
            _ = try await bridge.callTool(name: "orgo_shell", arguments: [:])
        }
        #expect(provider.lastCallName == nil)
    }
}
