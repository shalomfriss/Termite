import AppKit
import Combine
import Foundation
import GhosttyBridge

struct TerminalCommandBlock: Equatable {
    let command: String
    let workingDirectory: String
}

struct CommandLineTracker {
    private(set) var text = ""

    mutating func append(_ data: Data) {
        for byte in data {
            switch byte {
            case 0x7F, 0x08:
                if !text.isEmpty { text.removeLast() }
            case 0x20...0x7E:
                text.append(Character(UnicodeScalar(byte)))
            default:
                break
            }
        }
    }

    mutating func submit() -> String {
        defer { text = "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let handle: OpaquePointer?

    @Published var title = "Shell"
    @Published var workingDirectory = FileManager.default.currentDirectoryPath
    @Published var isRunning = true
    @Published var revision: UInt = 0
    let error: String?
    private(set) var commandBlocks: [TerminalCommandBlock] = []
    private var commandLine = CommandLineTracker()
    private var isMarkingInput = false

    init(cols: UInt16 = 100, rows: UInt16 = 32) {
        var message: UnsafePointer<CChar>?
        handle = gt_session_create(cols, rows, &message)
        error = message.map(String.init(cString:))
        isRunning = handle != nil
        refreshFrame()
    }

    isolated deinit {
        if let handle { gt_session_destroy(handle) }
    }

    func poll() {
        guard let handle else { return }
        if gt_session_poll(handle) {
            revision &+= 1
            refreshFrame()
        }
        isRunning = gt_session_is_running(handle)
    }

    func refreshFrame() {
        guard let handle, let frame = gt_session_frame(handle) else { return }
        if let pointer = frame.pointee.title {
            let value = String(cString: pointer).unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && !(0x202A...0x202E).contains(scalar.value)
                    && !(0x2066...0x2069).contains(scalar.value)
            }.map(String.init).joined()
            title = value.isEmpty ? "Shell" : value
        }
        if let pointer = frame.pointee.working_directory {
            let value = String(cString: pointer)
            if !value.isEmpty {
                let decoded = value.removingPercentEncoding ?? value
                if let url = URL(string: decoded), url.isFileURL {
                    workingDirectory = url.path
                } else {
                    workingDirectory = decoded
                }
            }
        }
    }

    func write(_ data: Data) {
        guard let handle else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_write(handle, base, data.count)
        }
    }

    func sendUserInput(_ data: Data) {
        guard let handle else { return }
        _ = gt_session_scroll_to_bottom(handle)
        var pending = Data()
        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                sendPendingInput(pending, handle: handle)
                pending.removeAll(keepingCapacity: true)
                submitCommand(byte, handle: handle)
            } else {
                pending.append(byte)
            }
        }
        sendPendingInput(pending, handle: handle)
    }

    private func sendPendingInput(_ data: Data, handle: OpaquePointer) {
        guard !data.isEmpty else { return }
        if !isMarkingInput {
            gt_session_mark_input(handle)
            isMarkingInput = true
            revision &+= 1
        }
        commandLine.append(data)
        write(data)
    }

    private func submitCommand(_ byte: UInt8, handle: OpaquePointer) {
        if isMarkingInput {
            // Drain the PTY first so the shell's echoed command remains tagged as input.
            if gt_session_poll(handle) { refreshFrame() }
            let command = commandLine.submit()
            if !command.isEmpty {
                commandBlocks.append(.init(command: command, workingDirectory: workingDirectory))
            }
            gt_session_mark_output(handle)
            revision &+= 1
        }
        isMarkingInput = false
        write(Data([byte]))
    }

    func workingDirectory(for command: String) -> String {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return commandBlocks.last(where: { $0.command == normalized })?.workingDirectory
            ?? workingDirectory
    }

    func scroll(rows: Int) {
        guard let handle, rows != 0 else { return }
        if gt_session_scroll(handle, rows) {
            revision &+= 1
            refreshFrame()
        }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard let handle else { return }
        _ = gt_session_resize(handle, cols, rows, cellWidth, cellHeight)
        revision &+= 1
    }
}

enum TabOrientation: String, CaseIterable {
    case horizontal
    case vertical
}

struct TerminalTabGroup: Identifiable {
    let id: UUID
    var name: String
    var tabs: [TerminalSession]
    var isCollapsed: Bool

    init(
        id: UUID = UUID(),
        name: String,
        tabs: [TerminalSession] = [],
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.isCollapsed = isCollapsed
    }
}

@MainActor
final class TerminalStore: ObservableObject {
    private static let orientationKey = "tabOrientation"
    private static let tabBarVisibilityKey = "isTabBarVisible"

    @Published var groups: [TerminalTabGroup] = []
    @Published var selectedGroupID: UUID?
    @Published var selectedID: UUID?
    @Published var tabOrientation: TabOrientation {
        didSet { UserDefaults.standard.set(tabOrientation.rawValue, forKey: Self.orientationKey) }
    }
    @Published var isTabBarVisible: Bool {
        didSet { UserDefaults.standard.set(isTabBarVisible, forKey: Self.tabBarVisibilityKey) }
    }
    private var timer: Timer?

    init() {
        tabOrientation = TabOrientation(
            rawValue: UserDefaults.standard.string(forKey: Self.orientationKey) ?? ""
        ) ?? .horizontal
        if UserDefaults.standard.object(forKey: Self.tabBarVisibilityKey) == nil {
            isTabBarVisible = true
        } else {
            isTabBarVisible = UserDefaults.standard.bool(forKey: Self.tabBarVisibilityKey)
        }
        newGroup()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    var selectedGroup: TerminalTabGroup? {
        groups.first { $0.id == selectedGroupID }
    }

    var tabs: [TerminalSession] {
        selectedGroup?.tabs ?? []
    }

    var selected: TerminalSession? {
        groups.lazy.flatMap(\.tabs).first { $0.id == selectedID }
    }

    func newGroup() {
        let usedNumbers = Set(groups.compactMap { group -> Int? in
            guard group.name.hasPrefix("Group ") else { return nil }
            return Int(group.name.dropFirst("Group ".count))
        })
        let number = (1...).first { !usedNumbers.contains($0) } ?? groups.count + 1
        let tab = TerminalSession()
        let group = TerminalTabGroup(name: "Group \(number)", tabs: [tab])
        groups.append(group)
        selectedGroupID = group.id
        selectedID = tab.id
    }

    func newTab(in groupID: UUID? = nil) {
        guard let index = groupIndex(for: groupID ?? selectedGroupID) else {
            newGroup()
            return
        }
        let tab = TerminalSession()
        groups[index].tabs.append(tab)
        groups[index].isCollapsed = false
        selectedGroupID = groups[index].id
        selectedID = tab.id
    }

    func selectGroup(_ id: UUID) {
        guard let index = groupIndex(for: id) else { return }
        selectedGroupID = id
        if !groups[index].tabs.contains(where: { $0.id == selectedID }) {
            selectedID = groups[index].tabs.first?.id
        }
    }

    func selectAndToggleGroup(_ id: UUID) {
        selectGroup(id)
        toggleGroupCollapsed(id)
    }

    func close(_ id: UUID? = nil) {
        let target = id ?? selectedID
        guard let target,
              let groupIndex = groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == target }) }),
              let tabIndex = groups[groupIndex].tabs.firstIndex(where: { $0.id == target }) else { return }
        groups[groupIndex].tabs.remove(at: tabIndex)

        if groups[groupIndex].tabs.isEmpty {
            if groups.count == 1 {
                let replacement = TerminalSession()
                groups[groupIndex].tabs = [replacement]
                selectedGroupID = groups[groupIndex].id
                selectedID = replacement.id
            } else {
                closeGroup(groups[groupIndex].id)
            }
        } else if selectedID == target {
            selectedGroupID = groups[groupIndex].id
            selectedID = groups[groupIndex].tabs[min(tabIndex, groups[groupIndex].tabs.count - 1)].id
        }
    }

    func closeGroup(_ id: UUID) {
        guard let index = groupIndex(for: id) else { return }
        if groups.count == 1 {
            groups.removeAll()
            newGroup()
            return
        }
        let wasSelected = selectedGroupID == id
        groups.remove(at: index)
        if wasSelected {
            let next = groups[min(index, groups.count - 1)]
            selectedGroupID = next.id
            selectedID = next.tabs.first?.id
        }
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let index = groupIndex(for: id) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        groups[index].name = cleaned
    }

    func toggleGroupCollapsed(_ id: UUID) {
        guard let index = groupIndex(for: id) else { return }
        groups[index].isCollapsed.toggle()
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func selectNext(delta: Int) {
        guard let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        let next = (index + delta + tabs.count) % tabs.count
        self.selectedID = tabs[next].id
    }

    private func poll() {
        for tab in groups.lazy.flatMap(\.tabs) { tab.poll() }
    }

    private func groupIndex(for id: UUID?) -> Int? {
        guard let id else { return nil }
        return groups.firstIndex { $0.id == id }
    }
}

enum TerminalInput {
    static func sequence(for event: NSEvent) -> Data? {
        switch event.keyCode {
        case 36, 76: return Data([13])
        case 48: return Data([9])
        case 51: return Data([127])
        case 53: return Data([27])
        case 117: return Data("\u{1B}[3~".utf8)
        case 123: return Data("\u{1B}[D".utf8)
        case 124: return Data("\u{1B}[C".utf8)
        case 125: return Data("\u{1B}[B".utf8)
        case 126: return Data("\u{1B}[A".utf8)
        case 115: return Data("\u{1B}[H".utf8)
        case 119: return Data("\u{1B}[F".utf8)
        case 116: return Data("\u{1B}[5~".utf8)
        case 121: return Data("\u{1B}[6~".utf8)
        default:
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            return Data(characters.utf8)
        }
    }
}
