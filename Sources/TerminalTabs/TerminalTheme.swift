import SwiftUI

enum TerminalTheme {
    static let canvas = Color(red: 0.035, green: 0.039, blue: 0.045)
    static let surface = Color(red: 0.055, green: 0.061, blue: 0.070)
    static let raised = Color(red: 0.085, green: 0.093, blue: 0.105)
    static let cyan = Color(red: 0.80, green: 0.83, blue: 0.86)
    static let cyanMuted = Color(red: 0.58, green: 0.62, blue: 0.67)
    static let green = Color(red: 0.48, green: 0.72, blue: 0.50)
    static let text = Color(red: 0.91, green: 0.91, blue: 0.89)
    static let mutedText = Color(red: 0.57, green: 0.59, blue: 0.62)
    static let danger = Color(red: 0.95, green: 0.30, blue: 0.37)
    static let border = Color.white.opacity(0.085)
    static let subtleFill = Color.white.opacity(0.045)
    static let hoverFill = Color.white.opacity(0.075)

    static var backdrop: some View {
        canvas
    }
}
