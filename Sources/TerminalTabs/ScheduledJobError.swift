import Foundation

enum ScheduledJobError: LocalizedError {
    case emptyScript
    case missingScheduleDate
    case invalidWorkingDirectory(String)
    case scriptFileUnavailable(String)
    case unsupportedScriptLanguage(String)
    case shellUnavailable
    case shellReadinessTimedOut

    var errorDescription: String? {
        switch self {
        case .emptyScript:
            "Enter a script before scheduling the job."
        case .missingScheduleDate:
            "Choose a date and time for the scheduled job."
        case .invalidWorkingDirectory(let path):
            "The working directory no longer exists: \(path)"
        case .scriptFileUnavailable(let path):
            "The selected script file is no longer available: \(path)"
        case .unsupportedScriptLanguage(let name):
            "Couldn’t determine whether \(name) is a Bash, sh, Zsh, or Python script. Add a file extension or shebang."
        case .shellUnavailable:
            "The new shell could not be created."
        case .shellReadinessTimedOut:
            "The new shell did not become ready in time."
        }
    }
}
