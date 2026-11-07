import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: .activateAllWindows)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct TerminalTabsApp: App {
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
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Tab Group") { store.newGroup() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Close Tab") { store.close() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Next Tab") { store.selectNext(delta: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { store.selectNext(delta: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button("Select Tab \(index + 1)") { store.select(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            CommandMenu("Tab Layout") {
                Button(store.isTabBarVisible ? "Hide Tab Bar" : "Show Tab Bar") {
                    store.isTabBarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Horizontal Tabs") { store.tabOrientation = .horizontal }
                Button("Vertical Tabs") { store.tabOrientation = .vertical }
            }
        }
    }
}

struct TerminalWindow: View {
    @ObservedObject var store: TerminalStore
    @State private var isRenamingGroup = false
    @State private var renameGroupID: UUID?
    @State private var groupNameDraft = ""

    var body: some View {
        Group {
            if store.isTabBarVisible && store.tabOrientation == .vertical {
                HStack(spacing: 0) {
                    VerticalTabSidebar(store: store, rename: beginRename)
                    terminal
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
        .background(Color(red: 0.075, green: 0.086, blue: 0.082))
        .onAppear {
            NSRunningApplication.current.activate(options: .activateAllWindows)
        }
        .alert("Rename Tab Group", isPresented: $isRenamingGroup) {
            TextField("Group name", text: $groupNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameGroupID { store.renameGroup(renameGroupID, to: groupNameDraft) }
            }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let selected = store.selected {
            TerminalCanvas(session: selected)
                .id(selected.id)
                .padding(10)
        }
    }

    private func beginRename(_ group: TerminalTabGroup) {
        renameGroupID = group.id
        groupNameDraft = group.name
        isRenamingGroup = true
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
                TabSettingsMenu(store: store)
                Spacer(minLength: 8)
            }
            .frame(height: 38)

            if store.selectedGroup?.isCollapsed == false {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(store.tabs) { tab in
                                TerminalTabButton(
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
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                }
            }
        }
        .background(Color(red: 0.105, green: 0.118, blue: 0.112))
    }
}

struct VerticalTabSidebar: View {
    @ObservedObject var store: TerminalStore
    let rename: (TerminalTabGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer().frame(width: 76)
                SmallIconButton(systemName: "folder.badge.plus", help: "New tab group") {
                    store.newGroup()
                }
                TabSettingsMenu(store: store)
            }
            .padding(.trailing, 8)
            .frame(height: 42)

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
                                Button("Rename Group") { rename(group) }
                                Button("Close Group", role: .destructive) { store.closeGroup(group.id) }
                            }

                            if !group.isCollapsed {
                                ForEach(group.tabs) { tab in
                                    TerminalTabButton(
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
        .frame(width: 238)
        .background(Color(red: 0.105, green: 0.118, blue: 0.112))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
        }
    }
}

struct CompactTitleBar: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        HStack {
            Spacer()
            TabSettingsMenu(store: store)
            Spacer().frame(width: 8)
        }
        .frame(height: 38)
        .background(Color(red: 0.105, green: 0.118, blue: 0.112))
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
        .background(selected ? Color.white.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(selected ? .primary : .secondary)
        .help(group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
        .contextMenu {
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group", action: toggleCollapsed)
            Button("Rename Group", action: rename)
            Button("Close Group", role: .destructive, action: close)
        }
    }
}

struct TabSettingsMenu: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        Menu {
            Picker("Tab orientation", selection: $store.tabOrientation) {
                Label("Horizontal", systemImage: "rectangle.split.3x1").tag(TabOrientation.horizontal)
                Label("Vertical", systemImage: "rectangle.split.1x2").tag(TabOrientation.vertical)
            }
            Divider()
            Toggle("Show tab bar", isOn: $store.isTabBarVisible)
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .foregroundStyle(.secondary)
        .help("Tab settings")
    }
}

struct SmallIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalSession
    let selected: Bool
    let vertical: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        }
        .foregroundStyle(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.52))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: vertical ? nil : 196, height: 38)
        .frame(maxWidth: vertical ? .infinity : nil)
        .background(selected ? Color.white.opacity(0.075) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Close Tab", action: close)
        }
        .padding(.horizontal, vertical ? 6 : 0)
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

