import Foundation
import SwiftUI

@MainActor
final class HermesRuntimeHealthViewModel: ObservableObject {
    typealias RefreshHandler = () async throws -> HermesRuntimeHealthSnapshot

    @Published private(set) var snapshot: HermesRuntimeHealthSnapshot
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var lastRefreshedAt: Date?

    private let refreshHandler: RefreshHandler?

    init(
        snapshot: HermesRuntimeHealthSnapshot = .empty,
        refresh: RefreshHandler? = nil
    ) {
        self.snapshot = snapshot
        self.lastRefreshedAt = snapshot.checkedAt
        self.refreshHandler = refresh
    }

    var canRefresh: Bool {
        refreshHandler != nil
    }

    var statusRows: [HermesRuntimeComponentStatus] {
        snapshot.normalizedComponents
    }

    var overallLevel: HermesRuntimeHealthLevel {
        snapshot.overallLevel
    }

    var headerSubtitle: String {
        let scope = snapshot.scopeLabel ?? "Local Hermes runtime"
        guard let lastRefreshedAt else { return scope }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: lastRefreshedAt, relativeTo: Date())
        return "\(scope), checked \(when)"
    }

    func apply(_ snapshot: HermesRuntimeHealthSnapshot) {
        self.snapshot = snapshot
        self.lastRefreshedAt = snapshot.checkedAt ?? Date()
        self.lastRefreshError = nil
    }

    func refresh() async {
        guard !isRefreshing, let refreshHandler else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            apply(try await refreshHandler())
        } catch {
            lastRefreshError = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }
}
