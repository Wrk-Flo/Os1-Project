import Foundation

enum HermesRuntimeHealthLevel: String, Codable, CaseIterable, Sendable {
    case ready
    case degraded
    case unavailable
    case unknown

    var displayName: String {
        switch self {
        case .ready:
            return "Ready"
        case .degraded:
            return "Needs attention"
        case .unavailable:
            return "Missing"
        case .unknown:
            return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .degraded:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "xmark.circle.fill"
        case .unknown:
            return "circle.dotted"
        }
    }
}

struct HermesRuntimeCLIStatus: Codable, Equatable, Sendable {
    var level: HermesRuntimeHealthLevel
    var version: String?
    var executablePath: String?
    var detail: String?

    init(
        level: HermesRuntimeHealthLevel,
        version: String? = nil,
        executablePath: String? = nil,
        detail: String? = nil
    ) {
        self.level = level
        self.version = version?.nilIfBlank
        self.executablePath = executablePath?.nilIfBlank
        self.detail = detail?.nilIfBlank
    }

    static let unknown = HermesRuntimeCLIStatus(level: .unknown)

    static func available(
        version: String? = nil,
        executablePath: String? = nil,
        detail: String? = nil
    ) -> HermesRuntimeCLIStatus {
        HermesRuntimeCLIStatus(
            level: .ready,
            version: version,
            executablePath: executablePath,
            detail: detail
        )
    }

    static func missing(detail: String? = nil) -> HermesRuntimeCLIStatus {
        HermesRuntimeCLIStatus(level: .unavailable, detail: detail)
    }

    var displayValue: String {
        switch level {
        case .ready:
            return version ?? "Available"
        case .degraded, .unavailable, .unknown:
            return level.displayName
        }
    }

    var supportingDetail: String? {
        executablePath ?? detail
    }
}

struct HermesRuntimeHomeStatus: Codable, Equatable, Sendable {
    var level: HermesRuntimeHealthLevel
    var path: String?
    var source: String?
    var detail: String?

    init(
        level: HermesRuntimeHealthLevel,
        path: String? = nil,
        source: String? = nil,
        detail: String? = nil
    ) {
        self.level = level
        self.path = path?.nilIfBlank
        self.source = source?.nilIfBlank
        self.detail = detail?.nilIfBlank
    }

    static let unknown = HermesRuntimeHomeStatus(level: .unknown)

    static func available(
        path: String,
        source: String? = nil,
        detail: String? = nil
    ) -> HermesRuntimeHomeStatus {
        HermesRuntimeHomeStatus(
            level: .ready,
            path: path,
            source: source,
            detail: detail
        )
    }

    static func missing(path: String? = nil, detail: String? = nil) -> HermesRuntimeHomeStatus {
        HermesRuntimeHomeStatus(level: .unavailable, path: path, detail: detail)
    }

    var displayPath: String {
        path ?? "Not discovered"
    }

    var supportingDetail: String? {
        source ?? detail
    }
}

struct HermesRuntimeActiveSelection: Codable, Equatable, Sendable {
    var providerName: String?
    var modelName: String?
    var source: String?
    var detail: String?

    init(
        providerName: String? = nil,
        modelName: String? = nil,
        source: String? = nil,
        detail: String? = nil
    ) {
        self.providerName = providerName?.nilIfBlank
        self.modelName = modelName?.nilIfBlank
        self.source = source?.nilIfBlank
        self.detail = detail?.nilIfBlank
    }

    static let unknown = HermesRuntimeActiveSelection()

    var isDiscovered: Bool {
        providerName != nil || modelName != nil
    }

    var providerDisplay: String {
        providerName ?? "Not discovered"
    }

    var modelDisplay: String {
        modelName ?? "Not discovered"
    }

    var supportingDetail: String? {
        source ?? detail
    }
}

struct HermesRuntimeComponentStatus: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case memory
        case sessions
        case skills
        case cron
        case models
        case gateway
        case cua

        var id: String { rawValue }

        var title: String {
            switch self {
            case .memory:
                return "Memory"
            case .sessions:
                return "Sessions"
            case .skills:
                return "Skills"
            case .cron:
                return "Cron"
            case .models:
                return "Models"
            case .gateway:
                return "Gateway"
            case .cua:
                return "Cua"
            }
        }

        var systemImage: String {
            switch self {
            case .memory:
                return "brain.head.profile"
            case .sessions:
                return "text.bubble"
            case .skills:
                return "wand.and.stars"
            case .cron:
                return "clock.arrow.circlepath"
            case .models:
                return "cpu"
            case .gateway:
                return "point.3.connected.trianglepath.dotted"
            case .cua:
                return "desktopcomputer"
            }
        }
    }

    var kind: Kind
    var level: HermesRuntimeHealthLevel
    var value: String?
    var detail: String?
    var path: String?

    var id: Kind { kind }

    init(
        kind: Kind,
        level: HermesRuntimeHealthLevel = .unknown,
        value: String? = nil,
        detail: String? = nil,
        path: String? = nil
    ) {
        self.kind = kind
        self.level = level
        self.value = value?.nilIfBlank
        self.detail = detail?.nilIfBlank
        self.path = path?.nilIfBlank
    }

    static func ready(
        _ kind: Kind,
        value: String? = nil,
        detail: String? = nil,
        path: String? = nil
    ) -> HermesRuntimeComponentStatus {
        HermesRuntimeComponentStatus(
            kind: kind,
            level: .ready,
            value: value,
            detail: detail,
            path: path
        )
    }

    static func missing(
        _ kind: Kind,
        value: String? = nil,
        detail: String? = nil,
        path: String? = nil
    ) -> HermesRuntimeComponentStatus {
        HermesRuntimeComponentStatus(
            kind: kind,
            level: .unavailable,
            value: value,
            detail: detail,
            path: path
        )
    }

    var displayValue: String {
        value ?? path ?? level.displayName
    }
}

struct HermesRuntimeHealthSnapshot: Codable, Equatable, Sendable {
    var cli: HermesRuntimeCLIStatus
    var hermesHome: HermesRuntimeHomeStatus
    var activeSelection: HermesRuntimeActiveSelection
    var components: [HermesRuntimeComponentStatus]
    var scopeLabel: String?
    var checkedAt: Date?

    init(
        cli: HermesRuntimeCLIStatus = .unknown,
        hermesHome: HermesRuntimeHomeStatus = .unknown,
        activeSelection: HermesRuntimeActiveSelection = .unknown,
        components: [HermesRuntimeComponentStatus] = [],
        scopeLabel: String? = nil,
        checkedAt: Date? = nil
    ) {
        self.cli = cli
        self.hermesHome = hermesHome
        self.activeSelection = activeSelection
        self.components = components
        self.scopeLabel = scopeLabel?.nilIfBlank
        self.checkedAt = checkedAt
    }

    static let empty = HermesRuntimeHealthSnapshot()

    var normalizedComponents: [HermesRuntimeComponentStatus] {
        var byKind: [HermesRuntimeComponentStatus.Kind: HermesRuntimeComponentStatus] = [:]
        for component in components {
            byKind[component.kind] = component
        }

        return HermesRuntimeComponentStatus.Kind.allCases.map { kind in
            byKind[kind] ?? HermesRuntimeComponentStatus(kind: kind)
        }
    }

    var overallLevel: HermesRuntimeHealthLevel {
        if cli.level == .unavailable || hermesHome.level == .unavailable {
            return .unavailable
        }

        let componentLevels = normalizedComponents.map(\.level)
        if componentLevels.contains(.unavailable) || componentLevels.contains(.degraded) {
            return .degraded
        }

        let readinessBlockingUnknowns: Set<HermesRuntimeComponentStatus.Kind> = [
            .memory,
            .sessions,
            .skills,
            .cron,
            .models,
        ]
        if cli.level == .unknown ||
            hermesHome.level == .unknown ||
            normalizedComponents.contains(where: { $0.level == .unknown && readinessBlockingUnknowns.contains($0.kind) }) {
            return .unknown
        }

        return .ready
    }

    var readyComponentCount: Int {
        normalizedComponents.filter { $0.level == .ready }.count
    }

    var attentionComponentCount: Int {
        normalizedComponents.filter { $0.level == .degraded || $0.level == .unavailable }.count
    }
}

extension HermesRuntimeHealthSnapshot {
    init(
        runtimeStatus status: HermesRuntimeStatus,
        cuaAvailability: CuaComputerSessionAvailability? = nil
    ) {
        self.init(
            cli: HermesRuntimeCLIStatus(runtimeStatus: status),
            hermesHome: HermesRuntimeHomeStatus(runtimeHome: status.home),
            activeSelection: HermesRuntimeActiveSelection(runtimeModel: status.model),
            components: HermesRuntimeComponentStatus.components(
                runtimeStatus: status,
                cuaAvailability: cuaAvailability
            ),
            scopeLabel: "Local Hermes runtime",
            checkedAt: Date()
        )
    }
}

private extension HermesRuntimeCLIStatus {
    init(runtimeStatus status: HermesRuntimeStatus) {
        guard let executable = status.executable else {
            self = .missing(detail: "Hermes CLI was not found on PATH or known fallback locations.")
            return
        }

        if status.version?.isAvailable == true {
            self = .available(
                version: status.version?.label,
                executablePath: executable.path,
                detail: executable.source.displayName
            )
        } else {
            self.init(
                level: .degraded,
                executablePath: executable.path,
                detail: status.version?.stderr.nilIfBlank ?? "Hermes CLI was found, but version detection did not complete."
            )
        }
    }
}

private extension HermesRuntimeHomeStatus {
    init(runtimeHome home: HermesRuntimeHome) {
        if home.exists {
            self = .available(path: home.path, source: home.source.displayName)
        } else {
            self = .missing(path: home.path, detail: "Directory does not exist.")
        }
    }
}

private extension HermesRuntimeActiveSelection {
    init(runtimeModel model: HermesRuntimeModelConfig?) {
        guard let model else {
            self.init(detail: "No model configuration was discovered.")
            return
        }

        self.init(
            providerName: model.provider,
            modelName: model.defaultModel,
            source: model.sourcePath,
            detail: model.baseURL
        )
    }
}

private extension HermesRuntimeComponentStatus {
    static func components(
        runtimeStatus status: HermesRuntimeStatus,
        cuaAvailability: CuaComputerSessionAvailability?
    ) -> [HermesRuntimeComponentStatus] {
        guard status.home.exists else {
            return Kind.allCases.map { kind in
                if kind == .cua {
                    return cuaStatus(cuaAvailability)
                }
                return HermesRuntimeComponentStatus.missing(kind, detail: "HERMES_HOME is not available.")
            }
        }

        return [
            memoryStatus(runtimeStatus: status),
            sessionsStatus(runtimeStatus: status),
            directoryStatus(
                runtimeStatus: status,
                kind: .skills,
                fileKind: .skillsDirectory,
                missingDetail: "Skills directory does not exist."
            ),
            directoryStatus(
                runtimeStatus: status,
                kind: .cron,
                fileKind: .cronDirectory,
                missingDetail: "Cron directory does not exist."
            ),
            modelsStatus(runtimeStatus: status),
            gatewayStatus(runtimeStatus: status),
            cuaStatus(cuaAvailability),
        ]
    }

    static func cuaStatus(_ availability: CuaComputerSessionAvailability?) -> HermesRuntimeComponentStatus {
        guard let availability else {
            return HermesRuntimeComponentStatus(
                kind: .cua,
                value: "Optional",
                detail: "CUA remains opt-in; run Hermes computer-use setup before enabling local computer sessions."
            )
        }

        switch availability.state {
        case .ready:
            return .ready(
                .cua,
                value: "Prereqs ready",
                detail: "Hermes and cua-driver are installed. Local computer-use start remains gated until explicitly enabled.",
                path: availability.cuaDriverPath
            )
        case .disabled:
            return HermesRuntimeComponentStatus(
                kind: .cua,
                level: .unknown,
                value: "Gated",
                detail: availability.message
            )
        case .unsupportedPlatform, .missingHermesCLI, .missingCuaDriver:
            return .missing(
                .cua,
                value: "Setup needed",
                detail: [availability.message, availability.installHint].compactMap { $0 }.joined(separator: " "),
                path: availability.cuaDriverPath ?? availability.hermesPath
            )
        }
    }

    static func memoryStatus(runtimeStatus status: HermesRuntimeStatus) -> HermesRuntimeComponentStatus {
        guard let memory = status.config.file(.memoryFile) else {
            return HermesRuntimeComponentStatus(
                kind: .memory,
                detail: "Memory file was not included in the runtime probe."
            )
        }

        guard memory.exists else {
            return HermesRuntimeComponentStatus(
                kind: .memory,
                level: .degraded,
                value: "Not created",
                detail: "Hermes can create MEMORY.md after the first local memory write.",
                path: memory.path
            )
        }

        return HermesRuntimeComponentStatus(
            kind: .memory,
            level: memory.isReadable ? .ready : .degraded,
            value: memory.isReadable ? "Readable" : "Exists but is not readable",
            path: memory.path
        )
    }

    static func sessionsStatus(runtimeStatus status: HermesRuntimeStatus) -> HermesRuntimeComponentStatus {
        directoryStatus(
            runtimeStatus: status,
            kind: .sessions,
            fileKind: .sessionsDirectory,
            missingDetail: "Sessions directory does not exist."
        )
    }

    static func directoryStatus(
        runtimeStatus status: HermesRuntimeStatus,
        kind: Kind,
        fileKind: HermesRuntimeConfigFileKind,
        missingDetail: String
    ) -> HermesRuntimeComponentStatus {
        guard let directory = status.config.file(fileKind) else {
            return HermesRuntimeComponentStatus(
                kind: kind,
                detail: "Directory was not included in the runtime probe."
            )
        }

        guard directory.exists else {
            return .missing(kind, detail: missingDetail, path: directory.path)
        }

        guard directory.isDirectory else {
            return HermesRuntimeComponentStatus(
                kind: kind,
                level: .degraded,
                value: "Path is not a directory",
                path: directory.path
            )
        }

        return HermesRuntimeComponentStatus(
            kind: kind,
            level: directory.isReadable ? .ready : .degraded,
            value: directory.isReadable ? "Readable" : "Exists but is not readable",
            path: directory.path
        )
    }

    static func modelsStatus(runtimeStatus status: HermesRuntimeStatus) -> HermesRuntimeComponentStatus {
        guard !status.localModelServers.isEmpty else {
            return HermesRuntimeComponentStatus(
                kind: .models,
                detail: "Local model servers were not probed."
            )
        }

        let available = status.localModelServers.filter { $0.availability == .available }
        if !available.isEmpty {
            return .ready(
                .models,
                value: "\(available.count) available",
                detail: available.map(\.server.name).joined(separator: ", ")
            )
        }

        let details = status.localModelServers.map { serverStatus in
            if let statusCode = serverStatus.statusCode {
                return "\(serverStatus.server.name): HTTP \(statusCode)"
            }
            if let message = serverStatus.message?.nilIfBlank {
                return "\(serverStatus.server.name): \(message)"
            }
            return "\(serverStatus.server.name): \(serverStatus.availability.rawValue)"
        }

        return HermesRuntimeComponentStatus(
            kind: .models,
            level: .degraded,
            value: "No local model server reachable",
            detail: details.joined(separator: "; ")
        )
    }

    static func gatewayStatus(runtimeStatus status: HermesRuntimeStatus) -> HermesRuntimeComponentStatus {
        guard let gateway = status.config.file(.gatewayStateFile) else {
            return HermesRuntimeComponentStatus(
                kind: .gateway,
                detail: "Gateway state file was not included in the runtime probe."
            )
        }

        guard gateway.exists else {
            return HermesRuntimeComponentStatus(
                kind: .gateway,
                value: "No gateway state",
                detail: "Gateway is not running or has not written state.",
                path: gateway.path
            )
        }

        guard gateway.isReadable,
              let raw = try? String(contentsOfFile: gateway.path, encoding: .utf8)
        else {
            return HermesRuntimeComponentStatus(
                kind: .gateway,
                level: .degraded,
                value: "State unreadable",
                path: gateway.path
            )
        }

        guard let snapshot = GatewayStateSnapshot.decode(from: raw) else {
            return HermesRuntimeComponentStatus(
                kind: .gateway,
                level: .degraded,
                value: "State invalid",
                path: gateway.path
            )
        }

        if snapshot.isRunning {
            return .ready(
                .gateway,
                value: "Running",
                detail: snapshot.updated_at,
                path: gateway.path
            )
        }

        return HermesRuntimeComponentStatus(
            kind: .gateway,
            level: .degraded,
            value: snapshot.gateway_state?.nilIfBlank ?? "Not running",
            detail: snapshot.exit_reason?.nilIfBlank,
            path: gateway.path
        )
    }
}

private extension HermesRuntimeExecutableSource {
    var displayName: String {
        switch self {
        case .path:
            return "PATH"
        case .fallback:
            return "Fallback path"
        }
    }
}

private extension HermesRuntimeHomeSource {
    var displayName: String {
        switch self {
        case .environment:
            return "HERMES_HOME"
        case .default:
            return "Default ~/.hermes"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
