import Foundation

struct ScheduledJobScript: Codable, Equatable, Sendable {
    var source: ScheduledJobScriptSource
    var language: ScheduledScriptLanguage
    var pastedText: String
    var filePath: String?

    static func pasted(
        _ text: String,
        language: ScheduledScriptLanguage
    ) -> Self {
        Self(
            source: .pasted,
            language: language,
            pastedText: text,
            filePath: nil
        )
    }

    static func file(at url: URL, language: ScheduledScriptLanguage) -> Self {
        Self(
            source: .file,
            language: language,
            pastedText: "",
            filePath: url.standardizedFileURL.path
        )
    }

    var summary: String {
        switch source {
        case .pasted:
            let firstLine = pastedText.split(whereSeparator: \Character.isNewline).first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstLine, !firstLine.isEmpty else { return "Scheduled Job" }
            return String(firstLine.prefix(48))
        case .file:
            guard let filePath else { return "Script File" }
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
    }

    func validate() throws {
        switch source {
        case .pasted:
            guard !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScheduledJobError.emptyScript
            }
            guard ScheduledScriptLanguage.pastedScriptOptions.contains(language) else {
                throw ScheduledJobError.unsupportedScriptLanguage(language.title)
            }
        case .file:
            guard let filePath, FileManager.default.fileExists(atPath: filePath) else {
                throw ScheduledJobError.scriptFileUnavailable(filePath ?? "")
            }
        }
    }

    func executionCommand() async throws -> String {
        switch source {
        case .pasted:
            let cleaned = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw ScheduledJobError.emptyScript }
            var delimiter = "__TERMINAL_TABS_JOB_\(UUID().uuidString.replacing("-", with: ""))__"
            while pastedText.split(whereSeparator: \Character.isNewline).contains(Substring(delimiter)) {
                delimiter += "_"
            }
            return "\(language.interpreterCommand) <<'\(delimiter)'\n\(pastedText)\n\(delimiter)"
        case .file:
            guard let filePath else { throw ScheduledJobError.scriptFileUnavailable("") }
            let url = URL(fileURLWithPath: filePath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ScheduledJobError.scriptFileUnavailable(url.path)
            }
            try await TerminalSession.ensureUbiquitousItemIsAvailable(at: url)
            let detectedLanguage = try ScheduledScriptLanguage.detect(at: url)
            return "\(detectedLanguage.interpreterCommand) -- \(TerminalSession.shellQuoted(url.path))"
        }
    }
}
