import SwiftUI

struct GraphicalViewPicker: View {
    @Binding var selection: GraphicalViewMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GraphicalViewMode.allCases) { mode in
                Button(mode.title, systemImage: mode.systemImage) {
                    selection = mode
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(selection == mode ? .primary : .secondary)
                .frame(width: 28, height: 22)
                .background(
                    selection == mode ? TerminalTheme.raised : .clear,
                    in: .rect(cornerRadius: 5)
                )
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .help("\(mode.title) view")
            }
        }
        .padding(3)
        .background(.thinMaterial, in: .rect(cornerRadius: 7))
    }
}
