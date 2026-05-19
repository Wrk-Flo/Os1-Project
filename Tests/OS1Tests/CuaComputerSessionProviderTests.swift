import Foundation
import Testing
@testable import OS1

private struct StubCuaExecutableResolver: CuaExecutableResolving {
    var isMacOS: Bool
    var platformName: String
    var executables: [String: String]

    init(
        isMacOS: Bool = true,
        platformName: String = "macOS",
        executables: [String: String] = [:]
    ) {
        self.isMacOS = isMacOS
        self.platformName = platformName
        self.executables = executables
    }

    func resolveExecutable(_ command: String) -> String? {
        executables[command]
    }
}

private final class RecordingCuaHermesRunner: CuaHermesCommandRunning, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
        var currentDirectoryPath: String
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private let result: CuaHermesCommandResult
    private var calls: [Call] = []

    init(result: CuaHermesCommandResult = CuaHermesCommandResult(exitCode: 0, stdout: "done", stderr: "")) {
        self.result = result
    }

    func runHermes(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) async throws -> CuaHermesCommandResult {
        record(
            Call(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                currentDirectoryPath: currentDirectoryURL.path,
                timeout: timeout
            )
        )
        return result
    }

    private func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var recordedCalls: [Call] {
        lock.lock()
        let value = calls
        lock.unlock()
        return value
    }
}

struct CuaComputerSessionProviderTests {
    @Test
    func configDecodesOlderPayloadWithLocalStartDefaultedOff() throws {
        let data = Data(#"{"isEnabled":true,"defaultMaxMinutes":120}"#.utf8)
        let config = try JSONDecoder().decode(CuaComputerSessionConfig.self, from: data)

        #expect(config.isEnabled)
        #expect(config.defaultMaxMinutes == ComputerSessionRequest.maxAllowedMinutes)
        #expect(config.hermesExecutable == nil)
        #expect(config.cuaDriverExecutable == nil)
        #expect(config.hermesHome == nil)
        #expect(config.allowsLocalHermesStart == false)
    }

    @Test
    func disabledProviderReportsDisabledAndUnavailable() async {
        let provider = CuaComputerSessionProvider()

        #expect(provider.availability == .disabled)
        #expect(provider.isAvailable == false)

        await #expect(throws: CuaComputerSessionProviderError.unavailable(.disabled)) {
            _ = try await provider.start(request: ComputerSessionRequest(task: "Inspect the screen"))
        }
    }

    @Test
    func enabledProviderReportsUnsupportedPlatform() {
        let provider = CuaComputerSessionProvider(
            config: CuaComputerSessionConfig(isEnabled: true),
            executableResolver: StubCuaExecutableResolver(isMacOS: false, platformName: "Linux")
        )

        #expect(provider.availability == .unsupportedPlatform("Linux"))
        #expect(provider.isAvailable == false)
    }

    @Test
    func enabledProviderReportsMissingHermesBeforeCuaDriver() async {
        let provider = CuaComputerSessionProvider(
            config: CuaComputerSessionConfig(isEnabled: true),
            executableResolver: StubCuaExecutableResolver()
        )

        #expect(provider.availability == .missingHermesCLI)
        #expect(provider.isAvailable == false)

        await #expect(throws: CuaComputerSessionProviderError.unavailable(.missingHermesCLI)) {
            _ = try await provider.start(request: ComputerSessionRequest(task: "Read a public page"))
        }
    }

    @Test
    func enabledProviderReportsMissingCuaDriverAfterHermesFound() async {
        let provider = CuaComputerSessionProvider(
            config: CuaComputerSessionConfig(isEnabled: true),
            executableResolver: StubCuaExecutableResolver(executables: [
                "hermes": "/opt/homebrew/bin/hermes"
            ])
        )

        let availability = provider.availability
        #expect(availability == .missingCuaDriver(hermesPath: "/opt/homebrew/bin/hermes"))
        #expect(availability.installHint?.contains("hermes computer-use install") == true)
        #expect(provider.isAvailable == false)

        await #expect(throws: CuaComputerSessionProviderError.unavailable(availability)) {
            _ = try await provider.start(request: ComputerSessionRequest(task: "Read a public page"))
        }
    }

    @Test
    func readyPrerequisitesRemainUnavailableUntilStartAdapterEnabled() async {
        let availability = CuaComputerSessionAvailability.ready(
            hermesPath: "/opt/homebrew/bin/hermes",
            cuaDriverPath: "/opt/homebrew/bin/cua-driver"
        )
        let provider = CuaComputerSessionProvider(
            config: CuaComputerSessionConfig(isEnabled: true),
            executableResolver: StubCuaExecutableResolver(executables: [
                "hermes": "/opt/homebrew/bin/hermes",
                "cua-driver": "/opt/homebrew/bin/cua-driver"
            ])
        )

        #expect(provider.availability == availability)
        #expect(provider.isAvailable == false)

        await #expect(throws: CuaComputerSessionProviderError.startAdapterDisabled(availability)) {
            _ = try await provider.start(request: ComputerSessionRequest(task: "Inspect local desktop"))
        }
    }

    @Test
    func localHermesStartRunsOneShotInvocationWhenExplicitlyEnabled() async throws {
        let runner = RecordingCuaHermesRunner()
        let provider = CuaComputerSessionProvider(
            config: CuaComputerSessionConfig(
                isEnabled: true,
                defaultMaxMinutes: 3,
                hermesExecutable: "custom-hermes",
                cuaDriverExecutable: "custom-cua-driver",
                hermesHome: "~/custom-hermes-home",
                allowsLocalHermesStart: true
            ),
            executableResolver: StubCuaExecutableResolver(executables: [
                "custom-hermes": "/opt/hermes/bin/hermes",
                "custom-cua-driver": "/opt/cua/bin/cua-driver"
            ]),
            commandRunner: runner,
            processEnvironment: ["PATH": "/usr/bin", "NO_COLOR": "0"],
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            sessionIDFactory: { "cua_fixed" }
        )

        let response = try await provider.start(
            request: ComputerSessionRequest(
                task: " Read Example ",
                sessionType: .browser,
                maxMinutes: 9,
                allowedDomains: [" Example.COM "],
                blockedDomains: [" Bad.Example "]
            )
        )
        let call = try #require(runner.recordedCalls.first)
        let prompt = try #require(call.arguments.last)

        #expect(provider.isAvailable)
        #expect(response.sessionId == "cua_fixed")
        #expect(response.provider == .cua)
        #expect(response.status == .completed)
        #expect(response.summary == "done")
        #expect(response.costEstimate?.maxMinutes == 3)
        #expect(response.costEstimate?.providerUnits == "cua-local-minutes")

        #expect(call.executablePath == "/opt/hermes/bin/hermes")
        #expect(Array(call.arguments.dropLast()) == ["chat", "--quiet", "--query"])
        #expect(prompt.contains("Use the Hermes `computer_use` tool"))
        #expect(prompt.contains("Task:\nRead Example"))
        #expect(prompt.contains("- max_minutes: 3"))
        #expect(prompt.contains("- allowed_domains: example.com"))
        #expect(prompt.contains("- blocked_domains: bad.example"))
        #expect(prompt.contains(" Example.COM ") == false)
        #expect(call.environment["HERMES_COMPUTER_USE_BACKEND"] == "cua")
        #expect(call.environment["HERMES_CUA_DRIVER_CMD"] == "/opt/cua/bin/cua-driver")
        #expect(call.environment["HERMES_HOME"] == "/Users/tester/custom-hermes-home")
        #expect(call.environment["NO_COLOR"] == "0")
        #expect(call.environment["TERM"] == "dumb")
        #expect(call.environment["PATH"] == "/opt/hermes/bin:/opt/cua/bin:/usr/bin")
        #expect(call.currentDirectoryPath == "/Users/tester")
        #expect(call.timeout == 180)
    }

    @Test
    func nonzeroHermesResultThrowsActionableFailure() async {
        let provider = CuaComputerSessionProvider(
            config: CuaComputerSessionConfig(
                isEnabled: true,
                allowsLocalHermesStart: true
            ),
            executableResolver: StubCuaExecutableResolver(executables: [
                "hermes": "/opt/homebrew/bin/hermes",
                "cua-driver": "/opt/homebrew/bin/cua-driver"
            ]),
            commandRunner: RecordingCuaHermesRunner(
                result: CuaHermesCommandResult(exitCode: 42, stdout: "stdout details", stderr: "stderr details")
            )
        )

        await #expect(throws: CuaComputerSessionProviderError.hermesCommandFailed(
            exitCode: 42,
            output: "stderr details\n\nstdout details"
        )) {
            _ = try await provider.start(request: ComputerSessionRequest(task: "Inspect local desktop"))
        }
    }

    @Test
    func statusAndStopReportLiveControlNotWired() async {
        let provider = CuaComputerSessionProvider()

        await #expect(throws: CuaComputerSessionProviderError.liveSessionControlUnavailable("cua_fixed")) {
            _ = try await provider.status(sessionId: "cua_fixed")
        }
        await #expect(throws: CuaComputerSessionProviderError.liveSessionControlUnavailable("cua_fixed")) {
            _ = try await provider.stop(sessionId: "cua_fixed")
        }
    }
}
