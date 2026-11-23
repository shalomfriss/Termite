import SwiftUI

struct GraphicalPreviewDisclosureButton: View {
    let item: GraphicalFileItem
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            VStack(spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass")
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
            }
            .frame(width: 30, height: 58)
            .foregroundStyle(TerminalTheme.cyan)
            .background(TerminalTheme.surface.opacity(0.96))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 9,
                    bottomLeadingRadius: 9
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 9,
                    bottomLeadingRadius: 9
                )
                .stroke(TerminalTheme.cyan.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.26), radius: 8, x: -3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show preview for \(item.name)")
        .help("Show preview for \(item.name)")
    }
}
