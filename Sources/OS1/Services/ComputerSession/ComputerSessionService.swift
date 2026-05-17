import Foundation

final class ComputerSessionService: @unchecked Sendable {
    typealias SessionIDFactory = @Sendable () -> String
    typealias ApprovalIDFactory = @Sendable () -> String

    private let providers: [ComputerSessionProvider: any ComputerSessionProviderClient]
    private let sessionIDFactory: SessionIDFactory
    private let approvalIDFactory: ApprovalIDFactory
    private let approvalLock = NSLock()
    private var approvalsByID: [String: ComputerSessionApprovalRecord] = [:]

    init(
        providers: [any ComputerSessionProviderClient],
        sessionIDFactory: @escaping SessionIDFactory = {
            "cs_\(UUID().uuidString.lowercased())"
        },
        approvalIDFactory: @escaping ApprovalIDFactory = {
            "approval_\(UUID().uuidString.lowercased())"
        }
    ) {
        var indexed: [ComputerSessionProvider: any ComputerSessionProviderClient] = [:]
        for provider in providers {
            indexed[provider.provider] = provider
        }
        self.providers = indexed
        self.sessionIDFactory = sessionIDFactory
        self.approvalIDFactory = approvalIDFactory
    }

    var availableProviders: Set<ComputerSessionProvider> {
        Set(providers.values.filter(\.isAvailable).map(\.provider))
    }

    var configuredProviders: Set<ComputerSessionProvider> {
        Set(providers.keys)
    }

    func submit(_ request: ComputerSessionRequest) async throws -> ComputerSessionResponse {
        let normalized = request.normalized
        if let validationError = normalized.validationError {
            throw ComputerSessionServiceError.invalidRequest(validationError)
        }

        let provider = try resolveProvider(for: normalized)
        let costEstimate = ComputerSessionCostEstimate(
            maxMinutes: normalized.maxMinutes,
            providerUnits: "\(provider.rawValue)-minutes"
        )

        guard let client = providers[provider], client.isAvailable else {
            throw ComputerSessionServiceError.providerUnavailable(provider)
        }

        if requiresApproval(normalized) {
            let sessionId = sessionIDFactory()
            let approvalId = approvalIDFactory()
            let approval = ComputerSessionApprovalRecord(
                approvalId: approvalId,
                sessionId: sessionId,
                provider: provider,
                request: normalized,
                costEstimate: costEstimate
            )
            storeApproval(approval)

            return ComputerSessionResponse(
                sessionId: sessionId,
                provider: provider,
                status: .approvalRequired,
                riskLevel: normalized.riskLevel,
                approvalId: approvalId,
                costEstimate: costEstimate
            )
        }

        return try await client.start(request: normalized)
    }

    func approvalRecord(approvalId: String) -> ComputerSessionApprovalRecord? {
        approvalLock.lock(); defer { approvalLock.unlock() }
        return approvalsByID[approvalId]
    }

    func approve(approvalId: String) async throws -> ComputerSessionResponse {
        let approval = try reserveApprovalForStart(approvalId: approvalId)
        guard let client = providers[approval.provider], client.isAvailable else {
            restoreApprovalToPending(approval)
            throw ComputerSessionServiceError.providerUnavailable(approval.provider)
        }

        do {
            let providerResponse = try await client.start(request: approval.request)
            return ComputerSessionResponse(
                sessionId: approval.sessionId,
                provider: providerResponse.provider,
                status: providerResponse.status,
                riskLevel: providerResponse.riskLevel,
                approvalId: approval.approvalId,
                artifacts: providerResponse.artifacts,
                summary: providerResponse.summary,
                auditLogId: providerResponse.auditLogId,
                replayRef: providerResponse.replayRef,
                costEstimate: providerResponse.costEstimate ?? approval.costEstimate
            )
        } catch {
            restoreApprovalToPending(approval)
            throw error
        }
    }

    func deny(approvalId: String, reason: String? = nil) throws -> ComputerSessionResponse {
        let approval = try resolveApproval(
            approvalId: approvalId,
            decision: .denied,
            denialReason: reason
        )

        return ComputerSessionResponse(
            sessionId: approval.sessionId,
            provider: approval.provider,
            status: .approvalDenied,
            riskLevel: approval.request.riskLevel,
            approvalId: approval.approvalId,
            summary: reason,
            costEstimate: approval.costEstimate
        )
    }

    func status(sessionId: String, provider: ComputerSessionProvider) async throws -> ComputerSessionResponse {
        guard let client = providers[provider], client.isAvailable else {
            throw ComputerSessionServiceError.providerUnavailable(provider)
        }
        return try await client.status(sessionId: sessionId)
    }

    func stop(sessionId: String, provider: ComputerSessionProvider) async throws -> ComputerSessionResponse {
        guard let client = providers[provider], client.isAvailable else {
            throw ComputerSessionServiceError.providerUnavailable(provider)
        }
        return try await client.stop(sessionId: sessionId)
    }

    func resolveProvider(for request: ComputerSessionRequest) throws -> ComputerSessionProvider {
        func configured(_ provider: ComputerSessionProvider) throws -> ComputerSessionProvider {
            guard providers[provider] != nil else {
                throw ComputerSessionServiceError.unsupportedProviderPreference(request.providerPreference)
            }
            return provider
        }

        switch request.providerPreference {
        case .cua:
            return try configured(.cua)
        case .e2b:
            return try configured(.e2b)
        case .azure:
            return try configured(.azure)
        case .orgo:
            return try configured(.orgo)
        case .local:
            return try configured(.local)
        case .auto:
            return try automaticProvider(for: request)
        }
    }

    func requiresApproval(_ request: ComputerSessionRequest) -> Bool {
        request.requiresApproval ||
            request.credentialPolicy != .none ||
            request.riskLevel.requiresApprovalByDefault ||
            request.sessionType == .desktop
    }

    private func automaticProvider(for request: ComputerSessionRequest) throws -> ComputerSessionProvider {
        let candidates: [ComputerSessionProvider]
        switch request.sessionType {
        case .code:
            candidates = [.e2b, .azure, .local, .cua, .orgo]
        case .browser:
            candidates = [.cua, .e2b, .orgo, .azure, .local]
        case .desktop:
            candidates = [.cua, .orgo, .e2b, .azure, .local]
        }

        if let available = candidates.first(where: { providers[$0]?.isAvailable == true }) {
            return available
        }

        throw ComputerSessionServiceError.unsupportedProviderPreference(.auto)
    }

    private func storeApproval(_ approval: ComputerSessionApprovalRecord) {
        approvalLock.lock(); defer { approvalLock.unlock() }
        approvalsByID[approval.approvalId] = approval
    }

    private func reserveApprovalForStart(approvalId: String) throws -> ComputerSessionApprovalRecord {
        approvalLock.lock(); defer { approvalLock.unlock() }

        guard var approval = approvalsByID[approvalId] else {
            throw ComputerSessionServiceError.approvalNotFound(approvalId)
        }
        guard !approval.decision.isResolved else {
            throw ComputerSessionServiceError.approvalAlreadyResolved(approvalId)
        }

        approval.decision = .approved
        approvalsByID[approvalId] = approval
        return approval
    }

    private func restoreApprovalToPending(_ approval: ComputerSessionApprovalRecord) {
        approvalLock.lock(); defer { approvalLock.unlock() }
        guard approvalsByID[approval.approvalId]?.decision == .approved else { return }
        var restored = approval
        restored.decision = .pending
        restored.denialReason = nil
        approvalsByID[approval.approvalId] = restored
    }

    private func resolveApproval(
        approvalId: String,
        decision: ComputerSessionApprovalDecision,
        denialReason: String? = nil
    ) throws -> ComputerSessionApprovalRecord {
        approvalLock.lock(); defer { approvalLock.unlock() }

        guard var approval = approvalsByID[approvalId] else {
            throw ComputerSessionServiceError.approvalNotFound(approvalId)
        }
        guard !approval.decision.isResolved else {
            throw ComputerSessionServiceError.approvalAlreadyResolved(approvalId)
        }

        approval.decision = decision
        approval.denialReason = denialReason
        approvalsByID[approvalId] = approval
        return approval
    }
}
