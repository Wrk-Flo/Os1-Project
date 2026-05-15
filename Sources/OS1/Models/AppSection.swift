import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case connections
    case overview
    case files
    case sessions
    case cronjobs
    case kanban
    case usage
    case skills
    case knowledgeBase
    case terminal
    case desktop
    case mail
    case messaging
    case connectors
    case providers
    case doctor

    var id: String { rawValue }

    var title: String {
        L10n.string(rawTitle)
    }

    private var rawTitle: String {
        switch self {
        case .connections:
            "Host"
        case .overview:
            "Overview"
        case .files:
            "Files"
        case .sessions:
            "Sessions"
        case .cronjobs:
            "Cron Jobs"
        case .kanban:
            "Kanban"
        case .usage:
            "Usage"
        case .skills:
            "Skills"
        case .knowledgeBase:
            "Knowledge Base"
        case .terminal:
            "Terminal"
        case .desktop:
            "Desktop"
        case .mail:
            "Mail"
        case .messaging:
            "Messaging"
        case .connectors:
            "Connectors"
        case .providers:
            "Providers"
        case .doctor:
            "Doctor"
        }
    }

    var systemImage: String {
        switch self {
        case .connections:
            "server.rack"
        case .overview:
            "waveform.path.ecg"
        case .files:
            "doc.text"
        case .sessions:
            "clock.arrow.circlepath"
        case .cronjobs:
            "calendar.badge.clock"
        case .kanban:
            "rectangle.3.group"
        case .usage:
            "chart.bar.xaxis"
        case .skills:
            "book.closed"
        case .knowledgeBase:
            "books.vertical.fill"
        case .terminal:
            "terminal"
        case .desktop:
            "display"
        case .mail:
            "envelope"
        case .messaging:
            "paperplane.fill"
        case .connectors:
            "puzzlepiece.extension"
        case .providers:
            "cpu"
        case .doctor:
            "stethoscope"
        }
    }
}
