import SwiftUI

struct HermesRuntimeView: View {
    let status: HermesRuntimeStatus?
    let errorMessage: String?
    let isRefreshing: Bool
    let refresh: () -> Void

    init(
        status: HermesRuntimeStatus?,
        errorMessage: String?,
        isRefreshing: Bool,
        refresh: @escaping () -> Void
    ) {
        self.status = status
        self.errorMessage = errorMessage
        self.isRefreshing = isRefreshing
        self.refresh = refresh
    }

    var body: some View {
        HermesPageContainer(width: .dashboard) {
            VStack(alignment: .leading, spacing: 16) {
                HermesPageHeader(
                    title: "Hermes Runtime",
                    subtitle: "Local Hermes runtime"
                ) {
                    HermesRefreshButton(isRefreshing: isRefreshing, action: refresh)
                }

                if let errorMessage {
                    HermesValidationMessage(text: errorMessage)
                }

                if let status {
                    HermesRuntimeHealthPanel(
                        snapshot: HermesRuntimeHealthSnapshot(runtimeStatus: status)
                    )
                } else if isRefreshing {
                    HermesSurfacePanel {
                        HermesLoadingState(label: "Refreshing Hermes runtime…", minHeight: 220)
                    }
                } else {
                    HermesSurfacePanel(
                        title: "Runtime health",
                        subtitle: "Click Refresh to inspect the local Hermes CLI, home directory, and runtime features."
                    ) {
                        EmptyView()
                    }
                }
            }
        }
    }
}

private extension HermesRuntimeHealthSnapshot {
    init(runtimeStatus status: HermesRuntimeStatus) {
        self.init(
            cli: HermesRuntimeCLIStatus(runtimeStatus: status),
            hermesHome: HermesRuntimeHomeStatus(runtimeHome: status.home),
            activeSelection: HermesRuntimeActiveSelection(runtimeModel: status.model),
            components: HermesRuntimeComponentStatus.components(runtimeStatus: status),
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
    static func components(runtimeStatus status: HermesRuntimeStatus) -> [HermesRuntimeComponentStatus] {
        guard status.home.exists else {
            return Kind.allCases.map { kind in
                .missing(kind, detail: "HERMES_HOME is not available.")
            }
        }

        return [
            HermesRuntimeComponentStatus(
                kind: .memory,
                detail: "Waiting for memory probe data."
            ),
            sessionsStatus(runtimeStatus: status),
            HermesRuntimeComponentStatus(
                kind: .skills,
                detail: "Waiting for skills probe data."
            ),
            HermesRuntimeComponentStatus(
                kind: .cron,
                detail: "Waiting for cron probe data."
            ),
            HermesRuntimeComponentStatus(
                kind: .gateway,
                detail: "Waiting for gateway probe data."
            ),
            HermesRuntimeComponentStatus(
                kind: .cua,
                detail: "Waiting for Cua probe data."
            ),
        ]
    }

    static func sessionsStatus(runtimeStatus status: HermesRuntimeStatus) -> HermesRuntimeComponentStatus {
        guard let sessions = status.config.file(.sessionsDirectory) else {
            return HermesRuntimeComponentStatus(
                kind: .sessions,
                detail: "Sessions directory was not included in the runtime probe."
            )
        }

        guard sessions.exists else {
            return .missing(
                .sessions,
                detail: "Sessions directory does not exist.",
                path: sessions.path
            )
        }

        return HermesRuntimeComponentStatus(
            kind: .sessions,
            level: sessions.isReadable ? .ready : .degraded,
            value: sessions.isReadable ? "Readable" : "Exists but is not readable",
            path: sessions.path
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
