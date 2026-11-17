import Foundation

enum GraphicalFolderCreationError: LocalizedError {
    case graphicalModeRequired
    case invalidName
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .graphicalModeRequired:
            "Turn on graphical mode before creating a folder."
        case .invalidName:
            "Enter a folder name without slashes."
        case .alreadyExists(let name):
            "An item named “\(name)” already exists."
        }
    }
}
