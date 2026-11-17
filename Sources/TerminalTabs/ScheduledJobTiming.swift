import Foundation

enum ScheduledJobTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    case scheduled
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .scheduled: "Scheduled"
        case .manual: "Saved Workflow"
        }
    }
}
