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

        let optionalUnknown = HermesRuntimeHealthSnapshot(
            cli: .available(version: "Hermes Agent v1.2.3"),
            hermesHome: .available(path: "~/.hermes"),
            components: Self.readyComponents.replacing(
                kind: .cua,
                with: HermesRuntimeComponentStatus(kind: .cua, value: "Optional")
            )
        )
        #expect(optionalUnknown.overallLevel == .ready)
    }

    @Test
    func runtimeStatusSnapshotReportsLocalOperationalReadiness() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-runtime-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent(".hermes", isDirectory: true)
        for directory in ["memories", "sessions", "skills", "cron"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try "Remember local operations.\n".write(
            to: home.appendingPathComponent("memories/MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"gateway_state":"running","updated_at":"2026-05-19T12:00:00Z"}"#.write(
            to: home.appendingPathComponent("gateway_state.json"),
            atomically: true,
            encoding: .utf8
        )

        let modelServer = HermesLocalModelServer(
            name: "Ollama",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            modelsPath: "models"
        )
        let runtimeStatus = HermesRuntimeStatus(
            executable: HermesRuntimeExecutable(path: "/Users/test/.local/bin/hermes", source: .fallback),
            version: HermesRuntimeVersion(label: "Hermes Agent v0.14.0", exitCode: 0, stderr: ""),
            home: HermesRuntimeHome(path: home.path, source: .default, exists: true),
            config: HermesRuntimeConfigStatus(
                files: HermesRuntimeConfigFileKind.allCases.map { inspect(kind: $0, home: home) }
            ),
            model: HermesRuntimeModelConfig(
                provider: "custom",
                defaultModel: "qwen2.5-coder:3b",
                baseURL: "http://127.0.0.1:11434/v1",
                sourcePath: home.appendingPathComponent("config.yaml").path
            ),
            update: HermesRuntimeUpdateStatus(state: .upToDate, source: .cache, cache: nil, message: nil),
            localModelServers: [
                HermesLocalModelServerStatus(
                    server: modelServer,
                    availability: .available,
                    statusCode: 200,
                    message: nil
                )
            ]
        )

        let snapshot = HermesRuntimeHealthSnapshot(runtimeStatus: runtimeStatus)

        #expect(snapshot.cli.level == .ready)
        #expect(snapshot.hermesHome.level == .ready)
        #expect(snapshot.activeSelection.modelName == "qwen2.5-coder:3b")
        #expect(snapshot.normalizedComponents.first { $0.kind == .memory }?.level == .ready)
        #expect(snapshot.normalizedComponents.first { $0.kind == .sessions }?.level == .ready)
        #expect(snapshot.normalizedComponents.first { $0.kind == .skills }?.level == .ready)
        #expect(snapshot.normalizedComponents.first { $0.kind == .cron }?.level == .ready)
        #expect(snapshot.normalizedComponents.first { $0.kind == .models }?.level == .ready)
        #expect(snapshot.normalizedComponents.first { $0.kind == .gateway }?.level == .ready)
        #expect(snapshot.overallLevel == .ready)
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

private func inspect(
    kind: HermesRuntimeConfigFileKind,
    home: URL
) -> HermesRuntimeConfigFileStatus {
    let url = home.appendingPathComponent(kind.relativePath)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

    return HermesRuntimeConfigFileStatus(
        kind: kind,
        path: url.path,
        exists: exists,
        isDirectory: exists && isDirectory.boolValue,
        isReadable: exists && FileManager.default.isReadableFile(atPath: url.path),
        sizeBytes: nil,
        modifiedAt: nil
    )
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
