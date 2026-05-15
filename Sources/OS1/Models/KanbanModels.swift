import Foundation

struct KanbanBoardResponse: Codable, Sendable {
    let ok: Bool
    let board: KanbanBoard
}

struct KanbanTaskDetailResponse: Codable, Sendable {
    let ok: Bool
    let detail: KanbanTaskDetail
}

struct KanbanOperationResponse: Codable, Sendable {
    let ok: Bool
    let message: String?
    let taskID: String?
    let detail: KanbanTaskDetail?
    let dispatch: KanbanDispatchResult?

    enum CodingKeys: String, CodingKey {
        case ok
        case message
        case taskID = "task_id"
        case detail
        case dispatch
    }
}

struct KanbanBoard: Codable, Hashable, Sendable {
    let databasePath: String
    let hostWide: Bool
    let isInitialized: Bool
    let hasKanbanModule: Bool
    let hasHermesCLI: Bool
    let dispatcher: KanbanDispatcherStatus?
    let latestEventID: Int?
    let tasks: [KanbanTask]
    let assignees: [KanbanAssignee]
    let tenants: [String]
    let stats: KanbanStats?

    enum CodingKeys: String, CodingKey {
        case databasePath = "database_path"
        case hostWide = "host_wide"
        case isInitialized = "is_initialized"
        case hasKanbanModule = "has_kanban_module"
        case hasHermesCLI = "has_hermes_cli"
        case dispatcher
        case latestEventID = "latest_event_id"
        case tasks
        case assignees
        case tenants
        case stats
    }

    static let empty = KanbanBoard(
        databasePath: "~/.hermes/kanban.db",
        hostWide: true,
        isInitialized: false,
        hasKanbanModule: false,
        hasHermesCLI: false,
        dispatcher: nil,
        latestEventID: nil,
        tasks: [],
        assignees: [],
        tenants: [],
        stats: nil
    )

    var visibleStatuses: [KanbanTaskStatus] {
        KanbanTaskStatus.boardStatuses.filter { status in
            status != .archived || tasks.contains(where: { $0.status == .archived })
        }
    }

    func tasks(for status: KanbanTaskStatus) -> [KanbanTask] {
        tasks.filter { $0.status == status }
    }

    func task(id: String?) -> KanbanTask? {
        guard let id else { return nil }
        return tasks.first(where: { $0.id == id })
    }
}

struct KanbanTask: Codable, Identifiable, Hashable, Sendable, TitleIdentifiable {
    let id: String
    let title: String?
    let body: String?
    let assignee: String?
    let status: KanbanTaskStatus
    let priority: Int
    let createdBy: String?
    let createdAt: Int?
    let startedAt: Int?
    let completedAt: Int?
    let workspaceKind: KanbanWorkspaceKind
    let workspacePath: String?
    let tenant: String?
    let result: String?
    let skills: [String]
    let spawnFailures: Int
    let workerPID: Int?
    let lastSpawnError: String?
    let maxRuntimeSeconds: Int?
    let lastHeartbeatAt: Int?
    let currentRunID: Int?
    let parentIDs: [String]
    let childIDs: [String]
    let progress: KanbanTaskProgress?
    let commentCount: Int
    let eventCount: Int
    let runCount: Int
    let latestEventAt: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case assignee
        case status
        case priority
        case createdBy = "created_by"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case workspaceKind = "workspace_kind"
        case workspacePath = "workspace_path"
        case tenant
        case result
        case skills
        case spawnFailures = "spawn_failures"
        case workerPID = "worker_pid"
        case lastSpawnError = "last_spawn_error"
        case maxRuntimeSeconds = "max_runtime_seconds"
        case lastHeartbeatAt = "last_heartbeat_at"
        case currentRunID = "current_run_id"
        case parentIDs = "parent_ids"
        case childIDs = "child_ids"
        case progress
        case commentCount = "comment_count"
        case eventCount = "event_count"
        case runCount = "run_count"
        case latestEventAt = "latest_event_at"
    }

    init(
        id: String,
        title: String?,
        body: String?,
        assignee: String?,
        status: KanbanTaskStatus,
        priority: Int,
        createdBy: String?,
        createdAt: Int?,
        startedAt: Int?,
        completedAt: Int?,
        workspaceKind: KanbanWorkspaceKind,
        workspacePath: String?,
        tenant: String?,
        result: String?,
        skills: [String],
        spawnFailures: Int,
        workerPID: Int?,
        lastSpawnError: String?,
        maxRuntimeSeconds: Int?,
        lastHeartbeatAt: Int?,
        currentRunID: Int?,
        parentIDs: [String],
        childIDs: [String],
        progress: KanbanTaskProgress?,
        commentCount: Int,
        eventCount: Int,
        runCount: Int,
        latestEventAt: Int?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.assignee = assignee
        self.status = status
        self.priority = priority
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.tenant = tenant
        self.result = result
        self.skills = skills
        self.spawnFailures = spawnFailures
        self.workerPID = workerPID
        self.lastSpawnError = lastSpawnError
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.lastHeartbeatAt = lastHeartbeatAt
        self.currentRunID = currentRunID
        self.parentIDs = parentIDs
        self.childIDs = childIDs
        self.progress = progress
        self.commentCount = commentCount
        self.eventCount = eventCount
        self.runCount = runCount
        self.latestEventAt = latestEventAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        status = try container.decodeIfPresent(KanbanTaskStatus.self, forKey: .status) ?? .other("unknown")
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Int.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Int.self, forKey: .completedAt)
        workspaceKind = try container.decodeIfPresent(KanbanWorkspaceKind.self, forKey: .workspaceKind) ?? .scratch
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        spawnFailures = try container.decodeIfPresent(Int.self, forKey: .spawnFailures) ?? 0
        workerPID = try container.decodeIfPresent(Int.self, forKey: .workerPID)
        lastSpawnError = try container.decodeIfPresent(String.self, forKey: .lastSpawnError)
        maxRuntimeSeconds = try container.decodeIfPresent(Int.self, forKey: .maxRuntimeSeconds)
        lastHeartbeatAt = try container.decodeIfPresent(Int.self, forKey: .lastHeartbeatAt)
        currentRunID = try container.decodeIfPresent(Int.self, forKey: .currentRunID)
        parentIDs = try container.decodeIfPresent([String].self, forKey: .parentIDs) ?? []
        childIDs = try container.decodeIfPresent([String].self, forKey: .childIDs) ?? []
        progress = try container.decodeIfPresent(KanbanTaskProgress.self, forKey: .progress)
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        latestEventAt = try container.decodeIfPresent(Int.self, forKey: .latestEventAt)
    }

    var resolvedTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }

    var trimmedBody: String? {
        trimmedText(body)
    }

    var trimmedResult: String? {
        trimmedText(result)
    }

    var createdDate: Date? {
        createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var latestActivityDate: Date? {
        (latestEventAt ?? completedAt ?? startedAt ?? createdAt)
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var isRunning: Bool {
        status == .running
    }

    var isBlocked: Bool {
        status == .blocked
    }

    var isTerminal: Bool {
        status == .done || status == .archived
    }

    var canBlock: Bool {
        status == .ready || status == .running
    }

    var canComplete: Bool {
        status == .ready || status == .running || status == .blocked
    }

    var canUnblock: Bool {
        status == .blocked
    }

    var priorityLabel: String {
        if priority > 0 {
            return "P+\(priority)"
        }
        if priority < 0 {
            return "P\(priority)"
        }
        return "P0"
    }

    var progressLabel: String? {
        guard let progress, progress.total > 0 else { return nil }
        return L10n.string("%@/%@ done", "\(progress.done)", "\(progress.total)")
    }

    var shortID: String {
        if id.count <= 10 {
            return id
        }
        return String(id.prefix(10))
    }

    func matchesSearch(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let foldingOptions: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
        let normalizedQuery = trimmedQuery.folding(options: foldingOptions, locale: Locale.current)
        var haystacks: [String] = [
            id,
            resolvedTitle,
            body ?? "",
            assignee ?? "",
            status.displayTitle,
            tenant ?? "",
            result ?? "",
            workspacePath ?? "",
            createdBy ?? ""
        ]
        haystacks.append(contentsOf: skills)
        haystacks.append(contentsOf: parentIDs)
        haystacks.append(contentsOf: childIDs)

        return haystacks.contains { value in
            value.folding(options: foldingOptions, locale: Locale.current)
                .localizedStandardContains(normalizedQuery)
        }
    }

    private func trimmedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum KanbanTaskStatus: Hashable, Codable, Sendable {
    case triage
    case todo
    case ready
    case running
    case blocked
    case done
    case archived
    case other(String)

    static let boardStatuses: [KanbanTaskStatus] = [
        .triage,
        .todo,
        .ready,
        .running,
        .blocked,
        .done,
        .archived
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "triage":
            self = .triage
        case "todo":
            self = .todo
        case "ready":
            self = .ready
        case "running":
            self = .running
        case "blocked":
            self = .blocked
        case "done":
            self = .done
        case "archived":
            self = .archived
        default:
            self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .triage:
            "triage"
        case .todo:
            "todo"
        case .ready:
            "ready"
        case .running:
            "running"
        case .blocked:
            "blocked"
        case .done:
            "done"
        case .archived:
            "archived"
        case .other(let value):
            value
        }
    }

    var displayTitle: String {
        switch self {
        case .triage:
            "Triage"
        case .todo:
            "Todo"
        case .ready:
            "Ready"
        case .running:
            "Running"
        case .blocked:
            "Blocked"
        case .done:
            "Done"
        case .archived:
            "Archived"
        case .other(let value):
            value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum KanbanWorkspaceKind: Hashable, Codable, Sendable {
    case scratch
    case worktree
    case directory
    case other(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scratch":
            self = .scratch
        case "worktree":
            self = .worktree
        case "dir":
            self = .directory
        default:
            self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .scratch:
            "scratch"
        case .worktree:
            "worktree"
        case .directory:
            "dir"
        case .other(let value):
            value
        }
    }

    var displayTitle: String {
        switch self {
        case .scratch:
            "Scratch"
        case .worktree:
            "Worktree"
        case .directory:
            "Directory"
        case .other(let value):
            value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct KanbanTaskProgress: Codable, Hashable, Sendable {
    let done: Int
    let total: Int
}

struct KanbanTaskDetail: Codable, Hashable, Sendable {
    let task: KanbanTask
    let parentIDs: [String]
    let childIDs: [String]
    let comments: [KanbanComment]
    let events: [KanbanEvent]
    let runs: [KanbanRun]
    let workerLog: String?

    enum CodingKeys: String, CodingKey {
        case task
        case parentIDs = "parent_ids"
        case childIDs = "child_ids"
        case comments
        case events
        case runs
        case workerLog = "worker_log"
    }
}

struct KanbanComment: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let taskID: String
    let author: String
    let body: String
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case author
        case body
        case createdAt = "created_at"
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }
}

struct KanbanEvent: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let taskID: String
    let kind: String
    let payload: [String: JSONValue]?
    let createdAt: Int
    let runID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case kind
        case payload
        case createdAt = "created_at"
        case runID = "run_id"
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    var displayPayload: String? {
        guard let payload, !payload.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(payload)),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

struct KanbanRun: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let taskID: String
    let profile: String?
    let stepKey: String?
    let status: String
    let outcome: String?
    let summary: String?
    let error: String?
    let metadata: [String: JSONValue]?
    let workerPID: Int?
    let startedAt: Int
    let endedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case profile
        case stepKey = "step_key"
        case status
        case outcome
        case summary
        case error
        case metadata
        case workerPID = "worker_pid"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    var startedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startedAt))
    }

    var endedDate: Date? {
        endedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var resolvedOutcome: String {
        outcome ?? (endedAt == nil ? "running" : status)
    }
}

struct KanbanAssignee: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let onDisk: Bool
    let counts: [String: Int]

    enum CodingKeys: String, CodingKey {
        case name
        case onDisk = "on_disk"
        case counts
    }

    var id: String { name }
}

struct KanbanStats: Codable, Hashable, Sendable {
    let byStatus: [String: Int]
    let byAssignee: [String: [String: Int]]
    let oldestReadyAgeSeconds: Int?
    let now: Int?

    enum CodingKeys: String, CodingKey {
        case byStatus = "by_status"
        case byAssignee = "by_assignee"
        case oldestReadyAgeSeconds = "oldest_ready_age_seconds"
        case now
    }
}

struct KanbanDispatcherStatus: Codable, Hashable, Sendable {
    let running: Bool?
    let message: String?

    var isKnownInactive: Bool {
        running == false
    }
}

struct KanbanDispatchResult: Codable, Hashable, Sendable {
    let reclaimed: Int
    let crashed: [String]
    let timedOut: [String]
    let autoBlocked: [String]
    let promoted: Int
    let spawned: [KanbanSpawnedTask]
    let skippedUnassigned: [String]

    enum CodingKeys: String, CodingKey {
        case reclaimed
        case crashed
        case timedOut = "timed_out"
        case autoBlocked = "auto_blocked"
        case promoted
        case spawned
        case skippedUnassigned = "skipped_unassigned"
    }
}

struct KanbanSpawnedTask: Codable, Hashable, Sendable {
    let taskID: String
    let assignee: String
    let workspace: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case assignee
        case workspace
    }
}

struct KanbanTaskDraft: Equatable {
    var title = ""
    var body = ""
    var assignee = ""
    var priority = 0
    var tenant = ""
    var skillsText = ""
    var startsInTriage = false

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedBody: String? {
        let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedAssignee: String? {
        let value = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedTenant: String? {
        let value = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var skills: [String] {
        skillsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var validationError: String? {
        if normalizedTitle.isEmpty {
            return "Task title is required."
        }
        if skills.contains(where: { $0.contains(",") }) {
            return "Skill names must be comma-separated without embedded commas."
        }
        return nil
    }
}

struct KanbanActionDraft: Equatable {
    var comment = ""
    var result = ""
    var blockReason = ""
    var assignee = ""

    var normalizedComment: String? {
        let value = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedResult: String? {
        let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedBlockReason: String? {
        let value = blockReason.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalizedAssignee: String? {
        let value = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
