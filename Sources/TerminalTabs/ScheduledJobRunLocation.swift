import Foundation

enum ScheduledJobRunLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case selectedFolder
    case temporaryFolder

    var id: Self { self }

    var title: String {
        switch self {
        case .selectedFolder: "Selected Folder"
        case .temporaryFolder: "Temporary Folder"
        }
    }
}
