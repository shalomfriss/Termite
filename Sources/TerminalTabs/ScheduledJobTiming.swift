import Foundation

enum ScheduledJobTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    case scheduled
    case cron
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .scheduled: "Scheduled"
        case .cron: "Cron Job"
        case .manual: "Saved Workflow"
        }
    }
}
