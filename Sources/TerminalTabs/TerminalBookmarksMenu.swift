import SwiftUI

struct TerminalBookmarksMenu: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Menu {
            if session.terminalBlockBookmarks.isEmpty {
                Button("No saved commands") {}
                    .disabled(true)
            } else {
                Section("Saved Commands") {
                    ForEach(session.terminalBlockBookmarks) { bookmark in
                        Menu(bookmark.title) {
                            Button("Run", systemImage: "arrow.forward.circle") {
                                session.rerunBlockCommand(bookmark.command)
                            }
                            .help("Run: \(bookmark.command)")
                            Divider()
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                session.toggleTerminalBlockBookmarked(
                                    bookmark.id,
                                    command: bookmark.command,
                                    output: bookmark.output,
                                    workingDirectory: bookmark.workingDirectory
                                )
                            }
                            .help("Remove \"\(bookmark.title)\" from saved commands")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: session.terminalBlockBookmarks.isEmpty ? "bookmark" : "bookmark.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.toolbarIcon)
        .fixedSize()
        .help("Saved commands")
        .accessibilityLabel("Saved commands")
        .accessibilityValue("\(session.terminalBlockBookmarks.count) saved")
    }
}
