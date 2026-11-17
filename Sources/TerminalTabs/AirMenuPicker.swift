import SwiftUI

struct AirMenuPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let minimumWidth: CGFloat
    let optionTitle: (Option) -> String

    @State private var isHovering = false

    init(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        minimumWidth: CGFloat = 124,
        optionTitle: @escaping (Option) -> String
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.minimumWidth = minimumWidth
        self.optionTitle = optionTitle
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(optionTitle(option), systemImage: "checkmark")
                    } else {
                        Text(optionTitle(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(optionTitle(selection))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(TerminalTheme.cyanMuted)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TerminalTheme.text)
            .padding(.horizontal, 10)
            .frame(minWidth: minimumWidth)
            .frame(height: 28)
            .background(
                isHovering
                    ? TerminalTheme.raised
                    : TerminalTheme.raised.opacity(0.72),
                in: .rect(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isHovering
                            ? TerminalTheme.cyan.opacity(0.42)
                            : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            }
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
    }
}
