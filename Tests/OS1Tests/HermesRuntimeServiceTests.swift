import Foundation
import Testing
@testable import OS1

struct HermesRuntimeServiceTests {
    @Test
    func detectFindsPathExecutableAndReadsVersion() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hermes = try sandbox.writeExecutable(at: bin.appendingPathComponent("hermes"))

        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(
                stdout: "\nHermes Agent v0.12.3\nPython: ok",
                stderr: "",
                exitCode: 0
            ))
        ])

        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": bin.path, "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )

        let detection = await service.detect()

        #expect(detection.executable?.path == hermes.standardizedFileURL.path)
        #expect(detection.executable?.source == .path)
        #expect(detection.version?.label == "Hermes Agent v0.12.3")
        #expect(detection.isAvailable)

        let request = try #require(runner.capturedRequests().first)
        #expect(request.arguments == ["version"])
        #expect(request.environment?["HERMES_HOME"] == sandbox.home.appendingPathComponent(".hermes").path)
    }

    @Test
    func statusReportsHermesHomeConfigUpdateCacheAndLocalModels() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try sandbox.writeExecutable(at: bin.appendingPathComponent("hermes"))

        let hermesHome = sandbox.home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try sandbox.write(
            """
            model:
              provider: ollama
              default: qwen2.5-coder:3b
              base_url: http://127.0.0.1:11434/v1
            """,
            to: hermesHome.appendingPathComponent("config.yaml")
        )
        try sandbox.write("OLLAMA_API_KEY=\"local\"\n", to: hermesHome.appendingPathComponent(".env"))
        try sandbox.write("{\"active_provider\":\"ollama\"}", to: hermesHome.appendingPathComponent("auth.json"))
        try sandbox.write(
            "{\"ts\": 1760000000, \"behind\": 3, \"rev\": \"abc123\"}",
            to: hermesHome.appendingPathComponent(".update_check")
        )

        let modelServer = HermesLocalModelServer(
            name: "Ollama",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            modelsPath: "models"
        )
        let modelStatus = HermesLocalModelServerStatus(
            server: modelServer,
            availability: .available,
            statusCode: 200,
            message: nil
        )
        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(stdout: "Hermes Agent v1.0.0", stderr: "", exitCode: 0))
        ])
        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": bin.path, "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [modelServer],
            localModelProbe: FakeHermesLocalModelProbe(statuses: [modelServer.name: modelStatus])
        )

        let status = await service.status()

        #expect(status.isAvailable)
        #expect(status.home.path == hermesHome.standardizedFileURL.path)
        #expect(status.home.exists)
        #expect(status.config.file(.configYAML)?.exists == true)
        #expect(status.config.file(.env)?.isReadable == true)
        #expect(status.config.file(.authJSON)?.exists == true)
        #expect(status.model?.provider == "ollama")
        #expect(status.model?.defaultModel == "qwen2.5-coder:3b")
        #expect(status.model?.baseURL == "http://127.0.0.1:11434/v1")
        #expect(status.update.state == .behind(commits: 3))
        #expect(status.update.source == .cache)
        #expect(status.update.cache?.revision == "abc123")
        #expect(status.localModelServers == [modelStatus])
    }

    @Test
    func statusReportsOpenRouterModelSelectionFromHermesConfig() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try sandbox.writeExecutable(at: bin.appendingPathComponent("hermes"))

        let hermesHome = sandbox.home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try sandbox.write(
            """
            model:
              api_mode: chat_completions
              base_url: https://openrouter.ai/api/v1
              default: z-ai/glm-4.5-air:free
              provider: custom
            providers:
              ollama-launch:
                default_model: qwen2.5-coder:3b
            """,
            to: hermesHome.appendingPathComponent("config.yaml")
        )

        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(stdout: "Hermes Agent v1.0.0", stderr: "", exitCode: 0))
        ])
        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": bin.path, "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )

        let status = await service.status(includeLocalModelServers: false)

        #expect(status.model?.provider == "custom")
        #expect(status.model?.defaultModel == "z-ai/glm-4.5-air:free")
        #expect(status.model?.baseURL == "https://openrouter.ai/api/v1")
    }

    @Test
    func statusReportsLocalOllamaModelSelectionFromHermesConfig() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try sandbox.writeExecutable(at: bin.appendingPathComponent("hermes"))

        let hermesHome = sandbox.home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try sandbox.write(
            """
            model:
              api_mode: chat_completions
              base_url: http://127.0.0.1:11434/v1
              default: llama3.2:1b
              provider: ollama-launch
            fallback_model:
              provider: ollama-launch
              model: llama3.2:3b
            providers:
              ollama-launch:
                default_model: llama3.2:3b
            auxiliary:
              title_generation:
                provider: none
            """,
            to: hermesHome.appendingPathComponent("config.yaml")
        )

        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(stdout: "Hermes Agent v1.0.0", stderr: "", exitCode: 0))
        ])
        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": bin.path, "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )

        let status = await service.status(includeLocalModelServers: false)

        #expect(status.model?.provider == "ollama-launch")
        #expect(status.model?.defaultModel == "llama3.2:1b")
        #expect(status.model?.baseURL == "http://127.0.0.1:11434/v1")
    }

    @Test
    func environmentHermesHomeOverridesDefaultAndExpandsTilde() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let service = HermesRuntimeService(
            processRunner: FakeHermesRuntimeProcessRunner(),
            environment: [
                "PATH": "",
                "HOME": sandbox.home.path,
                "HERMES_HOME": "~/profiles/researcher"
            ],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )

        let status = await service.status(includeLocalModelServers: false)

        #expect(status.home.path == sandbox.home.appendingPathComponent("profiles/researcher").path)
        #expect(status.home.source == .environment)
        #expect(status.update.state == .notInstalled)
    }

    @Test
    func checkForUpdatesTreatsExitOneAsBehindSignal() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try sandbox.writeExecutable(at: bin.appendingPathComponent("hermes"))

        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(stdout: "Update available", stderr: "", exitCode: 1))
        ])
        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": bin.path, "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )

        let check = try await service.checkForUpdates()

        #expect(check.availability.state == .behind(commits: nil))
        #expect(check.availability.source == .freshCheck)
        #expect(check.command?.exitCode == 1)
        #expect(runner.capturedRequests().first?.arguments == ["update", "--check"])
    }

    @Test
    func updateRunsBackupVariantAgainstDetectedExecutable() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let bin = sandbox.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hermes = try sandbox.writeExecutable(at: bin.appendingPathComponent("hermes"))

        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(stdout: "updated", stderr: "", exitCode: 0))
        ])
        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": bin.path, "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )

        let result = try await service.update()

        #expect(result.succeeded)
        let request = try #require(runner.capturedRequests().first)
        #expect(request.executableURL.path == hermes.standardizedFileURL.path)
        #expect(request.arguments == ["update", "--backup"])
        #expect(request.timeoutSeconds == 270)
    }

    @Test
    func installUsesOfficialInstallerPlanWithoutRunningItInTest() async throws {
        let sandbox = try HermesRuntimeTestSandbox()
        defer { sandbox.remove() }

        let runner = FakeHermesRuntimeProcessRunner(results: [
            .success(HermesRuntimeProcessResult(stdout: "installed", stderr: "", exitCode: 0))
        ])
        let service = HermesRuntimeService(
            processRunner: runner,
            environment: ["PATH": "/usr/bin", "HOME": sandbox.home.path],
            homeDirectory: sandbox.home,
            candidateExecutablePaths: [],
            localModelServers: [],
            localModelProbe: FakeHermesLocalModelProbe()
        )
        let plan = HermesRuntimeInstallPlan.officialInstallScript(
            installScriptURL: "https://example.test/install.sh",
            timeoutSeconds: 12
        )

        let result = try await service.install(using: plan)

        #expect(result.succeeded)
        let request = try #require(runner.capturedRequests().first)
        #expect(request.executableURL.path == "/bin/bash")
        #expect(request.arguments == ["-lc", "curl -fsSL \"$INSTALL_URL\" | bash"])
        #expect(request.environment?["INSTALL_URL"] == "https://example.test/install.sh")
        #expect(request.environment?["HERMES_HOME"] == sandbox.home.appendingPathComponent(".hermes").path)
        #expect(request.workingDirectoryURL == sandbox.home)
        #expect(request.timeoutSeconds == 12)
    }
}

private final class FakeHermesRuntimeProcessRunner: HermesRuntimeProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<HermesRuntimeProcessResult, Error>]
    private var requests: [HermesRuntimeProcessRequest] = []

    init(results: [Result<HermesRuntimeProcessResult, Error>] = []) {
        self.results = results
    }

    func run(_ request: HermesRuntimeProcessRequest) async throws -> HermesRuntimeProcessResult {
        let next = recordAndPopNext(request)

        switch next {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .none:
            return HermesRuntimeProcessResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private func recordAndPopNext(
        _ request: HermesRuntimeProcessRequest
    ) -> Result<HermesRuntimeProcessResult, Error>? {
        lock.lock()
        requests.append(request)
        let next = results.isEmpty ? nil : results.removeFirst()
        lock.unlock()
        return next
    }

    func capturedRequests() -> [HermesRuntimeProcessRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private struct FakeHermesLocalModelProbe: HermesLocalModelServerProbing {
    var statuses: [String: HermesLocalModelServerStatus] = [:]

    func probe(_ server: HermesLocalModelServer) async -> HermesLocalModelServerStatus {
        statuses[server.name] ?? HermesLocalModelServerStatus(
            server: server,
            availability: .unavailable,
            statusCode: nil,
            message: "not running"
        )
    }
}

private struct HermesRuntimeTestSandbox {
    let root: URL
    let home: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("os1-hermes-runtime-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func writeExecutable(at url: URL) throws -> URL {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
