import SwiftUI

struct GraphicalViewPicker: View {
    @Binding var selection: GraphicalViewMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(GraphicalViewMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Image(systemName: mode.systemImage)
                        .frame(width: 30, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selection == mode ? TerminalTheme.canvas : TerminalTheme.mutedText)
                .background(
                    selection == mode ? TerminalTheme.cyan : .clear,
                    in: .rect(cornerRadius: 7)
                )
                .overlay {
                    if selection == mode {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    }
                }
                .contentShape(.rect)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .help("\(mode.title) view")
            }
        }
        .padding(3)
        .background(TerminalTheme.canvas.opacity(0.72), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }
}
