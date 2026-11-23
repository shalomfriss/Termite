import SwiftUI

struct PredictiveTypingSettingsSection: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        GroupBox("Predictive typing") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Suggest commands from local history",
                    isOn: $store.predictiveTypingEnabled
                )

                LabeledContent("History limit") {
                    Stepper(
                        value: $store.commandHistoryLimit,
                        in: 25...CommandHistory.maximumLimit,
                        step: 25
                    ) {
                        Text("\(store.commandHistoryLimit) commands")
                            .monospacedDigit()
                    }
                    .fixedSize()
                }

                Text("Suggestions stay on this Mac. Press Right Arrow to accept the dimmed text. Turning suggestions off stops recording new commands; Clear History removes saved commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button(
                        "Clear History",
                        systemImage: "trash",
                        role: .destructive,
                        action: store.clearCommandHistory
                    )
                    .help("Delete predictive command history")
                }
            }
            .padding(8)
        }
    }
}
