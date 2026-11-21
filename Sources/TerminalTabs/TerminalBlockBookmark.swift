import Foundation

struct TerminalBlockBookmark: Identifiable, Equatable, Sendable {
    let id: TerminalBlockID
    let command: String
    let output: String
    let workingDirectory: String

    var title: String {
        let normalized = command
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? "Block at row \(id.historyRow + 1)" : normalized
    }
}
