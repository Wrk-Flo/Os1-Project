import Foundation

struct HermesRuntimeExecutable: Equatable, Sendable {
    let path: String
    let source: HermesRuntimeExecutableSource
}

enum HermesRuntimeExecutableSource: String, Equatable, Sendable {
    case path
    case fallback
}

struct HermesRuntimeVersion: Equatable, Sendable {
    let label: String?
    let exitCode: Int32
    let stderr: String

    var isAvailable: Bool {
        exitCode == 0 && label != nil
    }
}

struct HermesRuntimeDetection: Equatable, Sendable {
    let executable: HermesRuntimeExecutable?
    let version: HermesRuntimeVersion?
    let home: HermesRuntimeHome

    var isAvailable: Bool {
        executable != nil && (version?.isAvailable ?? false)
    }
}

struct HermesRuntimeHome: Equatable, Sendable {
    let path: String
    let source: HermesRuntimeHomeSource
    let exists: Bool
}

enum HermesRuntimeHomeSource: String, Equatable, Sendable {
    case environment
    case `default`
}

enum HermesRuntimeConfigFileKind: String, CaseIterable, Equatable, Sendable {
    case configYAML
    case env
    case authJSON
    case updateCheck
    case sessionsDirectory
    case logsDirectory
    case profilesDirectory

    var relativePath: String {
        switch self {
        case .configYAML:
            return "config.yaml"
        case .env:
            return ".env"
        case .authJSON:
            return "auth.json"
        case .updateCheck:
            return ".update_check"
        case .sessionsDirectory:
            return "sessions"
        case .logsDirectory:
            return "logs"
        case .profilesDirectory:
            return "profiles"
        }
    }
}

struct HermesRuntimeConfigFileStatus: Equatable, Sendable {
    let kind: HermesRuntimeConfigFileKind
    let path: String
    let exists: Bool
    let isDirectory: Bool
    let isReadable: Bool
    let sizeBytes: Int?
    let modifiedAt: Date?
}

struct HermesRuntimeConfigStatus: Equatable, Sendable {
    let files: [HermesRuntimeConfigFileStatus]

    func file(_ kind: HermesRuntimeConfigFileKind) -> HermesRuntimeConfigFileStatus? {
        files.first { $0.kind == kind }
    }
}

struct HermesRuntimeModelConfig: Equatable, Sendable {
    let provider: String?
    let defaultModel: String?
    let baseURL: String?
    let sourcePath: String
}

struct HermesRuntimeUpdateCache: Equatable, Sendable {
    let path: String
    let behind: Int?
    let revision: String?
    let checkedAt: Date?

    func isFresh(referenceDate: Date = Date(), ttlSeconds: TimeInterval = 6 * 3600) -> Bool {
        guard let checkedAt else { return false }
        return referenceDate.timeIntervalSince(checkedAt) < ttlSeconds
    }
}

struct HermesRuntimeUpdateStatus: Equatable, Sendable {
    let state: HermesRuntimeUpdateState
    let source: HermesRuntimeUpdateSource
    let cache: HermesRuntimeUpdateCache?
    let message: String?
}

enum HermesRuntimeUpdateState: Equatable, Sendable {
    case notInstalled
    case upToDate
    case behind(commits: Int?)
    case unknown
}

enum HermesRuntimeUpdateSource: String, Equatable, Sendable {
    case cache
    case freshCheck
    case unavailable
    case unknown
}

struct HermesLocalModelServer: Equatable, Sendable {
    let name: String
    let baseURL: URL
    let modelsPath: String

    static let defaultServers: [HermesLocalModelServer] = [
        HermesLocalModelServer(
            name: "Ollama",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            modelsPath: "models"
        ),
        HermesLocalModelServer(
            name: "llama.cpp",
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            modelsPath: "models"
        ),
        HermesLocalModelServer(
            name: "LM Studio",
            baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
            modelsPath: "models"
        )
    ]
}

struct HermesLocalModelServerStatus: Equatable, Sendable {
    let server: HermesLocalModelServer
    let availability: HermesLocalModelServerAvailability
    let statusCode: Int?
    let message: String?
}

enum HermesLocalModelServerAvailability: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

struct HermesRuntimeStatus: Equatable, Sendable {
    let executable: HermesRuntimeExecutable?
    let version: HermesRuntimeVersion?
    let home: HermesRuntimeHome
    let config: HermesRuntimeConfigStatus
    let model: HermesRuntimeModelConfig?
    let update: HermesRuntimeUpdateStatus
    let localModelServers: [HermesLocalModelServerStatus]

    var isAvailable: Bool {
        executable != nil && (version?.isAvailable ?? false)
    }
}

struct HermesRuntimeCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdoutTail: String
    let stderrTail: String

    var succeeded: Bool {
        exitCode == 0
    }
}

struct HermesRuntimeUpdateCheck: Equatable, Sendable {
    let availability: HermesRuntimeUpdateStatus
    let command: HermesRuntimeCommandResult?
}

struct HermesRuntimeInstallPlan: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeoutSeconds: TimeInterval?

    static func officialInstallScript(
        installScriptURL: String = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh",
        timeoutSeconds: TimeInterval = 300
    ) -> HermesRuntimeInstallPlan {
        HermesRuntimeInstallPlan(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-lc", "curl -fsSL \"$INSTALL_URL\" | bash"],
            environment: ["INSTALL_URL": installScriptURL],
            timeoutSeconds: timeoutSeconds
        )
    }
}
