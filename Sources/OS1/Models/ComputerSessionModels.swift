import Foundation

enum ComputerSessionProviderPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case cua
    case e2b
    case azure
    case orgo
    case local

    var id: String { rawValue }
}

enum ComputerSessionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case cua
    case e2b
    case azure
    case orgo
    case local

    var id: String { rawValue }
}

enum ComputerSessionRiskLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "read_only"
    case draft
    case write
    case sensitive

    var id: String { rawValue }

    var requiresApprovalByDefault: Bool {
        switch self {
        case .readOnly:
            false
        case .draft, .write, .sensitive:
            true
        }
    }
}

enum ComputerSessionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case browser
    case desktop
    case code

    var id: String { rawValue }
}

enum ComputerSessionCredentialPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case userApproved = "user_approved"
    case delegatedVaultReference = "delegated_vault_reference"

    var id: String { rawValue }
}

enum ComputerSessionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case queued
    case policyClassified = "policy_classified"
    case approvalRequired = "approval_required"
    case approved
    case sandboxAllocating = "sandbox_allocating"
    case sandboxReady = "sandbox_ready"
    case agentRunning = "agent_running"
    case resultPackaging = "result_packaging"
    case completed
    case failed
    case approvalDenied = "approval_denied"
    case budgetExhausted = "budget_exhausted"
    case policyViolation = "policy_violation"
    case cleanupFailed = "cleanup_failed"

    var id: String { rawValue }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .approvalDenied, .budgetExhausted, .policyViolation, .cleanupFailed:
            true
        case .queued, .policyClassified, .approvalRequired, .approved, .sandboxAllocating, .sandboxReady, .agentRunning, .resultPackaging:
            false
        }
    }
}

enum ComputerSessionApprovalDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case approved
    case denied

    var id: String { rawValue }

    var isResolved: Bool {
        switch self {
        case .pending:
            false
        case .approved, .denied:
            true
        }
    }
}

struct ComputerSessionOutputContract: Codable, Equatable, Sendable {
    var artifacts: Bool
    var summary: Bool
    var screenshots: Bool
    var actionLog: Bool

    init(
        artifacts: Bool = true,
        summary: Bool = true,
        screenshots: Bool = true,
        actionLog: Bool = true
    ) {
        self.artifacts = artifacts
        self.summary = summary
        self.screenshots = screenshots
        self.actionLog = actionLog
    }
}

struct ComputerSessionCostEstimate: Codable, Equatable, Sendable {
    var maxMinutes: Int
    var providerUnits: String?

    init(maxMinutes: Int, providerUnits: String? = nil) {
        self.maxMinutes = maxMinutes
        self.providerUnits = providerUnits
    }
}

struct ComputerSessionRequest: Codable, Equatable, Sendable {
    static let defaultMaxMinutes = 10
    static let maxAllowedMinutes = 60

    var task: String
    var riskLevel: ComputerSessionRiskLevel
    var sessionType: ComputerSessionType
    var providerPreference: ComputerSessionProviderPreference
    var maxMinutes: Int
    var requiresApproval: Bool
    var recordSession: Bool
    var allowedDomains: [String]
    var blockedDomains: [String]
    var credentialPolicy: ComputerSessionCredentialPolicy
    var outputContract: ComputerSessionOutputContract

    init(
        task: String,
        riskLevel: ComputerSessionRiskLevel = .readOnly,
        sessionType: ComputerSessionType = .browser,
        providerPreference: ComputerSessionProviderPreference = .auto,
        maxMinutes: Int = ComputerSessionRequest.defaultMaxMinutes,
        requiresApproval: Bool? = nil,
        recordSession: Bool = true,
        allowedDomains: [String] = [],
        blockedDomains: [String] = [],
        credentialPolicy: ComputerSessionCredentialPolicy = .none,
        outputContract: ComputerSessionOutputContract = ComputerSessionOutputContract()
    ) {
        self.task = task
        self.riskLevel = riskLevel
        self.sessionType = sessionType
        self.providerPreference = providerPreference
        self.maxMinutes = Self.clampedMaxMinutes(maxMinutes)
        self.requiresApproval = requiresApproval ?? Self.defaultApprovalRequirement(
            riskLevel: riskLevel,
            credentialPolicy: credentialPolicy
        )
        self.recordSession = recordSession
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.credentialPolicy = credentialPolicy
        self.outputContract = outputContract
    }

    var validationError: String? {
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Computer session task is required."
        }

        if credentialPolicy != .none && !requiresApproval {
            return "Credentialed computer sessions require approval."
        }

        if riskLevel == .sensitive && !recordSession {
            return "Sensitive computer sessions must be recorded."
        }

        return nil
    }

    var isValid: Bool {
        validationError == nil
    }

    var normalized: ComputerSessionRequest {
        var copy = self
        copy.task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.maxMinutes = Self.clampedMaxMinutes(maxMinutes)
        copy.allowedDomains = Self.normalizedDomains(allowedDomains)
        copy.blockedDomains = Self.normalizedDomains(blockedDomains)
        copy.requiresApproval = copy.requiresApproval || Self.defaultApprovalRequirement(
            riskLevel: copy.riskLevel,
            credentialPolicy: copy.credentialPolicy
        )
        if copy.riskLevel == .sensitive {
            copy.recordSession = true
        }
        return copy
    }

    private static func defaultApprovalRequirement(
        riskLevel: ComputerSessionRiskLevel,
        credentialPolicy: ComputerSessionCredentialPolicy
    ) -> Bool {
        riskLevel.requiresApprovalByDefault || credentialPolicy != .none
    }

    private static func clampedMaxMinutes(_ value: Int) -> Int {
        min(max(value, 1), maxAllowedMinutes)
    }

    static func clampedMinutes(_ value: Int) -> Int {
        clampedMaxMinutes(value)
    }

    private static func normalizedDomains(_ domains: [String]) -> [String] {
        domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

struct ComputerSessionResponse: Codable, Equatable, Sendable {
    var sessionId: String
    var provider: ComputerSessionProvider
    var status: ComputerSessionStatus
    var riskLevel: ComputerSessionRiskLevel
    var approvalId: String?
    var artifacts: [String]
    var summary: String?
    var auditLogId: String?
    var replayRef: String?
    var costEstimate: ComputerSessionCostEstimate?

    init(
        sessionId: String,
        provider: ComputerSessionProvider,
        status: ComputerSessionStatus,
        riskLevel: ComputerSessionRiskLevel,
        approvalId: String? = nil,
        artifacts: [String] = [],
        summary: String? = nil,
        auditLogId: String? = nil,
        replayRef: String? = nil,
        costEstimate: ComputerSessionCostEstimate? = nil
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.status = status
        self.riskLevel = riskLevel
        self.approvalId = approvalId
        self.artifacts = artifacts
        self.summary = summary
        self.auditLogId = auditLogId
        self.replayRef = replayRef
        self.costEstimate = costEstimate
    }
}

struct ComputerSessionApprovalRecord: Codable, Equatable, Sendable {
    var approvalId: String
    var sessionId: String
    var provider: ComputerSessionProvider
    var request: ComputerSessionRequest
    var decision: ComputerSessionApprovalDecision
    var costEstimate: ComputerSessionCostEstimate
    var denialReason: String?

    init(
        approvalId: String,
        sessionId: String,
        provider: ComputerSessionProvider,
        request: ComputerSessionRequest,
        decision: ComputerSessionApprovalDecision = .pending,
        costEstimate: ComputerSessionCostEstimate,
        denialReason: String? = nil
    ) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.provider = provider
        self.request = request
        self.decision = decision
        self.costEstimate = costEstimate
        self.denialReason = denialReason
    }
}
