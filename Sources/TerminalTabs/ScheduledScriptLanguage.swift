import Foundation

enum ScheduledScriptLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case bash
    case python
    case posixShell
    case zsh

    var id: Self { self }

    static let pastedScriptOptions: [Self] = [.bash, .python]

    var title: String {
        switch self {
        case .bash: "Bash"
        case .python: "Python"
        case .posixShell: "Shell (sh)"
        case .zsh: "Zsh"
        }
    }

    var interpreterCommand: String {
        switch self {
        case .bash: "/bin/bash"
        case .python: "/usr/bin/env python3"
        case .posixShell: "/bin/sh"
        case .zsh: "/bin/zsh"
        }
    }

    nonisolated static func detect(at url: URL) throws -> Self {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ScheduledJobError.scriptFileUnavailable(url.path)
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384),
              let contents = String(data: data, encoding: .utf8) else {
            throw ScheduledJobError.unsupportedScriptLanguage(url.lastPathComponent)
        }
        let lowercased = contents.lowercased()
        let firstLine = lowercased.split(whereSeparator: \Character.isNewline).first
            .map(String.init) ?? ""
        if firstLine.hasPrefix("#!") {
            if firstLine.contains("python") { return .python }
            if firstLine.contains("bash") { return .bash }
            if firstLine.contains("zsh") { return .zsh }
            if firstLine.contains("/sh") || firstLine.contains("env sh") { return .posixShell }
        }

        switch url.pathExtension.lowercased() {
        case "py", "pyw": return .python
        case "bash": return .bash
        case "sh", "command": return .posixShell
        case "zsh": return .zsh
        default: break
        }

        let pythonSignals = ["import ", "from ", "def ", "print(", "if __name__"]
            .count { lowercased.contains($0) }
        let shellSignals = ["#!/bin/", "echo ", "set -e", " then", "fi\n", "function "]
            .count { lowercased.contains($0) }
        if pythonSignals >= 1, pythonSignals > shellSignals { return .python }
        if shellSignals >= 1 { return .bash }
        throw ScheduledJobError.unsupportedScriptLanguage(url.lastPathComponent)
    }
}
