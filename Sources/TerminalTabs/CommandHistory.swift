import Foundation

struct CommandHistory: Equatable, Sendable {
    static let defaultLimit = 200
    static let maximumLimit = 1_000

    private(set) var commands: [String]
    private(set) var limit: Int

    init(commands: [String] = [], limit: Int = defaultLimit) {
        self.limit = Self.clampedLimit(limit)
        self.commands = []
        for command in commands {
            record(command)
        }
    }

    mutating func record(_ command: String) {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !normalized.isEmpty else { return }
        commands.removeAll { $0 == normalized }
        commands.append(normalized)
        if commands.count > limit {
            commands.removeFirst(commands.count - limit)
        }
    }

    mutating func setLimit(_ newLimit: Int) {
        limit = Self.clampedLimit(newLimit)
        if commands.count > limit {
            commands.removeFirst(commands.count - limit)
        }
    }

    mutating func removeAll() {
        commands.removeAll(keepingCapacity: false)
    }

    func prediction(for prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        return commands.reversed().first {
            $0.count > prefix.count && $0.hasPrefix(prefix)
        }
    }

    private static func clampedLimit(_ value: Int) -> Int {
        min(max(0, value), maximumLimit)
    }
}
