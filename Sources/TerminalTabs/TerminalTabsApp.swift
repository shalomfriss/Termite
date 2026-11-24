import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await Task.yield()
            NSRunningApplication.current.activate(options: .activateAllWindows)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct AirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TerminalStore()

    var body: some Scene {
        WindowGroup {
            TerminalWindow(store: store)
                .frame(minWidth: 720, minHeight: 440)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.isSettingsVisible = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Open Air settings")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("Create a new terminal tab")
                Button("New Tab Group") { store.newGroup() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .help("Create a new tab group")
            }
            CommandGroup(after: .newItem) {
                Button("Close Tab") { store.close() }
                    .keyboardShortcut("w", modifiers: .command)
                    .help("Close the current tab")
                Button("Next Tab") { store.selectNext(delta: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .help("Select the next tab")
                Button("Previous Tab") { store.selectNext(delta: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .help("Select the previous tab")
                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button("Select Tab \(index + 1)") { store.select(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .help("Select tab \(index + 1)")
                }
            }
            CommandMenu("Tab Layout") {
                Button(store.tabPanelVisibilityActionTitle) {
                    store.isTabBarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .help(store.tabPanelVisibilityActionTitle)
                Divider()
                Button("Horizontal Tabs") { store.tabOrientation = .horizontal }
                    .help("Place tab groups across the top")
                Button("Vertical Tabs") { store.tabOrientation = .vertical }
                    .help("Place tab groups in the side panel")
            }
            CommandMenu("AI") {
                Button("Open AI Chat") {
                    store.selected?.isAIChatVisible = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Open Terminal AI")
                Button("Clear AI Conversation") {
                    store.selected?.clearAIConversation()
                }
                .help("Clear messages from Terminal AI")
            }
            CommandMenu("Jobs") {
                Button("Scheduled Jobs…", systemImage: "clock") {
                    store.isScheduledJobsVisible = true
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .help("Open Jobs & Workflows")
            }
        }
    }
}

struct TerminalWindow: View {
    @ObservedObject var store: TerminalStore
    @State private var isRenamingGroup = false
    @State private var renameGroupID: UUID?
    @State private var groupNameDraft = ""
    @State private var verticalPanelWidth: CGFloat = 238
    @State private var verticalPanelDragStartWidth: CGFloat?

    var body: some View {
        Group {
            if store.tabOrientation == .vertical {
                VStack(spacing: 0) {
                    VerticalPanelHeader(store: store)
                    HStack(spacing: 0) {
                        if store.isTabBarVisible {
                            VerticalTabSidebar(store: store, rename: beginRename)
                                .frame(width: verticalPanelWidth)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            VerticalPanelResizeHandle()
                                .gesture(verticalPanelResizeGesture)
                                .transition(.opacity)
                        }
                        terminal
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if store.isTabBarVisible {
                        HorizontalTabBar(store: store, rename: beginRename)
                    } else {
                        CompactTitleBar(store: store)
                    }
                    terminal
                }
            }
        }
        .background(TerminalTheme.backdrop)
        .animation(.smooth(duration: 0.22), value: store.isTabBarVisible)
        .onAppear {
            NSRunningApplication.current.activate(options: .activateAllWindows)
        }
        .alert("Rename Tab Group", isPresented: $isRenamingGroup) {
            TextField("Group name", text: $groupNameDraft)
            Button("Cancel", role: .cancel) {}
                .help("Cancel renaming this tab group")
            Button("Rename") {
                if let renameGroupID { store.renameGroup(renameGroupID, to: groupNameDraft) }
            }
            .help("Save the new tab group name")
        }
        .sheet(isPresented: $store.isSettingsVisible) {
            AppSettingsView(store: store, settings: store.aiSettings)
        }
        .sheet(isPresented: $store.isScheduledJobsVisible) {
            ScheduledJobsView(store: store)
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let selected = store.selected {
            TerminalWorkspace(session: selected, store: store, settings: store.aiSettings)
                .padding(10)
        }
    }

    private func beginRename(_ group: TerminalTabGroup) {
        renameGroupID = group.id
        groupNameDraft = group.name
        isRenamingGroup = true
    }

    private var verticalPanelResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if verticalPanelDragStartWidth == nil {
                    verticalPanelDragStartWidth = verticalPanelWidth
                }
                verticalPanelWidth = min(
                    420,
                    max(180, (verticalPanelDragStartWidth ?? verticalPanelWidth) + value.translation.width)
                )
            }
            .onEnded { _ in
                verticalPanelDragStartWidth = nil
            }
    }
}

struct VerticalPanelHeader: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.isTabBarVisible.toggle()
            } label: {
                Label(store.selected?.title ?? "Shell", systemImage: "terminal")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .bold()
            .foregroundStyle(TerminalTheme.text)
            .help(store.tabPanelVisibilityActionTitle)
            .accessibilityLabel(store.tabPanelVisibilityActionTitle)
            Spacer()
        }
        .padding(.leading, 72)
        .padding(.trailing, 14)
        .frame(height: 60)
        .background(TerminalTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TerminalTheme.border).frame(height: 1)
        }
    }
}

struct VerticalPanelResizeHandle: View {
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? TerminalTheme.cyan.opacity(0.42) : TerminalTheme.cyan.opacity(0.16))
            .frame(width: 4)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { isHovering = $0 }
            .help("Resize side panel")
    }
}

struct TerminalWorkspace: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: TerminalStore
    @ObservedObject var settings: AISettings

    var body: some View {
        VStack(spacing: 9) {
            GraphicalModeToolbar(
                session: session,
                isEnabled: $store.graphicalMode,
                viewMode: $store.graphicalViewMode,
                showsHiddenFiles: $store.graphicalShowsHiddenFiles,
                sortOption: $store.graphicalSortOption,
                groupOption: $store.graphicalGroupOption,
                sortDirection: $store.graphicalSortDirection,
                foldersFirst: $store.graphicalFoldersFirst
            )

            if session.isAIChatVisible {
                ResizableTerminalAIPane(
                    session: session,
                    store: store,
                    settings: settings,
                    openDirectoryInNewTab: { directory in
                        store.newTab(startingIn: directory.path)
                    }
                )
            } else {
                TerminalSurface(
                    session: session,
                    store: store,
                    openDirectoryInNewTab: { directory in
                        store.newTab(startingIn: directory.path)
                    }
                )
            }
        }
    }

}

struct HorizontalTabBar: View {
    @ObservedObject var store: TerminalStore
    let rename: (TerminalTabGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer().frame(width: 76)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.groups) { group in
                            GroupButton(
                                group: group,
                                selected: group.id == store.selectedGroupID,
                                select: { store.selectAndToggleGroup(group.id) },
                                toggleCollapsed: { store.toggleGroupCollapsed(group.id) },
                                rename: { rename(group) },
                                close: { store.closeGroup(group.id) }
                            )
                        }
                    }
                }
                SmallIconButton(systemName: "folder.badge.plus", help: "New tab group") {
                    store.newGroup()
                }
                SmallIconButton(systemName: "plus", help: "New tab (Command-T)") {
                    store.newTab()
                }
                ScheduledJobsButton(store: store)
                TabSettingsMenu(store: store)
                SmallIconButton(
                    systemName: store.tabOrientation.panelSystemImage,
                    help: "Hide top panel"
                ) {
                    store.isTabBarVisible = false
                }
                Spacer(minLength: 8)
            }
            .frame(height: 38)

            if store.selectedGroup?.isCollapsed == false {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(store.tabs) { tab in
                                ReorderableTerminalTabButton(
                                    store: store,
                                    groupID: store.selectedGroupID,
                                    tab: tab,
                                    selected: tab.id == store.selectedID,
                                    vertical: false,
                                    select: { store.selectedID = tab.id },
                                    close: { store.close(tab.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    Spacer(minLength: 8)
                }
                .frame(height: 44)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(TerminalTheme.cyan.opacity(0.22)).frame(height: 1)
                }
            }
        }
        .background(TerminalTheme.surface)
    }
}

struct VerticalTabSidebar: View {
    @ObservedObject var store: TerminalStore
    let rename: (TerminalTabGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SmallIconButton(systemName: "folder.badge.plus", help: "New tab group") {
                    store.newGroup()
                }
                ScheduledJobsButton(store: store)
                TabSettingsMenu(store: store)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TerminalTheme.border).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.groups) { group in
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Button {
                                    store.selectAndToggleGroup(group.id)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                            .frame(width: 12)
                                        Image(systemName: group.id == store.selectedGroupID ? "folder.fill" : "folder")
                                        Text(group.name).lineLimit(1)
                                    }
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(group.id == store.selectedGroupID ? .primary : .secondary)
                                .help(group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
                                SmallIconButton(systemName: "plus", help: "New tab in \(group.name)") {
                                    store.newTab(in: group.id)
                                }
                            }
                            .padding(.horizontal, 10)
                            .contextMenu {
                                Button(group.isCollapsed ? "Expand Group" : "Collapse Group") {
                                    store.toggleGroupCollapsed(group.id)
                                }
                                .help(group.isCollapsed ? "Expand this tab group" : "Collapse this tab group")
                                Button("Rename Group") { rename(group) }
                                    .help("Rename this tab group")
                                Button("Close Group", role: .destructive) { store.closeGroup(group.id) }
                                    .help("Close this tab group and its tabs")
                            }

                            if !group.isCollapsed {
                                ForEach(group.tabs) { tab in
                                    ReorderableTerminalTabButton(
                                        store: store,
                                        groupID: group.id,
                                        tab: tab,
                                        selected: tab.id == store.selectedID,
                                        vertical: true,
                                        select: {
                                            store.selectGroup(group.id)
                                            store.selectedID = tab.id
                                        },
                                        close: { store.close(tab.id) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .background(TerminalTheme.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(TerminalTheme.border).frame(width: 1)
        }
    }
}

struct CompactTitleBar: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 76)
            Button(
                store.tabPanelVisibilityActionTitle,
                systemImage: store.tabOrientation.panelSystemImage
            ) {
                store.isTabBarVisible = true
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(TerminalTheme.cyanMuted)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(TerminalTheme.raised.opacity(0.62), in: .rect(cornerRadius: 7))
            .help(store.tabPanelVisibilityActionTitle)
            Spacer()
            ScheduledJobsButton(store: store)
            TabSettingsMenu(store: store)
            Spacer().frame(width: 8)
        }
        .frame(height: 38)
        .background(TerminalTheme.surface)
    }
}

struct GroupButton: View {
    let group: TerminalTabGroup
    let selected: Bool
    let select: () -> Void
    let toggleCollapsed: () -> Void
    let rename: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                Image(systemName: selected ? "folder.fill" : "folder")
                Text(group.name).lineLimit(1)
                Text("\(group.tabs.count)").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? TerminalTheme.cyan.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(selected ? TerminalTheme.text : TerminalTheme.mutedText)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(TerminalTheme.cyan.opacity(0.34), lineWidth: 1)
            }
        }
        .help(group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
        .contextMenu {
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group", action: toggleCollapsed)
                .help(group.isCollapsed ? "Expand this tab group" : "Collapse this tab group")
            Button("Rename Group", action: rename)
                .help("Rename this tab group")
            Button("Close Group", role: .destructive, action: close)
                .help("Close this tab group and its tabs")
        }
    }
}

struct TabSettingsMenu: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        Button("Settings", systemImage: "gearshape") {
            store.isSettingsVisible = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .foregroundStyle(TerminalTheme.cyanMuted)
        .help("Settings")
    }
}

struct SmallIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(help, systemImage: systemName, action: action)
        .labelStyle(.iconOnly)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .foregroundStyle(TerminalTheme.cyanMuted)
        .help(help)
    }
}

struct ReorderableTerminalTabButton: View {
    @ObservedObject var store: TerminalStore
    let groupID: UUID?
    @ObservedObject var tab: TerminalSession
    let selected: Bool
    let vertical: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isDropTarget = false

    var body: some View {
        TerminalTabButton(
            tab: tab,
            selected: selected,
            vertical: vertical,
            select: select,
            close: close
        )
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(TerminalTheme.cyan, lineWidth: 2)
                    .padding(.horizontal, vertical ? 6 : 0)
                    .allowsHitTesting(false)
            }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let groupID,
                  let value = values.first,
                  let sourceID = UUID(uuidString: value)
            else { return false }
            return store.moveTab(sourceID, to: tab.id, in: groupID)
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
    }
}

struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalSession
    @State private var isRenaming = false
    @State private var titleDraft = ""
    @FocusState private var isTitleFocused: Bool
    let selected: Bool
    let vertical: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Tab name", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .focused($isTitleFocused)
                        .onSubmit { finishRename() }
                        .onExitCommand { cancelRename() }
                        .onChange(of: isTitleFocused) {
                            if !isTitleFocused && isRenaming { finishRename() }
                        }
                } else {
                    Text(tab.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .highPriorityGesture(
                            TapGesture(count: 2).onEnded { beginRename() }
                        )
                        .help("Double-click to rename")
                }
                Text(displayDirectory)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close \(tab.title)")
        }
        .foregroundStyle(selected ? TerminalTheme.text : TerminalTheme.mutedText)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: vertical ? nil : 196, height: 38)
        .frame(maxWidth: vertical ? .infinity : nil)
        .background {
            if vertical, let accent = tab.tabAccentColor {
                Color(nsColor: accent).opacity(selected ? 0.22 : 0.11)
            } else {
                selected ? TerminalTheme.cyan.opacity(0.105) : Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            if vertical, let accent = tab.tabAccentColor {
                Capsule()
                    .fill(Color(nsColor: accent))
                    .frame(width: 3, height: 22)
                    .padding(.leading, 4)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(TerminalTheme.cyan.opacity(0.34), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Rename Tab", action: beginRename)
                .help("Rename this tab")
            Button("Close Tab", action: close)
                .help("Close this tab")
        }
        .padding(.horizontal, vertical ? 6 : 0)
    }

    private func beginRename() {
        select()
        titleDraft = tab.title
        isRenaming = true
        Task { @MainActor in
            await Task.yield()
            isTitleFocused = true
        }
    }

    private func finishRename() {
        guard isRenaming else { return }
        tab.rename(to: titleDraft)
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
        isTitleFocused = false
    }

    private var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if tab.workingDirectory == home { return "~" }
        if tab.workingDirectory.hasPrefix(home + "/") {
            return "~" + tab.workingDirectory.dropFirst(home.count)
        }
        return tab.workingDirectory
    }
}

