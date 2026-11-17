import SwiftUI

struct ScheduledScriptTextArea: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)

            if text.isEmpty {
                Text("Paste the script to execute")
                    .font(.body.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 260, idealHeight: 320, maxHeight: .infinity)
        .background(TerminalTheme.canvas.opacity(0.72), in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(TerminalTheme.cyan.opacity(0.24), lineWidth: 1)
        }
        .accessibilityLabel("Script to execute")
    }
}
