import SwiftUI

struct GraphicalViewPicker: View {
    @Binding var selection: GraphicalViewMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(GraphicalViewMode.allCases) { mode in
                ModeButton(mode: mode, isSelected: selection == mode) {
                    selection = mode
                }
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

private struct ModeButton: View {
    let mode: GraphicalViewMode
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: mode.systemImage)
                .frame(width: 30, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(foreground)
        .background(background, in: .rect(cornerRadius: 7))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
        }
        .contentShape(.rect)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .help("\(mode.title) view")
    }

    private var foreground: Color {
        if isSelected { return TerminalTheme.canvas }
        return isHovering ? TerminalTheme.text : TerminalTheme.mutedText
    }

    private var background: Color {
        if isSelected { return TerminalTheme.cyan }
        return isHovering ? .white.opacity(0.08) : .clear
    }
}
