import Foundation

struct CuaComputerSessionConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var baseURL: URL?
    var defaultMaxMinutes: Int
    var hermesExecutable: String?
    var cuaDriverExecutable: String?
    var hermesHome: String?
    var allowsLocalHermesStart: Bool

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case baseURL
        case defaultMaxMinutes
        case hermesExecutable
        case cuaDriverExecutable
        case hermesHome
        case allowsLocalHermesStart
    }

    init(
        isEnabled: Bool = false,
        baseURL: URL? = nil,
        defaultMaxMinutes: Int = ComputerSessionRequest.defaultMaxMinutes,
        hermesExecutable: String? = nil,
        cuaDriverExecutable: String? = nil,
        hermesHome: String? = nil,
        allowsLocalHermesStart: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.defaultMaxMinutes = ComputerSessionRequest.clampedMinutes(defaultMaxMinutes)
        self.hermesExecutable = hermesExecutable
        self.cuaDriverExecutable = cuaDriverExecutable
        self.hermesHome = hermesHome
        self.allowsLocalHermesStart = allowsLocalHermesStart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            baseURL: try container.decodeIfPresent(URL.self, forKey: .baseURL),
            defaultMaxMinutes: try container.decodeIfPresent(Int.self, forKey: .defaultMaxMinutes) ?? ComputerSessionRequest.defaultMaxMinutes,
            hermesExecutable: try container.decodeIfPresent(String.self, forKey: .hermesExecutable),
            cuaDriverExecutable: try container.decodeIfPresent(String.self, forKey: .cuaDriverExecutable),
            hermesHome: try container.decodeIfPresent(String.self, forKey: .hermesHome),
            allowsLocalHermesStart: try container.decodeIfPresent(Bool.self, forKey: .allowsLocalHermesStart) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encode(defaultMaxMinutes, forKey: .defaultMaxMinutes)
        try container.encodeIfPresent(hermesExecutable, forKey: .hermesExecutable)
        try container.encodeIfPresent(cuaDriverExecutable, forKey: .cuaDriverExecutable)
        try container.encodeIfPresent(hermesHome, forKey: .hermesHome)
        try container.encode(allowsLocalHermesStart, forKey: .allowsLocalHermesStart)
    }
}

struct CuaComputerSessionAvailability: Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case disabled
        case unsupportedPlatform = "unsupported_platform"
        case missingHermesCLI = "missing_hermes_cli"
        case missingCuaDriver = "missing_cua_driver"
        case ready
    }

    var state: State
    var message: String
    var installHint: String?
    var hermesPath: String?
    var cuaDriverPath: String?

    var isReady: Bool {
        state == .ready
    }

    static var disabled: Self {
        Self(
            state: .disabled,
            message: "Cua computer sessions are disabled in OS1 configuration.",
            installHint: "Enable Cua computer sessions after Hermes Agent and cua-driver are installed."
        )
    }

    static func unsupportedPlatform(_ platformName: String) -> Self {
        Self(
            state: .unsupportedPlatform,
            message: "Cua computer_use requires macOS because Hermes uses cua-driver for local desktop control. Current platform: \(platformName).",
            installHint: "Use a macOS host for Cua computer_use sessions."
        )
    }

    static var missingHermesCLI: Self {
        Self(
            state: .missingHermesCLI,
            message: "Hermes CLI was not found on this Mac.",
            installHint: "Install Hermes Agent and ensure `hermes` is on PATH. OS1 also checks ~/.local/bin, ~/.hermes/hermes-agent/venv/bin, ~/.cargo/bin, /opt/homebrew/bin, and /usr/local/bin."
        )
    }

    static func missingCuaDriver(hermesPath: String) -> Self {
        Self(
            state: .missingCuaDriver,
            message: "Hermes CLI is installed, but cua-driver was not found.",
            installHint: "Run `hermes computer-use install` or `hermes tools` and enable Computer Use so `cua-driver mcp` is available.",
            hermesPath: hermesPath
        )
    }

    static func ready(hermesPath: String, cuaDriverPath: String) -> Self {
        Self(
            state: .ready,
            message: "Hermes CLI and cua-driver are installed for local computer_use.",
            hermesPath: hermesPath,
            cuaDriverPath: cuaDriverPath
        )
    }
}

enum CuaComputerSessionProviderError: LocalizedError, Equatable {
    case unavailable(CuaComputerSessionAvailability)
    case startAdapterDisabled(CuaComputerSessionAvailability)
    case hermesCommandFailed(exitCode: Int32, output: String)
    case hermesCommandTimedOut(seconds: Int)
    case hermesLaunchFailed(String)
    case liveSessionControlUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            [availability.message, availability.installHint]
                .compactMap { $0 }
                .compactMap(\.trimmedNonEmpty)
                .joined(separator: " ")
        case .startAdapterDisabled:
            "Cua local prerequisites are ready, but OS1's Hermes computer_use start adapter is still gated. Enable allowsLocalHermesStart only for the experimental one-shot Hermes CLI path."
        case .hermesCommandFailed(let exitCode, let output):
            "Hermes computer_use exited with code \(exitCode)." + (output.isEmpty ? "" : "\n\n\(output)")
        case .hermesCommandTimedOut(let seconds):
            "Hermes computer_use did not finish within \(seconds) seconds. The local process was stopped."
        case .hermesLaunchFailed(let message):
            "Unable to launch Hermes computer_use: \(message)"
        case .liveSessionControlUnavailable(let sessionId):
            "Cua session \(sessionId) was started through a one-shot Hermes computer_use turn. Persistent status and stop controls are not wired yet."
        }
    }
}

protocol CuaExecutableResolving: Sendable {
    var isMacOS: Bool { get }
    var platformName: String { get }

    func resolveExecutable(_ command: String) -> String?
}

struct CuaLocalExecutableResolver: CuaExecutableResolving {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var isMacOS: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(Linux)
        "Linux"
        #elseif os(Windows)
        "Windows"
        #else
        "unsupported"
        #endif
    }

    func resolveExecutable(_ command: String) -> String? {
        guard let command = command.trimmedNonEmpty else {
            return nil
        }

        if command.contains("/") {
            return executablePath(at: command)
        }

        for directory in executableSearchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if let executable = executablePath(at: candidate) {
                return executable
            }
        }

        return nil
    }

    private var executableSearchDirectories: [String] {
        let fallbackDirectories = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".hermes/hermes-agent/venv/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return (fallbackDirectories + pathDirectories).uniquePreservingOrder()
    }

    private func executablePath(at path: String) -> String? {
        let expanded = expandedPath(path)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: expanded) else {
            return nil
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func expandedPath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return path
        }

        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return homeDirectory.appendingPathComponent(suffix).path
    }
}

struct CuaHermesCommandResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol CuaHermesCommandRunning: Sendable {
    func runHermes(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) async throws -> CuaHermesCommandResult
}

struct CuaLocalHermesCommandRunner: CuaHermesCommandRunning {
    func runHermes(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) async throws -> CuaHermesCommandResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                timeout: timeout
            )
        }.value
    }

    private static func runBlocking(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) throws -> CuaHermesCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = CuaPipeBuffer()
        let stderrBuffer = CuaPipeBuffer()
        let termination = DispatchSemaphore(value: 0)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CuaComputerSessionProviderError.hermesLaunchFailed(error.localizedDescription)
        }

        let milliseconds = max(1, Int(timeout * 1000))
        if termination.wait(timeout: .now() + .milliseconds(milliseconds)) == .timedOut {
            process.terminate()
            _ = termination.wait(timeout: .now() + .seconds(5))
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CuaComputerSessionProviderError.hermesCommandTimedOut(seconds: Int(timeout.rounded()))
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.availableData)
        stderrBuffer.append(stderrPipe.fileHandleForReading.availableData)

        return CuaHermesCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.stringValue,
            stderr: stderrBuffer.stringValue
        )
    }
}

private final class CuaPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int = 64 * 1024) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }

        lock.lock()
        data.append(chunk)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let value = data
        lock.unlock()
        return String(data: value, encoding: .utf8) ?? ""
    }
}

struct CuaHermesComputerUseInvocation: Equatable, Sendable {
    var request: ComputerSessionRequest
    var maxMinutes: Int

    var arguments: [String] {
        [
            "chat",
            "--quiet",
            "--query",
            prompt
        ]
    }

    var prompt: String {
        var lines = [
            "You are handling an OS1 Cua computer session through Hermes Agent.",
            "Use the Hermes `computer_use` tool when desktop interaction is needed.",
            "Complete one bounded turn and summarize the result. Do not claim persistent OS1 live control.",
            "",
            "Task:",
            request.task,
            "",
            "Session constraints:",
            "- session_type: \(request.sessionType.rawValue)",
            "- risk_level: \(request.riskLevel.rawValue)",
            "- max_minutes: \(maxMinutes)",
            "- requires_approval: \(request.requiresApproval)",
            "- credential_policy: \(request.credentialPolicy.rawValue)",
            "- record_session: \(request.recordSession)",
            "- output_artifacts: \(request.outputContract.artifacts)",
            "- output_summary: \(request.outputContract.summary)",
            "- output_screenshots: \(request.outputContract.screenshots)",
            "- output_action_log: \(request.outputContract.actionLog)"
        ]

        if !request.allowedDomains.isEmpty {
            lines.append("- allowed_domains: \(request.allowedDomains.joined(separator: ", "))")
        }
        if !request.blockedDomains.isEmpty {
            lines.append("- blocked_domains: \(request.blockedDomains.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}

final class CuaComputerSessionProvider: ComputerSessionProviderClient, @unchecked Sendable {
    let provider: ComputerSessionProvider = .cua
    private let config: CuaComputerSessionConfig
    private let credentialStore: CuaCredentialStore?
    private let executableResolver: any CuaExecutableResolving
    private let commandRunner: any CuaHermesCommandRunning
    private let processEnvironment: [String: String]
    private let homeDirectory: URL
    private let sessionIDFactory: @Sendable () -> String

    init(
        config: CuaComputerSessionConfig = CuaComputerSessionConfig(),
        credentialStore: CuaCredentialStore? = nil,
        executableResolver: any CuaExecutableResolving = CuaLocalExecutableResolver(),
        commandRunner: any CuaHermesCommandRunning = CuaLocalHermesCommandRunner(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionIDFactory: @escaping @Sendable () -> String = {
            "cua_\(UUID().uuidString.lowercased())"
        }
    ) {
        self.config = config
        self.credentialStore = credentialStore
        self.executableResolver = executableResolver
        self.commandRunner = commandRunner
        self.processEnvironment = processEnvironment
        self.homeDirectory = homeDirectory
        self.sessionIDFactory = sessionIDFactory
    }

    var availability: CuaComputerSessionAvailability {
        localAvailability()
    }

    var isAvailable: Bool {
        availability.isReady && config.allowsLocalHermesStart
    }

    func start(request: ComputerSessionRequest) async throws -> ComputerSessionResponse {
        let currentAvailability = availability
        guard currentAvailability.isReady else {
            throw CuaComputerSessionProviderError.unavailable(currentAvailability)
        }
        guard config.allowsLocalHermesStart else {
            throw CuaComputerSessionProviderError.startAdapterDisabled(currentAvailability)
        }
        guard let hermesPath = currentAvailability.hermesPath,
              let cuaDriverPath = currentAvailability.cuaDriverPath else {
            throw CuaComputerSessionProviderError.unavailable(currentAvailability)
        }

        let normalized = request.normalized
        let maxMinutes = min(normalized.maxMinutes, config.defaultMaxMinutes)
        let invocation = CuaHermesComputerUseInvocation(
            request: normalized,
            maxMinutes: maxMinutes
        )
        let result = try await commandRunner.runHermes(
            executablePath: hermesPath,
            arguments: invocation.arguments,
            environment: hermesEnvironment(hermesPath: hermesPath, cuaDriverPath: cuaDriverPath),
            currentDirectoryURL: homeDirectory,
            timeout: TimeInterval(maxMinutes * 60)
        )

        guard result.exitCode == 0 else {
            throw CuaComputerSessionProviderError.hermesCommandFailed(
                exitCode: result.exitCode,
                output: compactOutput(stderr: result.stderr, stdout: result.stdout)
            )
        }

        return ComputerSessionResponse(
            sessionId: sessionIDFactory(),
            provider: .cua,
            status: .completed,
            riskLevel: normalized.riskLevel,
            summary: compactOutput(stdout: result.stdout, stderr: result.stderr),
            costEstimate: ComputerSessionCostEstimate(
                maxMinutes: maxMinutes,
                providerUnits: "cua-local-minutes"
            )
        )
    }

    func status(sessionId: String) async throws -> ComputerSessionResponse {
        throw CuaComputerSessionProviderError.liveSessionControlUnavailable(sessionId)
    }

    func stop(sessionId: String) async throws -> ComputerSessionResponse {
        throw CuaComputerSessionProviderError.liveSessionControlUnavailable(sessionId)
    }

    private func localAvailability() -> CuaComputerSessionAvailability {
        guard config.isEnabled else {
            return .disabled
        }
        guard executableResolver.isMacOS else {
            return .unsupportedPlatform(executableResolver.platformName)
        }

        let hermesCommand = config.hermesExecutable?.trimmedNonEmpty ?? "hermes"
        guard let hermesPath = executableResolver.resolveExecutable(hermesCommand) else {
            return .missingHermesCLI
        }

        let cuaDriverCommand = config.cuaDriverExecutable?.trimmedNonEmpty ?? "cua-driver"
        guard let cuaDriverPath = executableResolver.resolveExecutable(cuaDriverCommand) else {
            return .missingCuaDriver(hermesPath: hermesPath)
        }

        return .ready(hermesPath: hermesPath, cuaDriverPath: cuaDriverPath)
    }

    private func hermesEnvironment(hermesPath: String, cuaDriverPath: String) -> [String: String] {
        var environment = processEnvironment
        environment["HERMES_COMPUTER_USE_BACKEND"] = "cua"
        environment["HERMES_CUA_DRIVER_CMD"] = cuaDriverPath
        environment["NO_COLOR"] = environment["NO_COLOR"]?.trimmedNonEmpty ?? "1"
        environment["TERM"] = "dumb"

        if let hermesHome = config.hermesHome?.trimmedNonEmpty {
            environment["HERMES_HOME"] = expandedHomePath(hermesHome)
        }

        let hermesDirectory = URL(fileURLWithPath: hermesPath).deletingLastPathComponent().path
        let cuaDriverDirectory = URL(fileURLWithPath: cuaDriverPath).deletingLastPathComponent().path
        environment["PATH"] = ([hermesDirectory, cuaDriverDirectory] + (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init))
            .uniquePreservingOrder()
            .joined(separator: ":")

        return environment
    }

    private func expandedHomePath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return path
        }

        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return homeDirectory.appendingPathComponent(suffix).path
    }

    private func compactOutput(stdout: String, stderr: String) -> String? {
        compactOutput(values: [stdout, stderr]).trimmedNonEmpty
    }

    private func compactOutput(stderr: String, stdout: String) -> String {
        compactOutput(values: [stderr, stdout])
    }

    private func compactOutput(values: [String], limit: Int = 12_000) -> String {
        let merged = values
            .compactMap { $0.trimmedNonEmpty }
            .joined(separator: "\n\n")
        guard merged.count > limit else {
            return merged
        }

        return String(merged.suffix(limit))
    }
}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for value in self {
            guard !value.isEmpty, !seen.contains(value) else {
                continue
            }
            seen.insert(value)
            values.append(value)
        }
        return values
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
