import Foundation

struct OrgoWorkspaceSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let computers: [OrgoComputerSummary]
}

struct OrgoComputerSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: String
}
