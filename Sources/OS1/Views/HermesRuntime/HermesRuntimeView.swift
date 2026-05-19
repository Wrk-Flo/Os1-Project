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
