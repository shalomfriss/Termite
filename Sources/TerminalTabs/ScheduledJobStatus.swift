import Foundation

enum ScheduledJobStatus: String, Codable, Sendable {
    case scheduled
    case saved
    case launching
    case launched
    case failed
}
