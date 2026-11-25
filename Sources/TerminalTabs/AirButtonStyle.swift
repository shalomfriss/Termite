import SwiftUI

struct AirButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
        case destructive
    }

    let emphasis: Emphasis

    func makeBody(configuration: Configuration) -> some View {
        AirButtonStyleBody(
            label: configuration.label,
            emphasis: emphasis,
            isPressed: configuration.isPressed
        )
    }
}

private struct AirButtonStyleBody<Label: View>: View {
    let label: Label
    let emphasis: AirButtonStyle.Emphasis
    let isPressed: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(background, in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(border, lineWidth: 1)
            }
            .shadow(
                color: emphasis == .primary && isHovering
                    ? TerminalTheme.cyan.opacity(0.22)
                    : .clear,
                radius: 8
            )
            .contentShape(.rect)
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: TerminalTheme.canvas
        case .secondary, .destructive: TerminalTheme.text
        }
    }

    private var background: Color {
        switch emphasis {
        case .primary:
            isPressed ? TerminalTheme.cyan.opacity(0.78) : TerminalTheme.cyan
        case .secondary:
            isHovering ? TerminalTheme.raised : TerminalTheme.raised.opacity(0.72)
        case .destructive:
            TerminalTheme.danger.opacity(isHovering ? 0.24 : 0.14)
        }
    }

    private var border: Color {
        switch emphasis {
        case .primary: .white.opacity(isHovering ? 0.34 : 0.20)
        case .secondary:
            isHovering ? TerminalTheme.cyan.opacity(0.42) : .white.opacity(0.10)
        case .destructive:
            TerminalTheme.danger.opacity(isHovering ? 0.72 : 0.42)
        }
    }
}

extension ButtonStyle where Self == AirButtonStyle {
    static var airPrimary: AirButtonStyle { AirButtonStyle(emphasis: .primary) }
    static var airSecondary: AirButtonStyle { AirButtonStyle(emphasis: .secondary) }
    static var airDestructive: AirButtonStyle { AirButtonStyle(emphasis: .destructive) }
}

struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct ToolbarIconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .foregroundStyle(isHovering || isPressed ? TerminalTheme.text : TerminalTheme.cyanMuted)
            .frame(width: 28, height: 28)
            .background(background, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .scaleEffect(isPressed ? 0.93 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.10), value: isHovering)
            .animation(.easeOut(duration: 0.07), value: isPressed)
    }

    private var background: Color {
        if isPressed { return .white.opacity(0.13) }
        if isHovering { return .white.opacity(0.08) }
        return .white.opacity(0.04)
    }
}

extension ButtonStyle where Self == ToolbarIconButtonStyle {
    static var toolbarIcon: ToolbarIconButtonStyle { ToolbarIconButtonStyle() }
}
