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
                .help("Select \(optionTitle(option))")
            }
        } label: {
            HStack(spacing: 0) {
                Text(optionTitle(selection))
                    .lineLimit(1)
                    .padding(.leading, 11)
                    .padding(.trailing, 10)
                Spacer(minLength: 8)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 1, height: 16)
                ZStack {
                    TerminalTheme.cyan.opacity(isHovering ? 0.16 : 0.09)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(isHovering ? TerminalTheme.cyan : TerminalTheme.cyanMuted)
                }
                .frame(width: 30, height: 28)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TerminalTheme.text)
            .frame(minWidth: minimumWidth)
            .frame(height: 30)
            .background(
                isHovering
                    ? TerminalTheme.raised
                    : TerminalTheme.raised.opacity(0.78),
                in: .rect(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
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
        .help("\(title): \(optionTitle(selection))")
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
    }
}
