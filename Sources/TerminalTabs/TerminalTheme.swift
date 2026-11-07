import SwiftUI

enum TerminalTheme {
    static let canvas = Color(red: 0.025, green: 0.065, blue: 0.088)
    static let surface = Color(red: 0.035, green: 0.094, blue: 0.122)
    static let raised = Color(red: 0.047, green: 0.125, blue: 0.153)
    static let cyan = Color(red: 0.32, green: 0.84, blue: 0.88)
    static let cyanMuted = Color(red: 0.24, green: 0.59, blue: 0.66)
    static let green = Color(red: 0.35, green: 0.82, blue: 0.39)
    static let text = Color(red: 0.82, green: 0.88, blue: 0.92)
    static let mutedText = Color(red: 0.50, green: 0.65, blue: 0.71)
    static let danger = Color(red: 0.95, green: 0.30, blue: 0.37)

    static var backdrop: some View {
        RadialGradient(
            colors: [surface, canvas],
            center: .top,
            startRadius: 20,
            endRadius: 720
        )
    }
}
