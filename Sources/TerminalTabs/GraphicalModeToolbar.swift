import SwiftUI

struct GraphicalModeToolbar: View {
    @ObservedObject var session: TerminalSession
    @Binding var isEnabled: Bool
    @Binding var viewMode: GraphicalViewMode
    @Binding var showsHiddenFiles: Bool
    @Binding var sortOption: GraphicalSortOption
    @Binding var groupOption: GraphicalGroupOption
    @Binding var sortDirection: GraphicalSortDirection
    @Binding var foldersFirst: Bool
    @State private var isNewFolderPopoverPresented = false
    @State private var isToggleHovering = false
    @State private var isSortMenuHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isEnabled) {
                Label("Graphical", systemImage: "square.grid.2x2")
                    .font(.callout)
                    .bold()
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? TerminalTheme.canvas : TerminalTheme.text)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                isEnabled
                    ? TerminalTheme.cyan
                    : (isToggleHovering ? TerminalTheme.hoverFill : TerminalTheme.subtleFill),
                in: .rect(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isEnabled ? TerminalTheme.cyan.opacity(0.6) : TerminalTheme.border, lineWidth: 1)
            }
            .onHover { isToggleHovering = $0 }
            .animation(.easeOut(duration: 0.10), value: isToggleHovering)
            .help(isEnabled ? "Turn off graphical mode" : "Browse directories graphically")

            if isEnabled {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: 22)

                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TerminalTheme.text)

                VStack(alignment: .leading, spacing: 1) {
                    Text(directoryName)
                        .font(.callout)
                        .bold()
                        .foregroundStyle(TerminalTheme.text)
                        .lineLimit(1)
                    Text(directorySubtitle)
                        .font(.caption)
                        .foregroundStyle(TerminalTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(session.workingDirectory)

                Spacer(minLength: 12)

                if let count = session.graphicalItemCount {
                    Text("^[\(count) item](inflect: true)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(TerminalTheme.mutedText)
                }

                if session.isGraphicalNavigationInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .help("Opening folder…")
                }

                Button("Attach listing to AI Chat", systemImage: "paperclip") {
                    session.attachGraphicalOutputToAI()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.toolbarIcon)
                .disabled(!session.canAttachGraphicalOutputToAI)
                .help("Attach directory listing to AI Chat")

                Button("Refresh directory", systemImage: "arrow.clockwise") {
                    session.showCurrentDirectoryGraphically()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.toolbarIcon)
                .disabled(session.isGraphicalNavigationInProgress)
                .help("Refresh directory")

                Button("New folder", systemImage: "folder.badge.plus") {
                    isNewFolderPopoverPresented = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.toolbarIcon)
                .disabled(session.isGraphicalNavigationInProgress)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder (Shift-Command-N)")
                .popover(isPresented: $isNewFolderPopoverPresented, arrowEdge: .bottom) {
                    NewFolderPopover(suggestedName: session.suggestedGraphicalFolderName) { name in
                        try session.createGraphicalFolder(named: name)
                    }
                }

                Menu {
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(GraphicalSortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Picker("Group By", selection: $groupOption) {
                        ForEach(GraphicalGroupOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Divider()
                    Picker("Direction", selection: $sortDirection) {
                        ForEach(GraphicalSortDirection.allCases) { direction in
                            Label(direction.title, systemImage: direction.systemImage)
                                .tag(direction)
                        }
                    }
                    Toggle("Keep Folders on Top", isOn: $foldersFirst)
                } label: {
                    Image(systemName: "square.grid.3x3.square")
                        .foregroundStyle(isSortMenuHovering ? TerminalTheme.text : TerminalTheme.cyanMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .fixedSize()
                .background(
                    isSortMenuHovering ? .white.opacity(0.08) : .white.opacity(0.04),
                    in: .rect(cornerRadius: 6)
                )
                .onHover { isSortMenuHovering = $0 }
                .animation(.easeOut(duration: 0.10), value: isSortMenuHovering)
                .help("Arrange and group items")

                Toggle("Show hidden files", isOn: $showsHiddenFiles)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(TerminalTheme.mutedText)
                    .fixedSize()
                    .help("Show files and folders whose names begin with a period")

                GraphicalViewPicker(selection: $viewMode)
            } else {
                Text("Clickable files, native menus, and directory previews")
                    .font(.callout)
                    .foregroundStyle(TerminalTheme.mutedText)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 46)
        .background(TerminalTheme.surface, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(TerminalTheme.border, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isEnabled)
        .alert(item: $session.graphicalOperationIssue) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var directoryName: String {
        let name = URL(fileURLWithPath: session.workingDirectory, isDirectory: true).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    private var directorySubtitle: String {
        let parent = URL(fileURLWithPath: session.workingDirectory, isDirectory: true)
            .deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}
