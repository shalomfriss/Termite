import Foundation

@MainActor
final class CommandHistoryStore {
    private static let enabledKey = "predictiveTypingEnabled"
    private static let limitKey = "commandHistoryLimit"
    private static let commandsKey = "commandHistoryCommands"

    private let defaults: UserDefaults?
    private(set) var isPredictionEnabled: Bool
    private(set) var history: CommandHistory

    init(
        defaults: UserDefaults? = nil,
        predictionEnabled: Bool = false,
        limit: Int = CommandHistory.defaultLimit,
        commands: [String] = []
    ) {
        self.defaults = defaults
        if let defaults {
            isPredictionEnabled = defaults.object(forKey: Self.enabledKey) == nil
                ? predictionEnabled
                : defaults.bool(forKey: Self.enabledKey)
            let storedLimit = defaults.object(forKey: Self.limitKey) == nil
                ? limit
                : defaults.integer(forKey: Self.limitKey)
            history = CommandHistory(
                commands: defaults.stringArray(forKey: Self.commandsKey) ?? commands,
                limit: storedLimit
            )
        } else {
            isPredictionEnabled = predictionEnabled
            history = CommandHistory(commands: commands, limit: limit)
        }
    }

    var limit: Int { history.limit }

    func setPredictionEnabled(_ isEnabled: Bool) {
        isPredictionEnabled = isEnabled
        defaults?.set(isEnabled, forKey: Self.enabledKey)
    }

    func setLimit(_ limit: Int) {
        history.setLimit(limit)
        defaults?.set(history.limit, forKey: Self.limitKey)
        persistCommands()
    }

    func record(_ command: String) {
        guard isPredictionEnabled else { return }
        history.record(command)
        persistCommands()
    }

    func prediction(for prefix: String) -> String? {
        guard isPredictionEnabled else { return nil }
        return history.prediction(for: prefix)
    }

    func clear() {
        history.removeAll()
        persistCommands()
    }

    private func persistCommands() {
        defaults?.set(history.commands, forKey: Self.commandsKey)
    }
}
