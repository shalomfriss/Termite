import Foundation

enum GraphicalOperationError: LocalizedError {
    case navigationTimedOut(String)
    case promptUnavailable
    case directoryUnavailable(String)
    case iCloudDownloadTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .navigationTimedOut(let path):
            "The shell did not finish navigating to \(path)."
        case .promptUnavailable:
            "The shell prompt did not become ready. Try refreshing the directory."
        case .directoryUnavailable(let path):
            "The directory at \(path) could not be displayed."
        case .iCloudDownloadTimedOut(let name):
            "\(name) is still downloading from iCloud. Try again when the download finishes."
        }
    }
}
