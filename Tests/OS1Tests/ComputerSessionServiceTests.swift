import Foundation
import Testing
@testable import OS1

private final class StubComputerSessionProvider: ComputerSessionProviderClient, @unchecked Sendable {
    let provider: ComputerSessionProvider
    let isAvailable: Bool
    private(set) var startedRequests: [ComputerSessionRequest] = []

    init(provider: ComputerSessionProvider, isAvailable: Bool = true) {
        self.provider = provider
        self.isAvailable = isAvailable
    }

    func start(request: ComputerSessionRequest) async throws -> ComputerSessionResponse {
        startedRequests.append(request)
        return ComputerSessionResponse(
            sessionId: "\(provider.rawValue)_started",
            provider: provider,
            status: .completed,
            riskLevel: request.riskLevel,
            costEstimate: ComputerSessionCostEstimate(maxMinutes: request.maxMinutes)
        )
    }

    func status(sessionId: String) async throws -> ComputerSessionResponse {
        ComputerSessionResponse(
            sessionId: sessionId,
            provider: provider,
            status: .completed,
            riskLevel: .readOnly
        )
    }

    func stop(sessionId: String) async throws -> ComputerSessionResponse {
        ComputerSessionResponse(
            sessionId: sessionId,
            provider: provider,
            status: .completed,
            riskLevel: .readOnly
        )
    }
}

struct ComputerSessionServiceTests {
    @Test
    func autoBrowserPrefersAvailableCuaProvider() async throws {
        let cua = StubComputerSessionProvider(provider: .cua)
        let e2b = StubComputerSessionProvider(provider: .e2b)
        let service = ComputerSessionService(providers: [e2b, cua])

        let response = try await service.submit(
            ComputerSessionRequest(task: "Read public website", sessionType: .browser)
        )

        #expect(response.provider == .cua)
        #expect(response.status == .completed)
        #expect(cua.startedRequests.count == 1)
        #expect(e2b.startedRequests.isEmpty)
    }

    @Test
    func autoCodePrefersE2BBeforeCua() async throws {
        let cua = StubComputerSessionProvider(provider: .cua)
        let e2b = StubComputerSessionProvider(provider: .e2b)
        let service = ComputerSessionService(providers: [cua, e2b])

        let response = try await service.submit(
            ComputerSessionRequest(task: "Run file conversion", sessionType: .code)
        )

        #expect(response.provider == .e2b)
        #expect(response.status == .completed)
        #expect(e2b.startedRequests.count == 1)
        #expect(cua.startedRequests.isEmpty)
    }

    @Test
    func desktopSessionReturnsApprovalRecordBeforeStartingProvider() async throws {
        let cua = StubComputerSessionProvider(provider: .cua)
        let service = ComputerSessionService(
            providers: [cua],
            sessionIDFactory: { "cs_fixed" },
            approvalIDFactory: { "approval_fixed" }
        )

        let response = try await service.submit(
            ComputerSessionRequest(
                task: "Inspect vendor portal",
                riskLevel: .readOnly,
                sessionType: .desktop,
                providerPreference: .cua
            )
        )

        #expect(response.sessionId == "cs_fixed")
        #expect(response.provider == .cua)
        #expect(response.status == .approvalRequired)
        #expect(response.approvalId == "approval_fixed")
        #expect(cua.startedRequests.isEmpty)

        let approval = try #require(service.approvalRecord(approvalId: "approval_fixed"))
        #expect(approval.sessionId == "cs_fixed")
        #expect(approval.provider == .cua)
        #expect(approval.decision == .pending)
        #expect(approval.request.task == "Inspect vendor portal")
        #expect(approval.request.sessionType == .desktop)
    }

    @Test
    func approvingPendingSessionStartsProviderWithStoredRequest() async throws {
        let cua = StubComputerSessionProvider(provider: .cua)
        let service = ComputerSessionService(
            providers: [cua],
            sessionIDFactory: { "cs_fixed" },
            approvalIDFactory: { "approval_fixed" }
        )

        _ = try await service.submit(
            ComputerSessionRequest(
                task: " Inspect vendor portal ",
                riskLevel: .readOnly,
                sessionType: .desktop,
                providerPreference: .cua,
                maxMinutes: 120,
                allowedDomains: [" Example.com "]
            )
        )

        let response = try await service.approve(approvalId: "approval_fixed")
        let approval = try #require(service.approvalRecord(approvalId: "approval_fixed"))

        #expect(response.sessionId == "cs_fixed")
        #expect(response.approvalId == "approval_fixed")
        #expect(response.provider == .cua)
        #expect(response.status == .completed)
        #expect(cua.startedRequests.count == 1)
        #expect(cua.startedRequests.first?.task == "Inspect vendor portal")
        #expect(cua.startedRequests.first?.maxMinutes == ComputerSessionRequest.maxAllowedMinutes)
        #expect(cua.startedRequests.first?.allowedDomains == ["example.com"])
        #expect(approval.decision == .approved)
    }

    @Test
    func denyingPendingSessionDoesNotStartProvider() async throws {
        let cua = StubComputerSessionProvider(provider: .cua)
        let service = ComputerSessionService(
            providers: [cua],
            sessionIDFactory: { "cs_fixed" },
            approvalIDFactory: { "approval_fixed" }
        )

        _ = try await service.submit(
            ComputerSessionRequest(
                task: "Inspect vendor portal",
                riskLevel: .readOnly,
                sessionType: .desktop,
                providerPreference: .cua
            )
        )

        let response = try service.deny(approvalId: "approval_fixed", reason: "Out of scope")
        let approval = try #require(service.approvalRecord(approvalId: "approval_fixed"))

        #expect(response.sessionId == "cs_fixed")
        #expect(response.provider == .cua)
        #expect(response.status == .approvalDenied)
        #expect(response.summary == "Out of scope")
        #expect(cua.startedRequests.isEmpty)
        #expect(approval.decision == .denied)
        #expect(approval.denialReason == "Out of scope")
    }

    @Test
    func unknownApprovalIDFailsPredictably() async {
        let service = ComputerSessionService(providers: [
            StubComputerSessionProvider(provider: .cua)
        ])

        await #expect(throws: ComputerSessionServiceError.approvalNotFound("approval_missing")) {
            _ = try await service.approve(approvalId: "approval_missing")
        }

        #expect(throws: ComputerSessionServiceError.approvalNotFound("approval_missing")) {
            _ = try service.deny(approvalId: "approval_missing")
        }
    }

    @Test
    func resolvedApprovalCannotBeResolvedAgain() async throws {
        let cua = StubComputerSessionProvider(provider: .cua)
        let service = ComputerSessionService(
            providers: [cua],
            sessionIDFactory: { "cs_fixed" },
            approvalIDFactory: { "approval_fixed" }
        )

        _ = try await service.submit(
            ComputerSessionRequest(
                task: "Inspect vendor portal",
                riskLevel: .readOnly,
                sessionType: .desktop,
                providerPreference: .cua
            )
        )
        _ = try service.deny(approvalId: "approval_fixed")

        await #expect(throws: ComputerSessionServiceError.approvalAlreadyResolved("approval_fixed")) {
            _ = try await service.approve(approvalId: "approval_fixed")
        }
        #expect(cua.startedRequests.isEmpty)
    }

    @Test
    func unavailableDesktopProviderFailsBeforeCreatingApprovalRecord() async {
        let service = ComputerSessionService(
            providers: [CuaComputerSessionProvider()],
            sessionIDFactory: { "cs_fixed" },
            approvalIDFactory: { "approval_fixed" }
        )

        await #expect(throws: ComputerSessionServiceError.providerUnavailable(.cua)) {
            _ = try await service.submit(
                ComputerSessionRequest(
                    task: "Inspect vendor portal",
                    riskLevel: .readOnly,
                    sessionType: .desktop,
                    providerPreference: .cua
                )
            )
        }
    }

    @Test
    func unavailableCuaProviderIsReportedForUngatedBrowserSession() async {
        let service = ComputerSessionService(providers: [CuaComputerSessionProvider()])

        await #expect(throws: ComputerSessionServiceError.providerUnavailable(.cua)) {
            _ = try await service.submit(
                ComputerSessionRequest(
                    task: "Read public website",
                    sessionType: .browser,
                    providerPreference: .cua
                )
            )
        }
    }

    @Test
    func explicitUnconfiguredProviderIsRejectedBeforeApprovalRecord() async {
        let service = ComputerSessionService(providers: [CuaComputerSessionProvider()])

        await #expect(throws: ComputerSessionServiceError.unsupportedProviderPreference(.e2b)) {
            _ = try await service.submit(
                ComputerSessionRequest(
                    task: "Inspect vendor portal",
                    sessionType: .desktop,
                    providerPreference: .e2b
                )
            )
        }
    }

    @Test
    func autoDoesNotSelectConfiguredButUnavailableProvider() async {
        let service = ComputerSessionService(providers: [CuaComputerSessionProvider()])

        await #expect(throws: ComputerSessionServiceError.unsupportedProviderPreference(.auto)) {
            _ = try await service.submit(
                ComputerSessionRequest(
                    task: "Read public website",
                    sessionType: .browser,
                    providerPreference: .auto
                )
            )
        }
    }
}
