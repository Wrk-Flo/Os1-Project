import Foundation

enum HermesRuntimeServiceError: LocalizedError, Equatable {
    case executableNotFound

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Hermes CLI was not found on this Mac."
        }
    }
}

protocol HermesLocalModelServerProbing: Sendable {
    func probe(_ server: HermesLocalModelServer) async -> HermesLocalModelServerStatus
}

struct HermesHTTPModelServerProbe: HermesLocalModelServerProbing {
    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func probe(_ server: HermesLocalModelServer) async -> HermesLocalModelServerStatus {
        let url = server.baseURL.appendingPathComponent(server.modelsPath)
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return HermesLocalModelServerStatus(
                    server: server,
                    availability: .unknown,
                    statusCode: nil,
                    message: "Non-HTTP response."
                )
            }

            return HermesLocalModelServerStatus(
                server: server,
                availability: (200..<300).contains(http.statusCode) ? .available : .unknown,
                statusCode: http.statusCode,
                message: (200..<300).contains(http.statusCode) ? nil : "HTTP \(http.statusCode)"
            )
        } catch {
            return HermesLocalModelServerStatus(
                server: server,
                availability: .unavailable,
                statusCode: nil,
                message: error.localizedDescription
            )
        }
    }
}

final class HermesRuntimeService: @unchecked Sendable {
    private let processRunner: any HermesRuntimeProcessRunning
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let candidateExecutablePaths: [URL]
    private let localModelServers: [HermesLocalModelServer]
    private let localModelProbe: any HermesLocalModelServerProbing

    init(
        processRunner: any HermesRuntimeProcessRunning = HermesRuntimeProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        candidateExecutablePaths: [URL]? = nil,
        localModelServers: [HermesLocalModelServer] = HermesLocalModelServer.defaultServers,
        localModelProbe: any HermesLocalModelServerProbing = HermesHTTPModelServerProbe()
    ) {
        self.processRunner = processRunner
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.candidateExecutablePaths = candidateExecutablePaths
            ?? Self.defaultExecutableCandidates(homeDirectory: homeDirectory)
        self.localModelServers = localModelServers
        self.localModelProbe = localModelProbe
    }

    func detect() async -> HermesRuntimeDetection {
        let executable = detectExecutable()
        let version = await readVersion(executable: executable)
        return HermesRuntimeDetection(
            executable: executable,
            version: version,
            home: resolveHermesHome()
        )
    }

    func status(includeLocalModelServers: Bool = true) async -> HermesRuntimeStatus {
        let executable = detectExecutable()
        let version = await readVersion(executable: executable)
        let home = resolveHermesHome()
        let config = inspectConfigFiles(in: home)
        let model = inspectModelConfig(in: home)
        let update = inspectCachedUpdateStatus(executable: executable, home: home)
        let modelServers = includeLocalModelServers ? await probeLocalModelServers() : []

        return HermesRuntimeStatus(
            executable: executable,
            version: version,
            home: home,
            config: config,
            model: model,
            update: update,
            localModelServers: modelServers
        )
    }

    func checkForUpdates() async throws -> HermesRuntimeUpdateCheck {
        guard let executable = detectExecutable() else {
            return HermesRuntimeUpdateCheck(
                availability: HermesRuntimeUpdateStatus(
                    state: .notInstalled,
                    source: .unavailable,
                    cache: nil,
                    message: "Hermes CLI is not installed."
                ),
                command: nil
            )
        }

        let result = try await processRunner.run(
            makeHermesRequest(
                executable: executable,
                arguments: ["update", "--check"],
                timeoutSeconds: 30
            )
        )
        let command = makeCommandResult(result)
        let message = command.stderrTail.isEmpty ? command.stdoutTail : command.stderrTail

        let state: HermesRuntimeUpdateState
        switch result.exitCode {
        case 0:
            state = .upToDate
        case 1:
            state = .behind(commits: nil)
        default:
            state = .unknown
        }

        return HermesRuntimeUpdateCheck(
            availability: HermesRuntimeUpdateStatus(
                state: state,
                source: .freshCheck,
                cache: nil,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            command: command
        )
    }

    func update(backup: Bool = true) async throws -> HermesRuntimeCommandResult {
        guard let executable = detectExecutable() else {
            throw HermesRuntimeServiceError.executableNotFound
        }

        var arguments = ["update"]
        if backup {
            arguments.append("--backup")
        }

        let result = try await processRunner.run(
            makeHermesRequest(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 270
            )
        )
        return makeCommandResult(result)
    }

    func install(
        using plan: HermesRuntimeInstallPlan = .officialInstallScript()
    ) async throws -> HermesRuntimeCommandResult {
        var env = runtimeEnvironment()
        for (key, value) in plan.environment {
            env[key] = value
        }

        let result = try await processRunner.run(
            HermesRuntimeProcessRequest(
                executableURL: plan.executableURL,
                arguments: plan.arguments,
                environment: env,
                workingDirectoryURL: homeDirectory,
                timeoutSeconds: plan.timeoutSeconds
            )
        )
        return makeCommandResult(result)
    }
}

private extension HermesRuntimeService {
    static func defaultExecutableCandidates(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin/hermes"),
            homeDirectory.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes"),
            homeDirectory.appendingPathComponent(".cargo/bin/hermes"),
            URL(fileURLWithPath: "/opt/homebrew/bin/hermes"),
            URL(fileURLWithPath: "/usr/local/bin/hermes"),
            URL(fileURLWithPath: "/usr/bin/hermes")
        ]
    }

    func detectExecutable() -> HermesRuntimeExecutable? {
        var seen = Set<String>()

        for candidate in pathExecutableCandidates() {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return HermesRuntimeExecutable(path: path, source: .path)
            }
        }

        for candidate in candidateExecutablePaths {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return HermesRuntimeExecutable(path: path, source: .fallback)
            }
        }

        return nil
    }

    func pathExecutableCandidates() -> [URL] {
        let entries = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []

        return entries.map { entry in
            URL(fileURLWithPath: entry).appendingPathComponent("hermes")
        }
    }

    func readVersion(executable: HermesRuntimeExecutable?) async -> HermesRuntimeVersion? {
        guard let executable else { return nil }

        do {
            let result = try await processRunner.run(
                makeHermesRequest(
                    executable: executable,
                    arguments: ["version"],
                    timeoutSeconds: 15
                )
            )
            return HermesRuntimeVersion(
                label: firstNonEmptyLine(result.stdout),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        } catch {
            return HermesRuntimeVersion(
                label: nil,
                exitCode: -1,
                stderr: error.localizedDescription
            )
        }
    }

    func resolveHermesHome() -> HermesRuntimeHome {
        let envValue = environment["HERMES_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let source: HermesRuntimeHomeSource = envValue == nil ? .default : .environment
        let url = envValue.map(expandLocalPath(_:))
            ?? homeDirectory.appendingPathComponent(".hermes")
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue

        return HermesRuntimeHome(
            path: url.standardizedFileURL.path,
            source: source,
            exists: exists
        )
    }

    func expandLocalPath(_ value: String) -> URL {
        if value == "~" {
            return homeDirectory
        }
        if value.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(value.dropFirst(2)))
        }
        if value.hasPrefix("$HOME/") {
            return homeDirectory.appendingPathComponent(String(value.dropFirst(6)))
        }
        if value.hasPrefix("${HOME}/") {
            return homeDirectory.appendingPathComponent(String(value.dropFirst(8)))
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return homeDirectory.appendingPathComponent(value)
    }

    func inspectConfigFiles(in home: HermesRuntimeHome) -> HermesRuntimeConfigStatus {
        let homeURL = URL(fileURLWithPath: home.path)
        let files = HermesRuntimeConfigFileKind.allCases.map { kind in
            inspectConfigFile(kind: kind, url: homeURL.appendingPathComponent(kind.relativePath))
        }
        return HermesRuntimeConfigStatus(files: files)
    }

    func inspectModelConfig(in home: HermesRuntimeHome) -> HermesRuntimeModelConfig? {
        let url = URL(fileURLWithPath: home.path).appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var inModelSection = false
        var provider: String?
        var defaultModel: String?
        var baseURL: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
            if indentation == 0 {
                inModelSection = trimmed == "model:"
                continue
            }
            guard inModelSection else {
                continue
            }

            if let separator = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(trimmed[trimmed.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                let value = rawValue
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .nilIfEmpty

                switch key {
                case "provider":
                    provider = value
                case "default":
                    defaultModel = value
                case "base_url":
                    baseURL = value
                default:
                    break
                }
            }
        }

        guard provider != nil || defaultModel != nil || baseURL != nil else {
            return nil
        }

        return HermesRuntimeModelConfig(
            provider: provider,
            defaultModel: defaultModel,
            baseURL: baseURL,
            sourcePath: url.standardizedFileURL.path
        )
    }

    func inspectConfigFile(
        kind: HermesRuntimeConfigFileKind,
        url: URL
    ) -> HermesRuntimeConfigFileStatus {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes?[.size] as? NSNumber
        let modifiedAt = attributes?[.modificationDate] as? Date

        return HermesRuntimeConfigFileStatus(
            kind: kind,
            path: url.standardizedFileURL.path,
            exists: exists,
            isDirectory: exists && isDirectory.boolValue,
            isReadable: exists && fileManager.isReadableFile(atPath: url.path),
            sizeBytes: fileSize?.intValue,
            modifiedAt: modifiedAt
        )
    }

    func inspectCachedUpdateStatus(
        executable: HermesRuntimeExecutable?,
        home: HermesRuntimeHome
    ) -> HermesRuntimeUpdateStatus {
        guard executable != nil else {
            return HermesRuntimeUpdateStatus(
                state: .notInstalled,
                source: .unavailable,
                cache: readUpdateCache(in: home),
                message: "Hermes CLI is not installed."
            )
        }

        guard let cache = readUpdateCache(in: home), let behind = cache.behind else {
            return HermesRuntimeUpdateStatus(
                state: .unknown,
                source: .unknown,
                cache: readUpdateCache(in: home),
                message: nil
            )
        }

        let state: HermesRuntimeUpdateState
        if behind == 0 {
            state = .upToDate
        } else if behind > 0 {
            state = .behind(commits: behind)
        } else {
            state = .behind(commits: nil)
        }

        return HermesRuntimeUpdateStatus(
            state: state,
            source: .cache,
            cache: cache,
            message: nil
        )
    }

    func readUpdateCache(in home: HermesRuntimeHome) -> HermesRuntimeUpdateCache? {
        let url = URL(fileURLWithPath: home.path).appendingPathComponent(".update_check")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let behind = object["behind"] as? Int
        let revision = object["rev"] as? String
        let checkedAt: Date?
        if let timestamp = object["ts"] as? TimeInterval {
            checkedAt = Date(timeIntervalSince1970: timestamp)
        } else {
            checkedAt = nil
        }

        return HermesRuntimeUpdateCache(
            path: url.standardizedFileURL.path,
            behind: behind,
            revision: revision,
            checkedAt: checkedAt
        )
    }

    func probeLocalModelServers() async -> [HermesLocalModelServerStatus] {
        var statuses: [HermesLocalModelServerStatus] = []
        for server in localModelServers {
            statuses.append(await localModelProbe.probe(server))
        }
        return statuses
    }

    func makeHermesRequest(
        executable: HermesRuntimeExecutable,
        arguments: [String],
        timeoutSeconds: TimeInterval?
    ) -> HermesRuntimeProcessRequest {
        HermesRuntimeProcessRequest(
            executableURL: URL(fileURLWithPath: executable.path),
            arguments: arguments,
            environment: runtimeEnvironment(),
            workingDirectoryURL: homeDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    func runtimeEnvironment() -> [String: String] {
        var env = environment
        env["HERMES_HOME"] = resolveHermesHome().path
        env["NO_COLOR"] = env["NO_COLOR"] ?? "1"
        env["TERM"] = env["TERM"] ?? "dumb"
        env["PATH"] = normalizedPath()
        return env
    }

    func normalizedPath() -> String {
        let defaultEntries = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".hermes/hermes-agent/venv/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let existing = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []

        var seen = Set<String>()
        return (defaultEntries + existing)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    func makeCommandResult(_ result: HermesRuntimeProcessResult) -> HermesRuntimeCommandResult {
        HermesRuntimeCommandResult(
            exitCode: result.exitCode,
            stdoutTail: tail(result.stdout),
            stderrTail: tail(result.stderr)
        )
    }

    func firstNonEmptyLine(_ text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func tail(_ text: String, limit: Int = 4000) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
