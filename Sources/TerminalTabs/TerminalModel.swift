import AppKit
import Combine
import Darwin
import Foundation
import GhosttyBridge

struct TerminalCommandBlock: Equatable {
    let command: String
    let workingDirectory: String
    var output: String = ""
}

struct GraphicalFileItem: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case file
        case executable
        case symbolicLink
    }

    let path: String
    let name: String
    let kind: Kind
    var permissions = "----------"
    var linkCount: UInt64 = 1
    var owner = "-"
    var group = "-"
    var size: UInt64 = 0
    var modified = Date.distantPast
    var id: String { path }
}

struct FileListingRequest: Equatable, Sendable {
    let path: String
    let showsHidden: Bool
    let detailed: Bool
}

private struct GraphicalHitLayout {
    let leadingColumns: Int
    let widthColumns: Int
    let rowHeight: Int
}

struct GraphicalDirectoryListing: Equatable, Sendable {
    let path: String
    var items: [GraphicalFileItem]
    var error: String?
    var isLoading: Bool
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
    @Published var isAIChatVisible = false
    @Published var aiDraft = ""
    @Published var aiMessages: [AIChatMessage] = []
    @Published var aiAttachment: TerminalBlockAttachment?
    @Published var isAIResponding = false
    @Published var aiError: String?
    @Published var graphicalMode = false
    @Published var tabAccentColor: NSColor?
    var graphicalViewMode: GraphicalViewMode = .icons
    let error: String?
    private var terminalTitle = "Shell"
    private var customTitle: String?
    private var shellWorkingDirectory = FileManager.default.currentDirectoryPath
    private(set) var commandBlocks: [TerminalCommandBlock] = []
    private var commandLine = CommandLineTracker()
    private var isMarkingInput = false
    private var terminalColumns = 100
    private var nextGraphicalImageID: UInt32 = 10_000
    private var nextGraphicalPlacementID: UInt32 = 1
    private var graphicalItemsByPlacementID: [UInt32: GraphicalFileItem] = [:]
    private var graphicalHitLayoutsByPlacementID: [UInt32: GraphicalHitLayout] = [:]
    private var currentGraphicalListing: GraphicalDirectoryListing?

    init(cols: UInt16 = 100, rows: UInt16 = 32) {
        tabAccentColor = nil
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
            refreshCapturedCommandOutput()
        }
        isRunning = gt_session_is_running(handle)
    }

    func refreshFrame() {
        guard let handle, let frame = gt_session_frame(handle) else { return }
        terminalColumns = Int(frame.pointee.cols)
        if let pointer = frame.pointee.title {
            let value = String(cString: pointer).unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && !(0x202A...0x202E).contains(scalar.value)
                    && !(0x2066...0x2069).contains(scalar.value)
            }.map(String.init).joined()
            terminalTitle = value.isEmpty ? "Shell" : value
            if customTitle == nil { title = terminalTitle }
        }
        if let pointer = frame.pointee.working_directory {
            let value = String(cString: pointer)
            if !value.isEmpty {
                let decoded = value.removingPercentEncoding ?? value
                if let url = URL(string: decoded), url.isFileURL {
                    shellWorkingDirectory = url.path
                } else {
                    shellWorkingDirectory = decoded
                }
                workingDirectory = shellWorkingDirectory
            }
        }
    }

    func rename(to value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = cleaned.isEmpty ? nil : cleaned
        title = customTitle ?? terminalTitle
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
        var directoryChangeTarget: String?
        if isMarkingInput {
            // Drain the PTY first so the shell's echoed command remains tagged as input.
            if gt_session_poll(handle) { refreshFrame() }
            let command = commandLine.submit()
            if !command.isEmpty {
                commandBlocks.append(.init(command: command, workingDirectory: workingDirectory))
                if let target = Self.directoryChangePath(
                    for: command,
                    workingDirectory: workingDirectory
                ) {
                    workingDirectory = target
                    directoryChangeTarget = target
                }
            }
            gt_session_mark_output(handle)
            revision &+= 1
            if let request = Self.fileListingRequest(
                for: command,
                workingDirectory: workingDirectory
            ) {
                let renderedListing = if graphicalMode {
                    renderInlineFileListing(command: command, request: request, handle: handle)
                } else {
                    renderEzaFileListing(command: command, request: request, handle: handle)
                }
                if renderedListing {
                    isMarkingInput = false
                    write(Data([byte]))
                    return
                }
            }
            if graphicalMode, let directoryChangeTarget {
                isMarkingInput = false
                Task { @MainActor [weak self] in
                    await self?.navigateGraphically(to: directoryChangeTarget)
                }
                return
            }
        }
        isMarkingInput = false
        write(Data([byte]))
    }

    func activateGraphicalItem(_ item: GraphicalFileItem) {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let target = URL(fileURLWithPath: item.path, isDirectory: true).standardizedFileURL.path
            workingDirectory = target
            revision &+= 1
            Task { @MainActor [weak self] in
                await self?.navigateGraphically(to: target)
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
    }

    func graphicalItemIsDirectory(_ item: GraphicalFileItem) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func copyGraphicalItem(
        _ item: GraphicalFileItem,
        pasteboard: NSPasteboard = .general
    ) {
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    @discardableResult
    func pasteGraphicalItems(
        onto item: GraphicalFileItem,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        let destinationDirectory: URL
        if graphicalItemIsDirectory(item) {
            destinationDirectory = URL(fileURLWithPath: item.path, isDirectory: true)
        } else {
            destinationDirectory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let manager = FileManager.default
        let standardizedDestination = destinationDirectory.standardizedFileURL
        var copiedAny = false
        for source in urls {
            let standardizedSource = source.standardizedFileURL
            var sourceIsDirectory = ObjCBool(false)
            guard manager.fileExists(atPath: standardizedSource.path, isDirectory: &sourceIsDirectory) else {
                continue
            }
            if sourceIsDirectory.boolValue,
               standardizedDestination.path.hasPrefix(standardizedSource.path + "/") {
                continue
            }
            let destination = Self.availablePasteDestination(
                for: standardizedSource,
                in: standardizedDestination,
                fileManager: manager
            )
            do {
                try manager.copyItem(at: standardizedSource, to: destination)
                copiedAny = true
            } catch {
                continue
            }
        }

        if copiedAny, standardizedDestination.path == URL(
            fileURLWithPath: workingDirectory,
            isDirectory: true
        ).standardizedFileURL.path, graphicalMode {
            showCurrentDirectoryGraphically()
        }
        return copiedAny
    }

    nonisolated static func availablePasteDestination(
        for source: URL,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let original = directory.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let extensionName = source.pathExtension
        let stem = extensionName.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent
        var copyNumber = 1
        while true {
            let suffix = copyNumber == 1 ? " copy" : " copy \(copyNumber)"
            let name = extensionName.isEmpty
                ? stem + suffix
                : stem + suffix + "." + extensionName
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            copyNumber += 1
        }
    }

    func setGraphicalMode(_ enabled: Bool) {
        graphicalMode = enabled
        guard enabled else {
            currentGraphicalListing = nil
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.graphicalMode, !self.isMarkingInput else { return }
            self.showCurrentDirectoryGraphically()
        }
    }

    func setGraphicalViewMode(_ mode: GraphicalViewMode, refresh: Bool = true) {
        guard graphicalViewMode != mode else { return }
        graphicalViewMode = mode
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func showCurrentDirectoryGraphically() {
        guard graphicalMode, let handle else { return }
        // Remove the idle prompt, replace it with the directory view, then ask
        // the shell for a fresh prompt below the injected terminal output.
        write(Data([0x15]))
        usleep(8_000)
        if gt_session_poll(handle) { refreshFrame() }
        feedTerminalOutput("\r\u{1B}[2J\u{1B}[H", handle: handle)
        let request = FileListingRequest(path: workingDirectory, showsHidden: true, detailed: false)
        if renderInlineFileListing(command: nil, request: request, handle: handle,
                                   clearShellInput: false) {
            write(Data([0x0D]))
        }
    }

    private func navigateGraphically(to target: String) async {
        guard graphicalMode, let handle else { return }
        // Execute in the real shell so its process state remains authoritative.
        // This bypasses semantic command capture because navigation is a window
        // action rather than a command the user typed.
        write(Data([0x15]))
        try? await Task.sleep(for: .milliseconds(10))
        if gt_session_poll(handle) { refreshFrame() }
        write(Data(("cd -- \(Self.shellQuoted(target))\r").utf8))
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(15))
            if gt_session_poll(handle) { refreshFrame() }
            if URL(fileURLWithPath: shellWorkingDirectory).standardizedFileURL.path == target { break }
        }

        // Clear the transient echoed cd and prompt, then silently render the
        // equivalent ls result and restore one clean prompt underneath it.
        feedTerminalOutput("\r\u{1B}[2J\u{1B}[H", handle: handle)
        let request = FileListingRequest(path: target, showsHidden: true, detailed: false)
        if renderInlineFileListing(command: nil, request: request, handle: handle,
                                   clearShellInput: false) {
            write(Data([0x0D]))
        }
    }

    func graphicalItem(for placementID: UInt32) -> GraphicalFileItem? {
        graphicalItemsByPlacementID[placementID]
    }

    func graphicalItemHitLayout(for placementID: UInt32) -> (Int, Int, Int) {
        let layout = graphicalHitLayoutsByPlacementID[placementID]
            ?? GraphicalHitLayout(leadingColumns: 0, widthColumns: 16, rowHeight: 2)
        return (layout.leadingColumns, layout.widthColumns, layout.rowHeight)
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func graphicalLabelLines(name: String, maxWidth: Int) -> [String] {
        guard maxWidth > 0 else { return [] }
        let cleanName = name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.map(String.init).joined()
        guard !cleanName.isEmpty else { return [""] }

        let maximumCharacters = maxWidth * 2
        let characters = Array(truncatedGraphicalName(cleanName, maximumCharacters: maximumCharacters))
        if characters.count <= maxWidth { return [String(characters)] }
        let firstCount = min(maxWidth, (characters.count + 1) / 2)
        return [
            String(characters.prefix(firstCount)),
            String(characters.dropFirst(firstCount).prefix(maxWidth)),
        ]
    }

    nonisolated static func truncatedGraphicalName(
        _ name: String,
        maximumCharacters: Int
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        var characters = Array(name)
        if characters.count > maximumCharacters {
            let dotIndex = characters.lastIndex(of: ".")
            let hasExtension = dotIndex.map { $0 > characters.startIndex && $0 < characters.index(before: characters.endIndex) } ?? false
            let suffix: [Character]
            if hasExtension, let dotIndex {
                let baseLast = characters[characters.index(before: dotIndex)]
                suffix = Array("…\(baseLast)" + String(characters[dotIndex...]))
            } else {
                suffix = Array("…\(characters.last!)")
            }
            let visibleSuffix = suffix.count < maximumCharacters
                ? suffix
                : ["…"] + Array(suffix.suffix(maximumCharacters - 1))
            let prefixCount = max(0, maximumCharacters - visibleSuffix.count)
            characters = Array(characters.prefix(prefixCount)) + visibleSuffix
        }
        return String(characters)
    }

    nonisolated static func directoryChangePath(
        for command: String,
        workingDirectory: String
    ) -> String? {
        guard var words = shellWords(command), words.first == "cd" else { return nil }
        words.removeFirst()
        if words.first == "--" { words.removeFirst() }
        guard words.count <= 1 else { return nil }
        let rawPath = words.first ?? "~"
        let expanded: String
        if rawPath == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if rawPath.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(rawPath.dropFirst(2))).path
        } else if rawPath.hasPrefix("/") {
            expanded = rawPath
        } else {
            expanded = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(rawPath).path
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    nonisolated static func fileListingPath(
        for command: String,
        workingDirectory: String
    ) -> String? {
        fileListingRequest(for: command, workingDirectory: workingDirectory)?.path
    }

    nonisolated static func fileListingRequest(
        for command: String,
        workingDirectory: String
    ) -> FileListingRequest? {
        guard var words = shellWords(command), !words.isEmpty else { return nil }
        if words.first == "command" { words.removeFirst() }
        guard let executable = words.first else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let listingCommands: Set<String> = [
            "ls", "ll", "la", "l", "lt", "gls", "colorls", "lsd",
            "eza", "exa", "tree", "dir", "vdir",
        ]
        let splitEza = name == "ez" && words.dropFirst().first == "a"
        guard listingCommands.contains(name) || splitEza else { return nil }
        if splitEza { words.remove(at: 1) }

        var paths: [String] = []
        var optionCharacters = ""
        var optionsEnded = false
        for word in words.dropFirst() {
            if !optionsEnded && word == "--" {
                optionsEnded = true
            } else if !optionsEnded && word.hasPrefix("-") {
                optionCharacters += word.dropFirst().filter { $0.isLetter }
                continue
            } else {
                paths.append(word)
            }
        }
        guard paths.count <= 1 else { return nil }
        let rawPath = paths.first ?? workingDirectory
        let expanded: String
        if rawPath == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if rawPath.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(rawPath.dropFirst(2))).path
        } else if rawPath.hasPrefix("/") {
            expanded = rawPath
        } else {
            expanded = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(rawPath).path
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let standardizedPath = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let aliasIsDetailed = ["ll", "la", "lt"].contains(name)
        let aliasShowsHidden = name == "la"
        return FileListingRequest(
            path: standardizedPath,
            showsHidden: aliasShowsHidden || optionCharacters.contains("a") || optionCharacters.contains("A"),
            detailed: aliasIsDetailed || optionCharacters.contains("l")
        )
    }

    nonisolated static func shellWords(_ command: String) -> [String]? {
        enum Quote { case none, single, double }
        var quote = Quote.none
        var escaping = false
        var current = ""
        var words: [String] = []
        func finishWord() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { current.append(character) }
            case .double:
                if character == "\"" { quote = .none }
                else if character == "\\" { escaping = true }
                else { current.append(character) }
            case .none:
                if character == "'" { quote = .single }
                else if character == "\"" { quote = .double }
                else if character == "\\" { escaping = true }
                else if character.isWhitespace { finishWord() }
                else if "|;&><`".contains(character) { return nil }
                else { current.append(character) }
            }
        }
        guard quote == .none, !escaping else { return nil }
        finishWord()
        return words
    }

    private func renderInlineFileListing(
        command: String?,
        request: FileListingRequest,
        handle: OpaquePointer,
        clearShellInput: Bool = true
    ) -> Bool {
        let listing = Self.ezaDirectoryListing(
            at: request.path,
            showsHidden: request.showsHidden
        ) ?? Self.directoryListing(at: request.path)
        guard listing.error == nil else {
            currentGraphicalListing = nil
            return false
        }
        let items = listing.items.filter { request.showsHidden || !$0.name.hasPrefix(".") || $0.name == ".." }
        currentGraphicalListing = GraphicalDirectoryListing(
            path: listing.path,
            items: items,
            error: nil,
            isLoading: false
        )

        // Clear the command buffered by the interactive shell. The app renders
        // the equivalent output into libghostty-vt, then submits a blank line so
        // the shell produces its next prompt in the normal order.
        if clearShellInput {
            write(Data([0x15]))
            usleep(8_000)
            if gt_session_poll(handle) { refreshFrame() }
        }

        var imageIDs: [GraphicalFileItem.Kind: UInt32] = [:]
        for kind in Set(items.map(\.kind)) {
            imageIDs[kind] = nextGraphicalImageID
            nextGraphicalImageID &+= 1
        }

        var output = Data()
        func append(_ value: String) { output.append(contentsOf: value.utf8) }
        if let command { append(command + "\r\n") }
        for (kind, imageID) in imageIDs {
            let pixels = Self.iconPixels(for: kind)
            append("\u{1B}_Ga=t,f=32,s=16,v=16,i=\(imageID),q=2;")
            append(pixels.base64EncodedString())
            append("\u{1B}\\")
        }

        if request.detailed {
            renderDetailedListing(items, imageIDs: imageIDs, append: append)
            if !items.isEmpty { append("\r\n") }
        } else {
            switch graphicalViewMode {
            case .icons:
                renderIconListing(items, imageIDs: imageIDs, append: append)
            case .list:
                renderSimpleList(items, imageIDs: imageIDs, append: append)
            case .columns:
                renderColumnListing(items, imageIDs: imageIDs, append: append)
            }
        }
        if items.isEmpty { append("(empty directory)\r\n") }

        feedTerminalOutput(output, handle: handle)
        return true
    }

    private func renderEzaFileListing(
        command: String,
        request: FileListingRequest,
        handle: OpaquePointer
    ) -> Bool {
        guard let output = Self.ezaOutput(
            for: request,
            terminalColumns: terminalColumns,
            terminalOutput: true
        ) else { return false }

        write(Data([0x15]))
        usleep(8_000)
        if gt_session_poll(handle) { refreshFrame() }

        let normalizedOutput = String(decoding: output, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        feedTerminalOutput(command + "\r\n" + normalizedOutput, handle: handle)
        return true
    }

    private func renderIconListing(
        _ items: [GraphicalFileItem],
        imageIDs: [GraphicalFileItem.Kind: UInt32],
        append: (String) -> Void
    ) {
        let tileWidth = 10
        let labelWidth = 8
        let outerMarginColumns = 1
        let usableColumns = max(tileWidth, terminalColumns - outerMarginColumns * 2)
        let itemsPerRow = max(1, usableColumns / tileWidth)

            for rowStart in stride(from: 0, to: items.count, by: itemsPerRow) {
                let rowItems = Array(items[rowStart..<min(rowStart + itemsPerRow, items.count)])
                let labels = rowItems.map {
                    Self.graphicalLabelLines(name: $0.name, maxWidth: labelWidth)
                }
                let labelRowCount = min(2, labels.map(\.count).max() ?? 1)
                for (index, item) in rowItems.enumerated() {
                    guard let imageID = imageIDs[item.kind] else { continue }
                    let placementID = nextGraphicalPlacementID
                    nextGraphicalPlacementID &+= 1
                    graphicalItemsByPlacementID[placementID] = item
                    graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                        leadingColumns: 4,
                        widthColumns: tileWidth,
                        rowHeight: 1 + labelRowCount
                    )
                    let tileStart = outerMarginColumns + index * tileWidth
                    let iconColumn = tileStart + (tileWidth - 2) / 2
                    append("\u{1B}[\(iconColumn + 1)G")
                    append("\u{1B}_Ga=p,i=\(imageID),p=\(placementID),c=2,r=1,C=1,q=2\u{1B}\\")
                }
                append("\r\n")
                for labelRow in 0..<labelRowCount {
                    for (index, item) in rowItems.enumerated() where labelRow < labels[index].count {
                        let line = labels[index][labelRow]
                        let tileStart = outerMarginColumns + index * tileWidth
                        let centeredColumn = tileStart + max(0, (tileWidth - line.count) / 2)
                        append("\u{1B}[\(centeredColumn + 1)G")
                        append(Self.labelColor(for: item.kind) + line + "\u{1B}[0m")
                    }
                    append("\r\n")
                }
                append("\r\n")
            }
    }

    private func renderSimpleList(
        _ items: [GraphicalFileItem],
        imageIDs: [GraphicalFileItem.Kind: UInt32],
        append: (String) -> Void
    ) {
        let iconColumn = 1
        let textColumn = 4
        let nameWidth = max(4, terminalColumns - textColumn - 2)
        for item in items {
            guard let imageID = imageIDs[item.kind] else { continue }
            let placementID = nextGraphicalPlacementID
            nextGraphicalPlacementID &+= 1
            graphicalItemsByPlacementID[placementID] = item
            graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                leadingColumns: 0,
                widthColumns: max(1, terminalColumns - 2),
                rowHeight: 1
            )
            append("\u{1B}[\(iconColumn + 1)G")
            append("\u{1B}_Ga=p,i=\(imageID),p=\(placementID),c=2,r=1,C=1,q=2\u{1B}\\")
            let name = Self.truncatedGraphicalName(item.name, maximumCharacters: nameWidth)
            append("\u{1B}[\(textColumn + 1)G")
            append(Self.labelColor(for: item.kind) + name + "\u{1B}[0m\r\n")
        }
        if !items.isEmpty { append("\r\n") }
    }

    private func renderColumnListing(
        _ items: [GraphicalFileItem],
        imageIDs: [GraphicalFileItem.Kind: UInt32],
        append: (String) -> Void
    ) {
        let columnWidth = 14
        let labelWidth = 10
        let outerMarginColumns = 1
        let itemsPerRow = max(1, (terminalColumns - outerMarginColumns * 2) / columnWidth)
        for rowStart in stride(from: 0, to: items.count, by: itemsPerRow) {
            let rowItems = Array(items[rowStart..<min(rowStart + itemsPerRow, items.count)])
            for (index, item) in rowItems.enumerated() {
                guard let imageID = imageIDs[item.kind] else { continue }
                let placementID = nextGraphicalPlacementID
                nextGraphicalPlacementID &+= 1
                graphicalItemsByPlacementID[placementID] = item
                graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                    leadingColumns: 0,
                    widthColumns: columnWidth,
                    rowHeight: 1
                )
                let columnStart = outerMarginColumns + index * columnWidth
                append("\u{1B}[\(columnStart + 1)G")
                append("\u{1B}_Ga=p,i=\(imageID),p=\(placementID),c=2,r=1,C=1,q=2\u{1B}\\")
                let name = Self.truncatedGraphicalName(item.name, maximumCharacters: labelWidth)
                append("\u{1B}[\(columnStart + 4)G")
                append(Self.labelColor(for: item.kind) + name + "\u{1B}[0m")
            }
            append("\r\n\r\n")
        }
    }

    private func renderDetailedListing(
        _ items: [GraphicalFileItem],
        imageIDs: [GraphicalFileItem.Kind: UInt32],
        append: (String) -> Void
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm"
        let iconColumn = 1
        let textColumn = 4

        for item in items {
            guard let imageID = imageIDs[item.kind] else { continue }
            let placementID = nextGraphicalPlacementID
            nextGraphicalPlacementID &+= 1
            graphicalItemsByPlacementID[placementID] = item
            graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                leadingColumns: 0,
                widthColumns: max(1, terminalColumns - 2),
                rowHeight: 1
            )
            append("\u{1B}[\(iconColumn + 1)G")
            append("\u{1B}_Ga=p,i=\(imageID),p=\(placementID),c=2,r=1,C=1,q=2\u{1B}\\")

            let owner = Self.padded(item.owner, width: 8)
            let group = Self.padded(item.group, width: 8)
            let links = Self.padded(String(item.linkCount), width: 3, rightAligned: true)
            let size = Self.padded(String(item.size), width: 9, rightAligned: true)
            let date = formatter.string(from: item.modified)
            let metadata = "\(item.permissions) \(links) \(owner) \(group) \(size) \(date) "
            let nameWidth = max(4, terminalColumns - textColumn - metadata.count - 1)
            let name = Self.truncatedGraphicalName(item.name, maximumCharacters: nameWidth)
            append("\u{1B}[\(textColumn + 1)G")
            append(metadata + Self.labelColor(for: item.kind) + name + "\u{1B}[0m\r\n")
        }
    }

    nonisolated static func padded(
        _ value: String,
        width: Int,
        rightAligned: Bool = false
    ) -> String {
        let clipped = String(value.prefix(width))
        let padding = String(repeating: " ", count: max(0, width - clipped.count))
        return rightAligned ? padding + clipped : clipped + padding
    }

    private func feedTerminalOutput(_ value: String, handle: OpaquePointer) {
        feedTerminalOutput(Data(value.utf8), handle: handle)
    }

    private func feedTerminalOutput(_ output: Data, handle: OpaquePointer) {
        output.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_feed_output(handle, base, output.count)
        }
        revision &+= 1
    }

    nonisolated static func labelColor(for kind: GraphicalFileItem.Kind) -> String {
        switch kind {
        case .directory: "\u{1B}[38;2;255;184;30m"
        case .executable: "\u{1B}[38;2;89;209;99m"
        case .symbolicLink: "\u{1B}[38;2;82;214;224m"
        case .file: "\u{1B}[38;2;210;225;234m"
        }
    }

    nonisolated static func iconPixels(for kind: GraphicalFileItem.Kind) -> Data {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        func fill(_ x: Range<Int>, _ y: Range<Int>, _ color: (UInt8, UInt8, UInt8, UInt8)) {
            for row in y where row >= 0 && row < size {
                for column in x where column >= 0 && column < size {
                    let offset = (row * size + column) * 4
                    pixels[offset] = color.0
                    pixels[offset + 1] = color.1
                    pixels[offset + 2] = color.2
                    pixels[offset + 3] = color.3
                }
            }
        }
        switch kind {
        case .directory:
            fill(2..<15, 5..<15, (112, 61, 5, 210))
            fill(2..<8, 2..<5, (255, 205, 67, 255))
            fill(1..<14, 4..<14, (220, 125, 8, 255))
            fill(2..<14, 5..<8, (255, 207, 66, 255))
            fill(2..<14, 8..<11, (255, 177, 24, 255))
            fill(2..<14, 11..<13, (225, 126, 7, 255))
            fill(3..<13, 5..<6, (255, 239, 158, 230))
            fill(13..<14, 6..<13, (159, 82, 2, 255))
        case .file:
            fill(3..<13, 1..<15, (190, 205, 216, 255))
            fill(9..<13, 1..<5, (232, 240, 245, 255))
            fill(5..<11, 7..<8, (91, 113, 128, 255))
            fill(5..<11, 10..<11, (91, 113, 128, 255))
        case .executable:
            fill(3..<13, 1..<15, (105, 195, 112, 255))
            fill(5..<11, 7..<8, (28, 92, 48, 255))
            fill(5..<11, 10..<11, (28, 92, 48, 255))
        case .symbolicLink:
            fill(2..<9, 4..<7, (72, 196, 220, 255))
            fill(7..<14, 9..<12, (72, 196, 220, 255))
            fill(6..<10, 7..<9, (72, 196, 220, 255))
        }
        return Data(pixels)
    }

    nonisolated static func directoryListing(at path: String) -> GraphicalDirectoryListing {
        let manager = FileManager.default
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            let directoryURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let urls = try manager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            var items = urls.map { url -> GraphicalFileItem in
                let values = try? url.resourceValues(forKeys: keys)
                let kind: GraphicalFileItem.Kind
                if values?.isSymbolicLink == true {
                    kind = .symbolicLink
                } else if values?.isDirectory == true {
                    kind = .directory
                } else if manager.isExecutableFile(atPath: url.path) {
                    kind = .executable
                } else {
                    kind = .file
                }
                return graphicalFileItem(url: url, name: url.lastPathComponent, kind: kind)
            }
            let parentURL = directoryURL.deletingLastPathComponent().standardizedFileURL
            items.append(graphicalFileItem(url: parentURL, name: "..", kind: .directory))
            items.sort {
                if $0.name == ".." { return true }
                if $1.name == ".." { return false }
                let leftDirectory = $0.kind == .directory
                let rightDirectory = $1.kind == .directory
                if leftDirectory != rightDirectory { return leftDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return GraphicalDirectoryListing(path: path, items: items, error: nil, isLoading: false)
        } catch {
            return GraphicalDirectoryListing(
                path: path,
                items: [],
                error: error.localizedDescription,
                isLoading: false
            )
        }
    }

    nonisolated static func ezaDirectoryListing(
        at path: String,
        showsHidden: Bool,
        executableURL: URL? = ezaExecutableURL()
    ) -> GraphicalDirectoryListing? {
        guard let executableURL else { return nil }
        let request = FileListingRequest(path: path, showsHidden: showsHidden, detailed: false)
        guard let output = ezaOutput(
            for: request,
            terminalColumns: 80,
            terminalOutput: false,
            executableURL: executableURL
        ) else { return nil }

        let fallback = directoryListing(at: path)
        guard fallback.error == nil else { return fallback }
        let visibleItems = fallback.items.filter {
            showsHidden || !$0.name.hasPrefix(".") || $0.name == ".."
        }
        var itemsByPath = Dictionary(uniqueKeysWithValues: visibleItems.map {
            (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0)
        })
        var orderedItems: [GraphicalFileItem] = []
        if let parent = itemsByPath.removeValue(forKey: URL(
            fileURLWithPath: path,
            isDirectory: true
        ).deletingLastPathComponent().standardizedFileURL.path) {
            orderedItems.append(parent)
        }

        let outputPaths = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        for outputPath in outputPaths {
            let standardizedPath = URL(fileURLWithPath: outputPath).standardizedFileURL.path
            if let item = itemsByPath.removeValue(forKey: standardizedPath) {
                orderedItems.append(item)
            }
        }
        orderedItems.append(contentsOf: itemsByPath.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
        return GraphicalDirectoryListing(
            path: fallback.path,
            items: orderedItems,
            error: nil,
            isLoading: false
        )
    }

    nonisolated static func ezaExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        var candidates: [URL] = []
        if let configuredPath = environment["TERMINAL_TABS_EZA_PATH"],
           !configuredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }
        candidates.append(
            URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appending(path: ".build/bin/eza")
        )
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appending(path: "eza")
            })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func ezaOutput(
        for request: FileListingRequest,
        terminalColumns: Int,
        terminalOutput: Bool,
        executableURL: URL? = ezaExecutableURL()
    ) -> Data? {
        guard let executableURL else { return nil }
        let arguments = ezaArguments(
            for: request,
            terminalColumns: terminalColumns,
            terminalOutput: terminalOutput
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    nonisolated static func ezaArguments(
        for request: FileListingRequest,
        terminalColumns: Int,
        terminalOutput: Bool
    ) -> [String] {
        var arguments = [
            terminalOutput ? "--color=always" : "--color=never",
            "--icons=never",
            "--hyperlink=never",
            "--group-directories-first",
        ]
        if terminalOutput {
            arguments.append(request.detailed ? "--long" : "--grid")
            arguments.append("--width=\(max(1, terminalColumns))")
        } else {
            arguments.append(contentsOf: ["--oneline", "--absolute=on", "--no-quotes"])
        }
        if request.showsHidden { arguments.append("--all") }
        arguments.append(contentsOf: ["--", request.path])
        return arguments
    }

    nonisolated static func graphicalFileItem(
        url: URL,
        name: String,
        kind: GraphicalFileItem.Kind
    ) -> GraphicalFileItem {
        var info = stat()
        let didStat = url.path.withCString { lstat($0, &info) } == 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return GraphicalFileItem(
            path: url.path,
            name: name,
            kind: kind,
            permissions: didStat ? permissionString(mode: info.st_mode, kind: kind) : "----------",
            linkCount: didStat ? UInt64(info.st_nlink) : 1,
            owner: attributes?[.ownerAccountName] as? String ?? "-",
            group: attributes?[.groupOwnerAccountName] as? String ?? "-",
            size: didStat ? UInt64(max(0, info.st_size)) : 0,
            modified: didStat
                ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                : .distantPast
        )
    }

    nonisolated static func permissionString(
        mode: mode_t,
        kind: GraphicalFileItem.Kind
    ) -> String {
        let prefix: Character
        switch kind {
        case .directory: prefix = "d"
        case .symbolicLink: prefix = "l"
        case .file, .executable: prefix = "-"
        }
        let masks: [(mode_t, Character)] = [
            (S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
            (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
            (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x"),
        ]
        return String(prefix) + String(masks.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }

    func workingDirectory(for command: String) -> String {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return commandBlocks.last(where: { $0.command == normalized })?.workingDirectory
            ?? workingDirectory
    }

    func fullOutput(for command: String) -> String? {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return commandBlocks.last(where: { $0.command == normalized && !$0.output.isEmpty })?.output
    }

    private func refreshCapturedCommandOutput() {
        guard let handle, !commandBlocks.isEmpty else { return }
        let count = gt_session_command_output(handle, nil, 0)
        guard count > 0 else { return }
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_command_output(handle, base, count)
        }
        commandBlocks[commandBlocks.count - 1].output = Self.cleanTerminalOutput(data)
    }

    static func cleanTerminalOutput(_ data: Data) -> String {
        var value = String(decoding: data, as: UTF8.self)
        value = value.replacingOccurrences(
            of: "\\u001B\\][^\\u0007]*(?:\\u0007|\\u001B\\\\)",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "\\u001B\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        var lines = value.components(separatedBy: "\n")
        while lines.first?.isEmpty == true { lines.removeFirst() }
        if !value.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func scroll(rows: Int) {
        guard let handle, rows != 0 else { return }
        if gt_session_scroll(handle, rows) {
            revision &+= 1
            refreshFrame()
        }
    }

    func attachToAI(command: String, output: String, workingDirectory: String) {
        aiAttachment = TerminalBlockAttachment(
            command: command,
            output: output,
            workingDirectory: workingDirectory
        )
        isAIChatVisible = true
        aiError = nil
    }

    var canAttachGraphicalOutputToAI: Bool {
        currentGraphicalListing != nil
    }

    func attachGraphicalOutputToAI() {
        guard let currentGraphicalListing else { return }
        let attachment = Self.aiAttachment(for: currentGraphicalListing)
        attachToAI(
            command: attachment.command,
            output: attachment.output,
            workingDirectory: attachment.workingDirectory
        )
    }

    nonisolated static func aiAttachment(
        for listing: GraphicalDirectoryListing
    ) -> TerminalBlockAttachment {
        let output = listing.items.map { item in
            "\(item.permissions) \(item.size) \(item.name)"
        }.joined(separator: "\n")
        return TerminalBlockAttachment(
            command: "ls -la -- \(shellQuoted(listing.path))",
            output: output.isEmpty ? "(empty directory)" : output,
            workingDirectory: listing.path
        )
    }

    func sendAIMessage(using settings: AISettings) {
        let question = aiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAIResponding else { return }
        let provider = settings.provider
        let connectionMode = settings.connectionMode(for: provider)
        let apiKey: String
        if connectionMode == .apiKey {
            guard let savedKey = settings.apiKey(for: provider) else {
                aiError = "Connect \(provider.title) from Settings first."
                return
            }
            apiKey = savedKey
        } else {
            apiKey = ""
        }

        let message = AIChatMessage(role: .user, text: question, attachment: aiAttachment)
        aiMessages.append(message)
        aiDraft = ""
        aiAttachment = nil
        aiError = nil
        isAIResponding = true
        let history = aiMessages
        let model = settings.selectedModel

        Task { [weak self] in
            do {
                let answer = try await AIClient.send(
                    provider: provider,
                    connectionMode: connectionMode,
                    model: model,
                    apiKey: apiKey,
                    messages: history,
                    workingDirectory: self?.workingDirectory ?? FileManager.default.currentDirectoryPath
                )
                guard let self else { return }
                self.aiMessages.append(AIChatMessage(role: .assistant, text: answer))
                self.isAIResponding = false
            } catch {
                guard let self else { return }
                self.aiError = error.localizedDescription
                self.isAIResponding = false
            }
        }
    }

    func clearAIConversation() {
        aiMessages.removeAll()
        aiAttachment = nil
        aiError = nil
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
    private static let graphicalModeKey = "graphicalMode"
    private static let graphicalViewModeKey = "graphicalViewMode"
    private static let autocolorTabsKey = "autocolorTabs"
    private static let automaticTabColors = [
        NSColor(srgbRed: 0.55, green: 0.39, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.38, green: 0.49, blue: 0.60, alpha: 1),
        NSColor(srgbRed: 0.39, green: 0.55, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.60, green: 0.48, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.48, green: 0.43, blue: 0.61, alpha: 1),
        NSColor(srgbRed: 0.57, green: 0.39, blue: 0.37, alpha: 1),
    ]

    @Published var groups: [TerminalTabGroup] = []
    let aiSettings = AISettings()
    @Published var isSettingsVisible = false
    @Published var selectedGroupID: UUID?
    @Published var selectedID: UUID?
    @Published var tabOrientation: TabOrientation {
        didSet { UserDefaults.standard.set(tabOrientation.rawValue, forKey: Self.orientationKey) }
    }
    @Published var isTabBarVisible: Bool {
        didSet { UserDefaults.standard.set(isTabBarVisible, forKey: Self.tabBarVisibilityKey) }
    }
    @Published var autocolorTabs: Bool {
        didSet { UserDefaults.standard.set(autocolorTabs, forKey: Self.autocolorTabsKey) }
    }
    @Published var graphicalMode: Bool {
        didSet {
            UserDefaults.standard.set(graphicalMode, forKey: Self.graphicalModeKey)
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalMode(graphicalMode)
            }
        }
    }
    @Published var graphicalViewMode: GraphicalViewMode {
        didSet {
            UserDefaults.standard.set(graphicalViewMode.rawValue, forKey: Self.graphicalViewModeKey)
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalViewMode(graphicalViewMode)
            }
        }
    }
    private var timer: Timer?
    private var lastAutomaticTabColorIndex: Int?

    init() {
        tabOrientation = TabOrientation(
            rawValue: UserDefaults.standard.string(forKey: Self.orientationKey) ?? ""
        ) ?? .horizontal
        if UserDefaults.standard.object(forKey: Self.tabBarVisibilityKey) == nil {
            isTabBarVisible = true
        } else {
            isTabBarVisible = UserDefaults.standard.bool(forKey: Self.tabBarVisibilityKey)
        }
        if UserDefaults.standard.object(forKey: Self.autocolorTabsKey) == nil {
            autocolorTabs = true
        } else {
            autocolorTabs = UserDefaults.standard.bool(forKey: Self.autocolorTabsKey)
        }
        graphicalMode = UserDefaults.standard.bool(forKey: Self.graphicalModeKey)
        graphicalViewMode = GraphicalViewMode(
            rawValue: UserDefaults.standard.string(forKey: Self.graphicalViewModeKey) ?? ""
        ) ?? .icons
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

    func setGraphicalMode(_ enabled: Bool) {
        graphicalMode = enabled
    }

    func newGroup() {
        let usedNumbers = Set(groups.compactMap { group -> Int? in
            guard group.name.hasPrefix("Group ") else { return nil }
            return Int(group.name.dropFirst("Group ".count))
        })
        let number = (1...).first { !usedNumbers.contains($0) } ?? groups.count + 1
        let tab = makeTab()
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
        let tab = makeTab()
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
                let replacement = makeTab()
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

    private func makeTab() -> TerminalSession {
        let tab = TerminalSession()
        tab.setGraphicalViewMode(graphicalViewMode, refresh: false)
        tab.setGraphicalMode(graphicalMode)
        guard autocolorTabs else { return tab }

        var colorIndex = Int.random(in: Self.automaticTabColors.indices)
        if colorIndex == lastAutomaticTabColorIndex, Self.automaticTabColors.count > 1 {
            colorIndex = (colorIndex + Int.random(in: 1..<Self.automaticTabColors.count))
                % Self.automaticTabColors.count
        }
        lastAutomaticTabColorIndex = colorIndex
        tab.tabAccentColor = Self.automaticTabColors[colorIndex]
        return tab
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
