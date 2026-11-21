import SwiftUI

struct TerminalBookmarksMenu: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Menu {
            if session.terminalBlockBookmarks.isEmpty {
                Button("No bookmarked blocks") {}
                    .disabled(true)
            } else {
                Section("Bookmarked Blocks") {
                    ForEach(session.terminalBlockBookmarks) { bookmark in
                        Button(
                            bookmark.title,
                            systemImage: "arrowshape.turn.up.left.fill"
                        ) {
                            session.revealTerminalBlock(bookmark)
                        }
                        .help("Open in \(bookmark.workingDirectory)")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: session.terminalBlockBookmarks.isEmpty
                      ? "bookmark"
                      : "bookmark.fill")
                Text(session.terminalBlockBookmarks.count, format: .number)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(TerminalTheme.cyanMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(TerminalTheme.cyan.opacity(0.08), in: .capsule)
            .overlay {
                Capsule().stroke(TerminalTheme.cyan.opacity(0.15), lineWidth: 1)
            }
            .contentShape(.capsule)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open bookmarked terminal blocks")
        .accessibilityLabel("Terminal block bookmarks")
        .accessibilityValue("\(session.terminalBlockBookmarks.count) bookmarks")
        .accessibilityHint("Opens a menu of bookmarked terminal blocks")
    }
}
