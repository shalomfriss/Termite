import Foundation

enum ScheduledJobScriptSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case pasted
    case file

    var id: Self { self }

    var title: String {
        switch self {
        case .pasted: "Paste Script"
        case .file: "Script File"
        }
    }
}
