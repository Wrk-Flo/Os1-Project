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

        if cli.level == .unknown || hermesHome.level == .unknown || componentLevels.contains(.unknown) {
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
