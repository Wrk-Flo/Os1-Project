import Foundation
import Testing
@testable import OS1

struct HermesRuntimeViewModelTests {
    @Test
    @MainActor
    func statusRowsFillMissingComponentsInCanonicalOrder() {
        let viewModel = HermesRuntimeHealthViewModel(
            snapshot: HermesRuntimeHealthSnapshot(
                components: [
                    .ready(.gateway, value: "Running"),
                    .missing(.memory, detail: "MEMORY.md was not found"),
                ]
            )
        )

        #expect(viewModel.statusRows.map(\.kind) == HermesRuntimeComponentStatus.Kind.allCases)
        #expect(viewModel.statusRows.first { $0.kind == .gateway }?.level == .ready)
        #expect(viewModel.statusRows.first { $0.kind == .memory }?.level == .unavailable)
        #expect(viewModel.statusRows.first { $0.kind == .sessions }?.level == .unknown)
    }

    @Test
    func overallLevelPrioritizesCliAndCoreRuntimeState() {
        let ready = HermesRuntimeHealthSnapshot(
            cli: .available(version: "Hermes Agent v1.2.3"),
            hermesHome: .available(path: "~/.hermes", source: "HERMES_HOME"),
            components: Self.readyComponents
        )
        #expect(ready.overallLevel == .ready)

        let missingCLI = HermesRuntimeHealthSnapshot(
            cli: .missing(detail: "hermes was not found on PATH"),
            hermesHome: .available(path: "~/.hermes"),
            components: Self.readyComponents
        )
        #expect(missingCLI.overallLevel == .unavailable)

        let missingCua = HermesRuntimeHealthSnapshot(
            cli: .available(version: "Hermes Agent v1.2.3"),
            hermesHome: .available(path: "~/.hermes"),
            components: Self.readyComponents.replacing(
                kind: .cua,
                with: .missing(.cua, detail: "Cua provider is not configured")
            )
        )
        #expect(missingCua.overallLevel == .degraded)
    }

    @Test
    @MainActor
    func refreshHandlerUpdatesSnapshotAndTimestamp() async {
        let checkedAt = Date(timeIntervalSince1970: 42)
        let refreshed = HermesRuntimeHealthSnapshot(
            cli: .available(version: "Hermes Agent v9.9.9", executablePath: "/usr/local/bin/hermes"),
            hermesHome: .available(path: "~/.hermes", source: "default"),
            activeSelection: HermesRuntimeActiveSelection(
                providerName: "openai",
                modelName: "gpt-5.1"
            ),
            components: Self.readyComponents,
            scopeLabel: "Local Mac",
            checkedAt: checkedAt
        )
        let viewModel = HermesRuntimeHealthViewModel(refresh: { refreshed })

        await viewModel.refresh()

        #expect(viewModel.snapshot == refreshed)
        #expect(viewModel.lastRefreshedAt == checkedAt)
        #expect(viewModel.lastRefreshError == nil)
    }

    @Test
    @MainActor
    func refreshFailureKeepsExistingSnapshotAndPublishesError() async {
        let original = HermesRuntimeHealthSnapshot(
            cli: .available(version: "Hermes Agent v1.0.0"),
            hermesHome: .available(path: "~/.hermes"),
            components: Self.readyComponents
        )
        let viewModel = HermesRuntimeHealthViewModel(snapshot: original) {
            throw RefreshError.probeFailed
        }

        await viewModel.refresh()

        #expect(viewModel.snapshot == original)
        #expect(viewModel.lastRefreshError == "Probe failed")
    }

    private static var readyComponents: [HermesRuntimeComponentStatus] {
        HermesRuntimeComponentStatus.Kind.allCases.map { kind in
            .ready(kind, value: "Ready")
        }
    }
}

private enum RefreshError: LocalizedError {
    case probeFailed

    var errorDescription: String? {
        "Probe failed"
    }
}

private extension Array where Element == HermesRuntimeComponentStatus {
    func replacing(
        kind: HermesRuntimeComponentStatus.Kind,
        with replacement: HermesRuntimeComponentStatus
    ) -> [HermesRuntimeComponentStatus] {
        map { status in
            status.kind == kind ? replacement : status
        }
    }
}
