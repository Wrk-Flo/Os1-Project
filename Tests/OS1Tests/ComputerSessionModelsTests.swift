import Foundation
import Testing
@testable import OS1

struct ComputerSessionModelsTests {
    @Test
    func requestDefaultsToGovernedPublicBrowserSession() {
        let request = ComputerSessionRequest(task: "Collect public pricing details", providerPreference: .cua)

        #expect(request.riskLevel == .readOnly)
        #expect(request.sessionType == .browser)
        #expect(request.providerPreference == .cua)
        #expect(request.maxMinutes == 10)
        #expect(!request.requiresApproval)
        #expect(request.recordSession)
        #expect(request.credentialPolicy == .none)
        #expect(request.outputContract == ComputerSessionOutputContract())
        #expect(request.isValid)
    }

    @Test
    func credentialedSessionRequiresApprovalEvenWhenCallerTriesToDisableIt() {
        let request = ComputerSessionRequest(
            task: "Download invoices from vendor portal",
            riskLevel: .readOnly,
            sessionType: .desktop,
            providerPreference: .cua,
            requiresApproval: false,
            credentialPolicy: .userApproved
        )

        #expect(request.validationError == "Credentialed computer sessions require approval.")
        #expect(request.normalized.requiresApproval)
        #expect(request.normalized.validationError == nil)
    }

    @Test
    func sensitiveSessionNormalizesToRecordedAndApprovalGated() {
        let request = ComputerSessionRequest(
            task: " Inspect private CRM records ",
            riskLevel: .sensitive,
            sessionType: .desktop,
            providerPreference: .auto,
            maxMinutes: 90,
            requiresApproval: false,
            recordSession: false,
            allowedDomains: [" Example.com ", ""],
            blockedDomains: ["PAYMENTS.EXAMPLE.COM"]
        )

        #expect(request.validationError == "Sensitive computer sessions must be recorded.")

        let normalized = request.normalized
        #expect(normalized.task == "Inspect private CRM records")
        #expect(normalized.maxMinutes == ComputerSessionRequest.maxAllowedMinutes)
        #expect(normalized.requiresApproval)
        #expect(normalized.recordSession)
        #expect(normalized.allowedDomains == ["example.com"])
        #expect(normalized.blockedDomains == ["payments.example.com"])
        #expect(normalized.validationError == nil)
    }

    @Test
    func requestJSONUsesStableSnakeCaseEnumValues() throws {
        let request = ComputerSessionRequest(
            task: "Run visual check",
            riskLevel: .readOnly,
            sessionType: .desktop,
            providerPreference: .cua,
            maxMinutes: 5,
            requiresApproval: true,
            recordSession: true,
            credentialPolicy: .delegatedVaultReference
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["riskLevel"] as? String == "read_only")
        #expect(object["sessionType"] as? String == "desktop")
        #expect(object["providerPreference"] as? String == "cua")
        #expect(object["credentialPolicy"] as? String == "delegated_vault_reference")
    }

    @Test
    func responseRoundTripPreservesProviderStatusAndAuditFields() throws {
        let response = ComputerSessionResponse(
            sessionId: "cs_123",
            provider: .cua,
            status: .approvalRequired,
            riskLevel: .write,
            approvalId: "approval_456",
            artifacts: ["azure-blob://artifact"],
            summary: "Queued for approval.",
            auditLogId: "audit_789",
            replayRef: "replay_abc",
            costEstimate: ComputerSessionCostEstimate(maxMinutes: 10, providerUnits: "cua-minutes")
        )

        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ComputerSessionResponse.self, from: encoded)

        #expect(decoded == response)
        #expect(decoded.status == .approvalRequired)
        #expect(!decoded.status.isTerminal)
        #expect(ComputerSessionStatus.completed.isTerminal)
    }

    @Test
    func approvalRecordRoundTripPreservesStoredRequestAndDecision() throws {
        let record = ComputerSessionApprovalRecord(
            approvalId: "approval_123",
            sessionId: "cs_123",
            provider: .cua,
            request: ComputerSessionRequest(
                task: "Inspect vendor portal",
                riskLevel: .write,
                sessionType: .desktop,
                providerPreference: .cua,
                maxMinutes: 15,
                credentialPolicy: .userApproved
            ),
            decision: .denied,
            costEstimate: ComputerSessionCostEstimate(maxMinutes: 15, providerUnits: "cua-minutes"),
            denialReason: "Out of scope"
        )

        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ComputerSessionApprovalRecord.self, from: encoded)

        #expect(decoded == record)
        #expect(decoded.decision.isResolved)
        #expect(!ComputerSessionApprovalDecision.pending.isResolved)
    }
}
