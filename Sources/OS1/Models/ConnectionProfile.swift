import Foundation

// MARK: - Sub-types

struct SSHConfig: Codable, Equatable, Hashable {
    var alias: String
    var host: String
    var port: Int?
    var user: String

    init(alias: String = "", host: String = "", port: Int? = nil, user: String = "") {
        self.alias = alias
        self.host = host
        self.port = port
        self.user = user
    }
}

struct OrgoConfig: Codable, Equatable, Hashable {
    var workspaceId: String
    var computerId: String

    init(workspaceId: String = "", computerId: String = "") {
        self.workspaceId = workspaceId
        self.computerId = computerId
    }
}

enum TransportKind: String, Codable, CaseIterable {
    case ssh
    case orgo
}

enum TransportConfig: Equatable, Hashable {
    case ssh(SSHConfig)
    case orgo(OrgoConfig)

    var kind: TransportKind {
        switch self {
        case .ssh: .ssh
        case .orgo: .orgo
        }
    }
}

extension TransportConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case ssh
        case orgo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(TransportKind.self, forKey: .kind)
        switch kind {
        case .ssh:
            self = .ssh(try container.decode(SSHConfig.self, forKey: .ssh))
        case .orgo:
            self = .orgo(try container.decode(OrgoConfig.self, forKey: .orgo))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .ssh(let cfg):
            try container.encode(cfg, forKey: .ssh)
        case .orgo(let cfg):
            try container.encode(cfg, forKey: .orgo)
        }
    }
}

// MARK: - ConnectionProfile

struct ConnectionProfile: Identifiable, Equatable, Hashable {
    var id: UUID
    var label: String
    var hermesProfile: String?
    var transport: TransportConfig
    var createdAt: Date
    var updatedAt: Date
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        label: String = "",
        hermesProfile: String? = nil,
        transport: TransportConfig = .ssh(SSHConfig()),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.hermesProfile = hermesProfile
        self.transport = transport
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }

    // Convenience init mirroring the legacy SSH-only signature so existing
    // callers and tests keep working without churn.
    init(
        id: UUID = UUID(),
        label: String = "",
        sshAlias: String = "",
        sshHost: String = "",
        sshPort: Int? = nil,
        sshUser: String = "",
        hermesProfile: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.init(
            id: id,
            label: label,
            hermesProfile: hermesProfile,
            transport: .ssh(SSHConfig(alias: sshAlias, host: sshHost, port: sshPort, user: sshUser)),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastConnectedAt: lastConnectedAt
        )
    }
}

// MARK: - Codable with backwards-compatible decoding

extension ConnectionProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, hermesProfile, transport, createdAt, updatedAt, lastConnectedAt
        // Legacy keys retained only for decoding pre-port profiles.
        case sshAlias, sshHost, sshPort, sshUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let label = try container.decode(String.self, forKey: .label)
        let hermesProfile = try container.decodeIfPresent(String.self, forKey: .hermesProfile)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)

        let transport: TransportConfig
        if let modern = try container.decodeIfPresent(TransportConfig.self, forKey: .transport) {
            transport = modern
        } else {
            let alias = try container.decodeIfPresent(String.self, forKey: .sshAlias) ?? ""
            let host = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
            let port = try container.decodeIfPresent(Int.self, forKey: .sshPort)
            let user = try container.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
            transport = .ssh(SSHConfig(alias: alias, host: host, port: port, user: user))
        }

        self.id = id
        self.label = label
        self.hermesProfile = hermesProfile
        self.transport = transport
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(hermesProfile, forKey: .hermesProfile)
        try container.encode(transport, forKey: .transport)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }
}

// MARK: - SSH pass-through accessors (read+write for SwiftUI bindings)

extension ConnectionProfile {
    var sshAlias: String {
        get {
            if case .ssh(let cfg) = transport { return cfg.alias } else { return "" }
        }
        set {
            if case .ssh(var cfg) = transport {
                cfg.alias = newValue
                transport = .ssh(cfg)
            }
        }
    }

    var sshHost: String {
        get {
            if case .ssh(let cfg) = transport { return cfg.host } else { return "" }
        }
        set {
            if case .ssh(var cfg) = transport {
                cfg.host = newValue
                transport = .ssh(cfg)
            }
        }
    }

    var sshPort: Int? {
        get {
            if case .ssh(let cfg) = transport { return cfg.port } else { return nil }
        }
        set {
            if case .ssh(var cfg) = transport {
                cfg.port = newValue
                transport = .ssh(cfg)
            }
        }
    }

    var sshUser: String {
        get {
            if case .ssh(let cfg) = transport { return cfg.user } else { return "" }
        }
        set {
            if case .ssh(var cfg) = transport {
                cfg.user = newValue
                transport = .ssh(cfg)
            }
        }
    }
}

// MARK: - Orgo pass-through accessors (wired into editor in step 3)

extension ConnectionProfile {
    var orgoWorkspaceId: String {
        get {
            if case .orgo(let cfg) = transport { return cfg.workspaceId } else { return "" }
        }
        set {
            if case .orgo(var cfg) = transport {
                cfg.workspaceId = newValue
                transport = .orgo(cfg)
            }
        }
    }

    var orgoComputerId: String {
        get {
            if case .orgo(let cfg) = transport { return cfg.computerId } else { return "" }
        }
        set {
            if case .orgo(var cfg) = transport {
                cfg.computerId = newValue
                transport = .orgo(cfg)
            }
        }
    }
}

// MARK: - Trimmed accessors

extension ConnectionProfile {
    var trimmedAlias: String? {
        let value = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var trimmedHost: String? {
        let value = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var trimmedUser: String? {
        let value = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var trimmedHermesProfile: String? {
        guard let hermesProfile else { return nil }
        let value = hermesProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.caseInsensitiveCompare("default") != .orderedSame else { return nil }
        return value
    }

    var resolvedHermesProfileName: String {
        trimmedHermesProfile ?? "default"
    }

    var usesDefaultHermesProfile: Bool {
        trimmedHermesProfile == nil
    }
}

// MARK: - Remote path helpers (transport-agnostic — Hermes lives at ~/.hermes on either)

extension ConnectionProfile {
    var remoteHermesHomePath: String {
        if let trimmedHermesProfile {
            return "~/.hermes/profiles/\(trimmedHermesProfile)"
        }
        return "~/.hermes"
    }

    var remoteSkillsPath: String {
        "\(remoteHermesHomePath)/skills"
    }

    var remoteKnowledgeBasePath: String {
        "\(remoteHermesHomePath)/knowledge"
    }

    var remoteCronJobsPath: String {
        "\(remoteHermesHomePath)/cron/jobs.json"
    }

    var remoteKanbanHomePath: String {
        "~/.hermes"
    }

    var remoteKanbanDatabasePath: String {
        "\(remoteKanbanHomePath)/kanban.db"
    }

    func remotePath(for trackedFile: RemoteTrackedFile) -> String {
        "\(remoteHermesHomePath)/\(trackedFile.relativePathFromHermesHome)"
    }

    func applyingHermesProfile(named profileName: String) -> ConnectionProfile {
        var copy = self
        copy.hermesProfile = profileName
        return copy.updated()
    }

    var remoteShellBootstrapCommand: String {
        remoteShellBootstrapCommand()
    }

    func remoteShellBootstrapCommand(startupCommandLine: String? = nil) -> String {
        let shellHomeExpression: String
        if let trimmedHermesProfile {
            let escapedProfile = trimmedHermesProfile.escapedForDoubleQuotedShellArgument
            shellHomeExpression = "$HOME/.hermes/profiles/\(escapedProfile)"
        } else {
            shellHomeExpression = "$HOME/.hermes"
        }

        let exportCommand = "export HERMES_HOME=\"\(shellHomeExpression)\""
        guard let startupCommandLine,
              !startupCommandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(exportCommand); exec \"${SHELL:-/bin/zsh}\" -l"
        }

        let escapedStartupCommand = startupCommandLine.escapedForDoubleQuotedShellArgument
        return "\(exportCommand); exec \"${SHELL:-/bin/zsh}\" -lc \"\(escapedStartupCommand)\""
    }
}

// MARK: - SSH-shaped derived properties

extension ConnectionProfile {
    var workspaceScopeFingerprint: String {
        [
            effectiveTarget,
            trimmedUser ?? "",
            resolvedPort.map(String.init) ?? "",
            remoteHermesHomePath
        ].joined(separator: "|")
    }

    var hostConnectionFingerprint: String {
        [
            effectiveTarget,
            trimmedUser ?? "",
            resolvedPort.map(String.init) ?? ""
        ].joined(separator: "|")
    }

    var effectiveTarget: String {
        trimmedAlias ?? trimmedHost ?? ""
    }

    var usesAliasSourceOfTruth: Bool {
        trimmedAlias != nil && trimmedHost == nil
    }

    var resolvedPort: Int? {
        guard let port = sshPort, port > 0 else { return nil }
        if usesAliasSourceOfTruth && port == 22 {
            return nil
        }
        return port
    }

    var displayDestination: String {
        guard let user = trimmedUser else {
            return effectiveTarget
        }
        return "\(user)@\(effectiveTarget)"
    }
}

// MARK: - Validation

extension ConnectionProfile {
    var isValid: Bool {
        validationError == nil
    }

    var validationError: String? {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name is required."
        }
        switch transport {
        case .ssh:
            return sshValidationError
        case .orgo:
            return orgoValidationError
        }
    }

    var sshValidationError: String? {
        guard case .ssh = transport else {
            return "This profile is not configured for SSH."
        }

        guard !effectiveTarget.isEmpty else {
            return "Add an SSH alias or host."
        }

        if let error = validateSSHArgument(trimmedAlias, fieldName: "SSH alias") {
            return error
        }

        if let error = validateSSHArgument(trimmedHost, fieldName: "Host") {
            return error
        }

        if let error = validateSSHArgument(trimmedUser, fieldName: "SSH user") {
            return error
        }

        if let trimmedHermesProfile {
            if trimmedHermesProfile.contains("/") || trimmedHermesProfile == "." || trimmedHermesProfile == ".." {
                return "Hermes profile must be a profile name, not a path."
            }
            if trimmedHermesProfile.containsControlCharacter {
                return "Hermes profile contains unsupported control characters."
            }
        }

        return nil
    }

    var orgoValidationError: String? {
        guard case .orgo(let cfg) = transport else {
            return "This profile is not configured for Orgo."
        }

        if cfg.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Orgo workspace is required."
        }

        if cfg.computerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Orgo computer is required."
        }

        if let trimmedHermesProfile {
            if trimmedHermesProfile.contains("/") || trimmedHermesProfile == "." || trimmedHermesProfile == ".." {
                return "Hermes profile must be a profile name, not a path."
            }
            if trimmedHermesProfile.containsControlCharacter {
                return "Hermes profile contains unsupported control characters."
            }
        }

        return nil
    }
}

// MARK: - Mutators

extension ConnectionProfile {
    func updated() -> ConnectionProfile {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hermesProfile = trimmedHermesProfile

        switch transport {
        case .ssh(var cfg):
            cfg.alias = cfg.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.host = cfg.host.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.user = cfg.user.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = cfg.port, port <= 0 {
                cfg.port = nil
            }
            copy.transport = .ssh(cfg)
        case .orgo(var cfg):
            cfg.workspaceId = cfg.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.computerId = cfg.computerId.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.transport = .orgo(cfg)
        }

        copy.updatedAt = Date()
        return copy
    }
}

// MARK: - Private helpers

private extension String {
    var escapedForDoubleQuotedShellArgument: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    var containsControlCharacter: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

private func validateSSHArgument(_ value: String?, fieldName: String) -> String? {
    guard let value else { return nil }
    if value.hasPrefix("-") {
        return "\(fieldName) cannot start with a dash."
    }
    if value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
        return "\(fieldName) cannot contain whitespace or control characters."
    }
    return nil
}
