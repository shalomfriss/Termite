import AppKit
import Combine
import Darwin
import Foundation
import GhosttyBridge
import UniformTypeIdentifiers

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
    var created = Date.distantPast
    var added = Date.distantPast
    var lastOpened = Date.distantPast
    var kindDescription = "Item"
    var tags: [String] = []
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

private struct LstrJSONNode: Decodable {
    let name: String?
    let contents: [LstrJSONNode]?
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
    static let graphicalNavigationConcealSequence = Data("\u{1B}[8m".utf8)
    static let graphicalNavigationRevealSequence = Data("\u{1B}[28m".utf8)

    static var shellIntegrationDirectory: String? {
        Bundle.module.url(
            forResource: "ShellIntegration",
            withExtension: nil
        )?.path
    }

    let id = UUID()
    let handle: OpaquePointer?

    @Published var title = "Shell"
    @Published var workingDirectory = FileManager.default.currentDirectoryPath
    @Published var isRunning = true
    @Published var revision: UInt = 0
    @Published var isAIChatVisible = false
    @Published var aiDraft = ""
    @Published var aiMessages: [AIChatMessage] = []
    @Published var aiAttachments: [AIInputAttachment] = []
    @Published var isAIResponding = false
    @Published var aiError: String?
    @Published var graphicalMode = false
    @Published private(set) var isGraphicalNavigationInProgress = false
    @Published private(set) var isAlternateScreen = false
    @Published private(set) var isMouseReporting = false
    @Published private(set) var isFocusReporting = false
    @Published private(set) var isCursorAtPrompt = false
    @Published private(set) var isBracketedPasteEnabled = false
    @Published private(set) var graphicalPreviewItem: GraphicalFileItem?
    @Published var graphicalOperationIssue: GraphicalOperationIssue?
    @Published var tabAccentColor: NSColor?
    @Published private(set) var gitBranch: String? = nil
    @Published private(set) var gitBranches: [String] = []
    var graphicalViewMode: GraphicalViewMode = .icons
    var graphicalShowsHiddenFiles = false
    var graphicalSortOption: GraphicalSortOption = .name
    var graphicalGroupOption: GraphicalGroupOption = .none
    var graphicalSortDirection: GraphicalSortDirection = .ascending
    var graphicalFoldersFirst = true
    var listingBackend: ListingBackend = .eza
    let error: String?
    private var terminalTitle = "Shell"
    private var customTitle: String?
    private var shellWorkingDirectory = FileManager.default.currentDirectoryPath
    private(set) var commandBlocks: [TerminalCommandBlock] = []
    private var collapsedTerminalBlockIDs: Set<TerminalBlockID> = []
    private var bookmarkedTerminalBlockIDs: Set<TerminalBlockID> = []
    private var commandLine = CommandLineTracker()
    private var isMarkingInput = false
    private var terminalColumns = 100
    private var nextGraphicalImageID: UInt32 = 10_000
    private var nextGraphicalPlacementID: UInt32 = 1
    private var graphicalItemsByPlacementID: [UInt32: GraphicalFileItem] = [:]
    private var graphicalHitLayoutsByPlacementID: [UInt32: GraphicalHitLayout] = [:]
    private var currentGraphicalListing: GraphicalDirectoryListing?
    private var graphicalNavigationTask: Task<Void, Never>?
    private var graphicalStartupTask: Task<Void, Never>?
    private var graphicalNavigationGeneration: UInt = 0
    private var gitBranchDirectory: String?

    init(
        cols: UInt16 = 100,
        rows: UInt16 = 32,
        workingDirectory initialWorkingDirectory: String? = nil
    ) {
        tabAccentColor = nil
        let initialDirectory = initialWorkingDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        var message: UnsafePointer<CChar>?
        let shellIntegrationDirectory = Self.shellIntegrationDirectory
        if let initialDirectory {
            handle = initialDirectory.withCString { directory in
                guard let shellIntegrationDirectory else {
                    return gt_session_create_at(cols, rows, directory, &message)
                }
                return shellIntegrationDirectory.withCString { integrationDirectory in
                    gt_session_create_configured(
                        cols,
                        rows,
                        directory,
                        integrationDirectory,
                        &message
                    )
                }
            }
        } else if let shellIntegrationDirectory {
            handle = shellIntegrationDirectory.withCString { integrationDirectory in
                gt_session_create_configured(cols, rows, nil, integrationDirectory, &message)
            }
        } else {
            handle = gt_session_create(cols, rows, &message)
        }
        error = message.map(String.init(cString:))
        isRunning = handle != nil
        refreshFrame()
        if let initialDirectory {
            // The child may not have completed its chdir when the first frame is
            // captured. Keep the requested directory until shell output provides
            // an authoritative working directory on a later poll.
            workingDirectory = initialDirectory
            shellWorkingDirectory = initialDirectory
        }
        refreshGitBranch()
    }

    isolated deinit {
        graphicalNavigationTask?.cancel()
        graphicalStartupTask?.cancel()
        if let handle { gt_session_destroy(handle) }
    }

    func poll() {
        guard let handle else { return }
        if gt_session_poll(handle) {
            revision &+= 1
            refreshFrame()
            if !isAlternateScreen { refreshCapturedCommandOutput() }
        }
        isRunning = gt_session_is_running(handle)
    }

    func refreshFrame() {
        guard let handle, let frame = gt_session_frame(handle) else { return }
        terminalColumns = Int(frame.pointee.cols)
        isAlternateScreen = frame.pointee.alternate_screen
        isMouseReporting = frame.pointee.mouse_reporting
        isFocusReporting = frame.pointee.focus_reporting
        isCursorAtPrompt = frame.pointee.cursor_at_prompt
        isBracketedPasteEnabled = frame.pointee.bracketed_paste
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
        refreshGitBranch()
    }

    private func refreshGitBranch(forceBranches: Bool = false) {
        let branch = Self.gitBranchName(at: workingDirectory)
        let shouldRefreshBranches = forceBranches
            || gitBranchDirectory != workingDirectory
            || branch != gitBranch
        if branch != gitBranch { gitBranch = branch }
        guard shouldRefreshBranches else { return }
        let branches = Self.gitLocalBranchNames(at: workingDirectory)
        if branches != gitBranches { gitBranches = branches }
        gitBranchDirectory = workingDirectory
    }

    func refreshGitBranches() {
        refreshGitBranch(forceBranches: true)
    }

    func switchGitBranch(to branch: String) {
        guard branch != gitBranch, gitBranches.contains(branch) else { return }
        sendUserInput(Data(Self.gitSwitchCommand(for: branch).utf8))
        sendUserInput(Data([0x0D]))
    }

    nonisolated static func gitSwitchCommand(for branch: String) -> String {
        "git switch -- \(shellQuoted(branch))"
    }

    nonisolated static func gitBranchName(at path: String) -> String? {
        guard let metadata = gitMetadata(at: path),
              let head = try? String(
                  contentsOf: metadata.gitDirectory.appending(path: "HEAD"),
                  encoding: .utf8
              ).trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else { return nil }
        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        return String(head.prefix(7))
    }

    nonisolated static func gitLocalBranchNames(at path: String) -> [String] {
        guard let metadata = gitMetadata(at: path) else { return [] }
        let fileManager = FileManager.default
        let headsDirectory = metadata.commonDirectory.appending(path: "refs/heads")
        var branches = Set<String>()

        if let enumerator = fileManager.enumerator(atPath: headsDirectory.path) {
            for case let relativePath as String in enumerator {
                let url = headsDirectory.appending(path: relativePath)
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                branches.insert(relativePath)
            }
        }

        if let packedRefs = try? String(
            contentsOf: metadata.commonDirectory.appending(path: "packed-refs"),
            encoding: .utf8
        ) {
            for line in packedRefs.split(whereSeparator: \Character.isNewline) {
                let fields = line.split(whereSeparator: \Character.isWhitespace)
                guard fields.count >= 2 else { continue }
                let reference = String(fields[1])
                guard reference.hasPrefix("refs/heads/") else { continue }
                branches.insert(String(reference.dropFirst("refs/heads/".count)))
            }
        }

        if let current = gitBranchName(at: path),
           let head = try? String(
               contentsOf: metadata.gitDirectory.appending(path: "HEAD"),
               encoding: .utf8
           ), head.hasPrefix("ref: refs/heads/") {
            branches.insert(current)
        }

        return branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func gitMetadata(
        at path: String
    ) -> (gitDirectory: URL, commonDirectory: URL)? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL

        while true {
            let dotGit = directory.appending(path: ".git")
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = dotGit
                } else if let marker = try? String(contentsOf: dotGit, encoding: .utf8),
                          marker.hasPrefix("gitdir:") {
                    let rawPath = marker
                        .dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = URL(
                        fileURLWithPath: rawPath,
                        relativeTo: directory
                    ).standardizedFileURL
                } else {
                    return nil
                }

                let commonDirectory: URL
                if let commonPath = try? String(
                    contentsOf: gitDirectory.appending(path: "commondir"),
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines),
                !commonPath.isEmpty {
                    commonDirectory = URL(
                        fileURLWithPath: commonPath,
                        relativeTo: gitDirectory
                    ).standardizedFileURL
                } else {
                    commonDirectory = gitDirectory
                }
                return (gitDirectory, commonDirectory)
            }

            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
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

    func executeScheduledScript(_ script: String) async throws {
        guard let handle, gt_session_is_running(handle) else {
            throw ScheduledJobError.shellUnavailable
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScheduledJobError.emptyScript
        }

        // A scheduled script is real shell input even when the global graphical
        // listing mode is enabled. Prevent its startup listing from racing the job.
        graphicalStartupTask?.cancel()
        graphicalStartupTask = nil

        var candidatePrompt: String?
        var stableChecks = 0
        for attempt in 0..<240 {
            try Task.checkCancellation()
            if gt_session_poll(handle) {
                revision &+= 1
                refreshFrame()
            }
            guard gt_session_is_running(handle) else {
                throw ScheduledJobError.shellUnavailable
            }
            if let prompt = visiblePromptText(handle: handle), !prompt.isEmpty {
                if prompt == candidatePrompt {
                    stableChecks += 1
                } else {
                    candidatePrompt = prompt
                    stableChecks = 1
                }
                if stableChecks >= 3,
                   Self.looksLikeShellPrompt(prompt) || attempt >= 200 {
                    write(Data(script.utf8))
                    if script.utf8.last != 0x0A, script.utf8.last != 0x0D {
                        write(Data([0x0D]))
                    }
                    return
                }
            } else {
                candidatePrompt = nil
                stableChecks = 0
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ScheduledJobError.shellReadinessTimedOut
    }

    func sendUserInput(_ data: Data) {
        guard let handle else { return }
        if isAlternateScreen {
            write(data)
            return
        }
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
                    renderFileListing(command: command, request: request, handle: handle)
                }
                if renderedListing {
                    isMarkingInput = false
                    write(Data([byte]))
                    return
                }
            }
            if graphicalMode, let directoryChangeTarget {
                isMarkingInput = false
                requestGraphicalNavigation(to: directoryChangeTarget)
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
            requestGraphicalNavigation(to: target)
        } else {
            let url = URL(fileURLWithPath: item.path)
            performWhenUbiquitousItemIsAvailable(url, title: "Couldn’t Open File") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func setGraphicalPreviewItem(_ item: GraphicalFileItem?) {
        let previewItem: GraphicalFileItem?
        if graphicalMode,
           let item,
           !graphicalItemIsDirectory(item) {
            previewItem = item
        } else {
            previewItem = nil
        }
        guard graphicalPreviewItem != previewItem else { return }
        graphicalPreviewItem = previewItem
    }

    func listGraphicalDirectory(_ item: GraphicalFileItem) {
        guard graphicalMode, graphicalItemIsDirectory(item) else { return }
        sendUserInput(Data("ls -- \(Self.shellQuoted(item.path))".utf8))
        sendUserInput(Data([0x0D]))
    }

    func catGraphicalFile(_ item: GraphicalFileItem) {
        guard graphicalMode, graphicalItemCanDisplayAsText(item) else { return }
        let url = URL(fileURLWithPath: item.path)
        performWhenUbiquitousItemIsAvailable(url, title: "Couldn’t Read File") { [weak self] in
            guard let self, self.graphicalItemCanDisplayAsText(item) else { return }
            self.sendUserInput(Data("cat -- \(Self.shellQuoted(item.path))".utf8))
            self.sendUserInput(Data([0x0D]))
        }
    }

    func graphicalItemIsDirectory(_ item: GraphicalFileItem) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func graphicalItemCanDisplayAsText(_ item: GraphicalFileItem) -> Bool {
        guard !graphicalItemIsDirectory(item) else { return false }
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if contentType.conforms(to: .text) { return true }
            if contentType.conforms(to: .image)
                || contentType.conforms(to: .audio)
                || contentType.conforms(to: .movie)
                || contentType.conforms(to: .archive)
                || contentType.conforms(to: .executable) {
                return false
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: 8_192) else { return false }
        guard !sample.isEmpty else { return true }
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    var suggestedGraphicalFolderName: String {
        let directory = graphicalDirectoryURL
        let manager = FileManager.default
        var index = 1
        while true {
            let name = index == 1 ? "untitled folder" : "untitled folder \(index)"
            if !manager.fileExists(atPath: directory.appending(path: name).path) {
                return name
            }
            index += 1
        }
    }

    @discardableResult
    func createGraphicalFolder(named rawName: String) throws -> URL {
        guard graphicalMode else { throw GraphicalFolderCreationError.graphicalModeRequired }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw GraphicalFolderCreationError.invalidName
        }

        let destination = graphicalDirectoryURL.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GraphicalFolderCreationError.alreadyExists(name)
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        showCurrentDirectoryGraphically()
        return destination
    }

    private var graphicalDirectoryURL: URL {
        URL(
            fileURLWithPath: currentGraphicalListing?.path ?? workingDirectory,
            isDirectory: true
        ).standardizedFileURL
    }

    nonisolated static func ensureUbiquitousItemIsAvailable(at url: URL) async throws {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .isDirectoryKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let initialValues = try url.resourceValues(forKeys: keys)
        guard initialValues.isUbiquitousItem == true else { return }
        if initialValues.isDirectory == true,
           (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil {
            return
        }
        if Self.isAvailableUbiquitousStatus(initialValues.ubiquitousItemDownloadingStatus) {
            return
        }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<120 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
            let values = try url.resourceValues(forKeys: keys)
            if Self.isAvailableUbiquitousStatus(values.ubiquitousItemDownloadingStatus) {
                return
            }
        }
        throw GraphicalOperationError.iCloudDownloadTimedOut(url.lastPathComponent)
    }

    nonisolated private static func isAvailableUbiquitousStatus(
        _ status: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        status == .current || status == .downloaded
    }

    private func performWhenUbiquitousItemIsAvailable(
        _ url: URL,
        title: String,
        action: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor [weak self] in
            do {
                try await Self.ensureUbiquitousItemIsAvailable(at: url)
                try Task.checkCancellation()
                action()
            } catch is CancellationError {
                return
            } catch {
                self?.graphicalOperationIssue = GraphicalOperationIssue(
                    title: title,
                    message: error.localizedDescription
                )
            }
        }
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

    func canMoveGraphicalItems(_ urls: [URL], into item: GraphicalFileItem) -> Bool {
        guard graphicalMode, graphicalItemIsDirectory(item), !urls.isEmpty else { return false }
        let destination = URL(fileURLWithPath: item.path, isDirectory: true).standardizedFileURL
        let manager = FileManager.default
        return urls.allSatisfy { source in
            let source = source.standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  source != destination else { return false }
            if isDirectory.boolValue, destination.path.hasPrefix(source.path + "/") {
                return false
            }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            return !manager.fileExists(atPath: target.path)
        }
    }

    @discardableResult
    func moveGraphicalItems(_ urls: [URL], into item: GraphicalFileItem) -> Bool {
        guard canMoveGraphicalItems(urls, into: item) else { return false }
        let destination = URL(fileURLWithPath: item.path, isDirectory: true).standardizedFileURL
        let manager = FileManager.default
        var movedURLs: [(source: URL, destination: URL)] = []
        for sourceURL in urls {
            let source = sourceURL.standardizedFileURL
            let target = destination.appendingPathComponent(source.lastPathComponent)
            do {
                try manager.moveItem(at: source, to: target)
                movedURLs.append((source, target))
            } catch {
                for move in movedURLs.reversed() {
                    try? manager.moveItem(at: move.destination, to: move.source)
                }
                return false
            }
        }
        showCurrentDirectoryGraphically()
        return true
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
        guard graphicalMode != enabled else { return }
        graphicalMode = enabled
        guard enabled else {
            graphicalStartupTask?.cancel()
            graphicalStartupTask = nil
            graphicalNavigationTask?.cancel()
            graphicalNavigationTask = nil
            isGraphicalNavigationInProgress = false
            currentGraphicalListing = nil
            graphicalPreviewItem = nil
            return
        }
        graphicalStartupTask?.cancel()
        graphicalStartupTask = Task { @MainActor [weak self] in
            var candidatePrompt: String?
            var stableChecks = 0
            for attempt in 0..<80 {
                do {
                    try await Task.sleep(
                        for: attempt == 0 ? .milliseconds(150) : .milliseconds(50)
                    )
                } catch {
                    return
                }
                guard let self, self.graphicalMode, !self.isMarkingInput else { return }
                self.poll()
                guard let prompt = self.handle.flatMap({ self.visiblePromptText(handle: $0) }) else {
                    candidatePrompt = nil
                    stableChecks = 0
                    continue
                }
                if prompt == candidatePrompt {
                    stableChecks += 1
                } else {
                    candidatePrompt = prompt
                    stableChecks = 1
                }
                guard stableChecks >= 4,
                      Self.looksLikeShellPrompt(prompt) || attempt >= 70 else { continue }
                if self.showCurrentDirectoryGraphically(preservingPrompt: prompt) {
                    self.graphicalStartupTask = nil
                    return
                }
            }
            self?.graphicalStartupTask = nil
        }
    }

    func setGraphicalViewMode(_ mode: GraphicalViewMode, refresh: Bool = true) {
        guard graphicalViewMode != mode else { return }
        graphicalViewMode = mode
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func setGraphicalShowsHiddenFiles(_ enabled: Bool, refresh: Bool = true) {
        guard graphicalShowsHiddenFiles != enabled else { return }
        graphicalShowsHiddenFiles = enabled
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func setGraphicalSortOption(_ option: GraphicalSortOption, refresh: Bool = true) {
        guard graphicalSortOption != option else { return }
        graphicalSortOption = option
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func setGraphicalGroupOption(_ option: GraphicalGroupOption, refresh: Bool = true) {
        guard graphicalGroupOption != option else { return }
        graphicalGroupOption = option
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func setGraphicalSortDirection(_ direction: GraphicalSortDirection, refresh: Bool = true) {
        guard graphicalSortDirection != direction else { return }
        graphicalSortDirection = direction
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func setGraphicalFoldersFirst(_ enabled: Bool, refresh: Bool = true) {
        guard graphicalFoldersFirst != enabled else { return }
        graphicalFoldersFirst = enabled
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    func setListingBackend(_ backend: ListingBackend, refresh: Bool = true) {
        guard listingBackend != backend else { return }
        listingBackend = backend
        if refresh, graphicalMode { showCurrentDirectoryGraphically() }
    }

    @discardableResult
    func showCurrentDirectoryGraphically(preservingPrompt capturedPrompt: String? = nil) -> Bool {
        guard graphicalMode,
              !isGraphicalNavigationInProgress,
              let handle,
              let prompt = capturedPrompt ?? visiblePromptText(handle: handle) else { return false }
        setGraphicalPreviewItem(nil)
        // Preserve the shell's existing idle prompt instead of submitting a
        // blank command, which would make the shell emit a second prompt.
        write(Data([0x15]))
        usleep(8_000)
        if gt_session_poll(handle) { refreshFrame() }
        feedTerminalOutput("\r\u{1B}[2J\u{1B}[H", handle: handle)
        let request = FileListingRequest(
            path: workingDirectory,
            showsHidden: graphicalShowsHiddenFiles,
            detailed: false
        )
        if renderInlineFileListing(command: nil, request: request, handle: handle,
                                   clearShellInput: false) {
            feedTerminalOutput(prompt, handle: handle)
            return true
        }
        return false
    }

    nonisolated static func looksLikeShellPrompt(_ value: String) -> Bool {
        guard let last = value.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return "%$#>❯❮›»λ".contains(last)
    }

    private func requestGraphicalNavigation(to rawTarget: String) {
        guard graphicalMode else { return }
        let targetURL = URL(fileURLWithPath: rawTarget, isDirectory: true).standardizedFileURL
        graphicalPreviewItem = nil
        graphicalStartupTask?.cancel()
        graphicalStartupTask = nil
        graphicalNavigationGeneration &+= 1
        let generation = graphicalNavigationGeneration
        graphicalNavigationTask?.cancel()
        isGraphicalNavigationInProgress = true
        workingDirectory = targetURL.path
        revision &+= 1

        graphicalNavigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Self.ensureUbiquitousItemIsAvailable(at: targetURL)
                try Task.checkCancellation()
                try await self.navigateGraphically(
                    to: targetURL.path,
                    generation: generation
                )
            } catch is CancellationError {
                // A newer navigation request superseded this one.
            } catch {
                guard generation == self.graphicalNavigationGeneration else { return }
                self.workingDirectory = self.shellWorkingDirectory
                self.graphicalOperationIssue = GraphicalOperationIssue(
                    title: "Couldn’t Open Folder",
                    message: error.localizedDescription
                )
            }

            guard generation == self.graphicalNavigationGeneration else { return }
            if let handle = self.handle {
                self.feedTerminalOutput(Self.graphicalNavigationRevealSequence, handle: handle)
            }
            self.isGraphicalNavigationInProgress = false
            self.graphicalNavigationTask = nil
        }
    }

    private func navigateGraphically(to target: String, generation: UInt) async throws {
        guard graphicalMode, let handle else { return }
        // Execute in the real shell so its process state remains authoritative.
        // This bypasses semantic command capture because navigation is a window
        // action rather than a command the user typed. Conceal its transient echo
        // so graphical navigation never exposes the implementation command.
        feedTerminalOutput(Self.graphicalNavigationConcealSequence, handle: handle)
        var shouldRestoreVisibleOutput = true
        var shouldRestoreEcho = gt_session_set_echo(handle, false)
        defer {
            if shouldRestoreEcho { _ = gt_session_set_echo(handle, true) }
            if shouldRestoreVisibleOutput,
               generation == graphicalNavigationGeneration {
                feedTerminalOutput(Self.graphicalNavigationRevealSequence, handle: handle)
            }
        }
        write(Data([0x15]))
        try await Task.sleep(for: .milliseconds(10))
        try Task.checkCancellation()
        if gt_session_poll(handle) { refreshFrame() }
        // Replace the current folder view before asking the shell to enter the
        // next directory. The command and its prompt remain concealed below.
        feedTerminalOutput("\r\u{1B}[2J\u{1B}[H", handle: handle)
        feedTerminalOutput(Self.graphicalNavigationConcealSequence, handle: handle)
        write(Data(("cd -- \(Self.shellQuoted(target))\r").utf8))
        var reachedTarget = false
        for _ in 0..<200 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
            if gt_session_poll(handle) { refreshFrame() }
            if URL(fileURLWithPath: shellWorkingDirectory).standardizedFileURL.path == target {
                reachedTarget = true
                break
            }
        }
        guard reachedTarget else { throw GraphicalOperationError.navigationTimedOut(target) }
        try await drainShellOutput(handle: handle)
        if shouldRestoreEcho {
            _ = gt_session_set_echo(handle, true)
            shouldRestoreEcho = false
        }
        let prompt = try await waitForVisiblePrompt(handle: handle)
        try Task.checkCancellation()

        // Clear the concealed cd and prompt, then restore ordinary rendering.
        // Keep existing blocks and begin a fresh semantic block at this row for
        // the newly opened directory.
        feedTerminalOutput("\r\u{1B}[J", handle: handle)
        feedTerminalOutput(Self.graphicalNavigationRevealSequence, handle: handle)
        shouldRestoreVisibleOutput = false
        gt_session_mark_input(handle)
        // Ghostty only retains a semantic row when it owns at least one cell.
        // Keep that sentinel invisible and outside the listing's content area.
        feedTerminalOutput(
            "\u{1B}[8m\u{1B}[\(terminalColumns)G \u{1B}[28m\r",
            handle: handle
        )
        gt_session_mark_output(handle)
        revision &+= 1
        let request = FileListingRequest(
            path: target,
            showsHidden: graphicalShowsHiddenFiles,
            detailed: false
        )
        guard renderInlineFileListing(
            command: nil,
            request: request,
            handle: handle,
            clearShellInput: false
        ) else { throw GraphicalOperationError.directoryUnavailable(target) }
        feedTerminalOutput(prompt, handle: handle)
        workingDirectory = target
    }

    private func drainShellOutput(handle: OpaquePointer) async throws {
        var quietPolls = 0
        for _ in 0..<40 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
            if gt_session_poll(handle) {
                quietPolls = 0
                refreshFrame()
            } else {
                quietPolls += 1
                if quietPolls >= 3 { return }
            }
        }
    }

    private func waitForVisiblePrompt(handle: OpaquePointer) async throws -> String {
        var candidate: String?
        var stableChecks = 0
        for _ in 0..<160 {
            try Task.checkCancellation()
            if gt_session_poll(handle) { refreshFrame() }
            if let prompt = visiblePromptText(
                handle: handle,
                includesInvisibleCells: true
            ), !prompt.isEmpty {
                if prompt == candidate {
                    stableChecks += 1
                } else {
                    candidate = prompt
                    stableChecks = 1
                }
                if stableChecks >= 2 { return prompt }
            } else {
                candidate = nil
                stableChecks = 0
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw GraphicalOperationError.promptUnavailable
    }

    private func visiblePromptText(
        handle: OpaquePointer,
        includesInvisibleCells: Bool = false
    ) -> String? {
        guard let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells,
              framePointer.pointee.cursor_visible else { return nil }
        let frame = framePointer.pointee
        let row = Int(frame.cursor_y)
        let columns = Int(frame.cols)
        let endColumn = min(Int(frame.cursor_x), columns)
        guard row >= 0, row < Int(frame.rows) else { return nil }

        var prompt = ""
        for column in 0..<endColumn {
            let cell = cells[row * columns + column]
            guard cell.text_len > 0 else { continue }
            let isInvisible = cell.style & UInt16(GT_STYLE_INVISIBLE) != 0
            guard includesInvisibleCells || !isInvisible else { continue }
            prompt += withUnsafeBytes(of: cell.text) { raw in
                String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
            }
        }
        return prompt
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
            "eza", "exa", "lstr", "tree", "dir", "vdir",
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
        let backendListing: GraphicalDirectoryListing? = switch listingBackend {
        case .eza:
            Self.ezaDirectoryListing(at: request.path, showsHidden: request.showsHidden)
        case .lstr:
            Self.lstrDirectoryListing(at: request.path, showsHidden: request.showsHidden)
        }
        let listing = backendListing ?? Self.directoryListing(at: request.path)
        guard listing.error == nil else {
            currentGraphicalListing = nil
            return false
        }
        let visibleItems = listing.items.filter {
            request.showsHidden || !$0.name.hasPrefix(".") || $0.name == ".."
        }
        let sections = Self.graphicalSections(
            visibleItems,
            sortBy: graphicalSortOption,
            groupBy: graphicalGroupOption,
            direction: graphicalSortDirection,
            foldersFirst: graphicalFoldersFirst
        )
        let items = sections.flatMap(\.items)
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
            let pixels = GraphicalFileIcon.pixels(for: kind)
            append("\u{1B}_Ga=t,f=32,s=\(GraphicalFileIcon.pixelSize),v=\(GraphicalFileIcon.pixelSize),i=\(imageID),q=2;")
            append(pixels.base64EncodedString())
            append("\u{1B}\\")
        }

        for section in sections where !section.items.isEmpty {
            if let title = section.title {
                append("\u{1B}[38;2;112;196;198m  \(title)\u{1B}[0m\r\n")
            }
            if request.detailed {
                renderDetailedListing(section.items, imageIDs: imageIDs, append: append)
                append("\r\n")
            } else {
                switch graphicalViewMode {
                case .icons:
                    renderIconListing(section.items, imageIDs: imageIDs, append: append)
                case .list:
                    renderSimpleList(section.items, imageIDs: imageIDs, append: append)
                }
            }
        }
        if items.isEmpty {
            append("\r\n\u{1B}[38;2;112;139;151m  No items in this folder\u{1B}[0m\r\n")
        }

        feedTerminalOutput(output, handle: handle)
        return true
    }

    private func renderFileListing(
        command: String,
        request: FileListingRequest,
        handle: OpaquePointer
    ) -> Bool {
        guard let output = Self.listingOutput(
            for: request,
            terminalColumns: terminalColumns,
            backend: listingBackend
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
        let labelWidth = 9
        let outerMarginColumns = 1
        let iconWidth = 4
        let iconHeight = 2
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
                let tileStart = outerMarginColumns + index * tileWidth
                let iconOffset = (tileWidth - iconWidth) / 2
                let iconColumn = tileStart + iconOffset
                graphicalItemsByPlacementID[placementID] = item
                graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                    leadingColumns: iconOffset,
                    widthColumns: tileWidth,
                    rowHeight: iconHeight + labelRowCount
                )
                append("\u{1B}[\(iconColumn + 1)G")
                append("\u{1B}_Ga=p,i=\(imageID),p=\(placementID),c=\(iconWidth),r=\(iconHeight),C=1,q=2\u{1B}\\")
            }
            for _ in 0..<iconHeight { append("\r\n") }
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
            append("\u{1B}[\(iconColumn + 1)G")
            append("\u{1B}_Ga=p,i=\(imageID),p=\(placementID),c=2,r=1,C=1,q=2\u{1B}\\")
            let name = Self.truncatedGraphicalName(item.name, maximumCharacters: nameWidth)
            graphicalItemsByPlacementID[placementID] = item
            graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                leadingColumns: iconColumn,
                widthColumns: Self.graphicalRowHitWidth(
                    textColumn: textColumn,
                    renderedTextCount: name.count,
                    terminalColumns: terminalColumns
                ),
                rowHeight: 1
            )
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
            graphicalItemsByPlacementID[placementID] = item
            graphicalHitLayoutsByPlacementID[placementID] = GraphicalHitLayout(
                leadingColumns: iconColumn,
                widthColumns: Self.graphicalRowHitWidth(
                    textColumn: textColumn,
                    renderedTextCount: metadata.count + name.count,
                    terminalColumns: terminalColumns
                ),
                rowHeight: 1
            )
            append("\u{1B}[\(textColumn + 1)G")
            append(metadata + Self.labelColor(for: item.kind) + name + "\u{1B}[0m\r\n")
        }
    }

    nonisolated static func graphicalRowHitWidth(
        textColumn: Int,
        renderedTextCount: Int,
        terminalColumns: Int
    ) -> Int {
        let contentWidth = textColumn + renderedTextCount + 1
        return min(max(1, terminalColumns - 2), max(6, contentWidth))
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
        case .directory: "\u{1B}[38;2;151;226;228m"
        case .executable: "\u{1B}[38;2;142;219;166m"
        case .symbolicLink: "\u{1B}[38;2;144;187;225m"
        case .file: "\u{1B}[38;2;204;218;226m"
        }
    }

    nonisolated static func graphicalSections(
        _ items: [GraphicalFileItem],
        sortBy: GraphicalSortOption,
        groupBy: GraphicalGroupOption,
        direction: GraphicalSortDirection,
        foldersFirst: Bool
    ) -> [GraphicalItemSection] {
        let parentItems = items.filter { $0.name == ".." }
        let contentItems = items.filter { $0.name != ".." }
        let sortedContent = contentItems.sorted { left, right in
            if foldersFirst, sortBy == .name {
                let leftDirectory = left.kind == .directory
                let rightDirectory = right.kind == .directory
                if leftDirectory != rightDirectory { return leftDirectory }
            }
            let result = graphicalComparison(left, right, option: sortBy)
            if result == .orderedSame {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return direction == .ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }

        guard let groupOption = groupBy.sortOption else {
            return [GraphicalItemSection(title: nil, items: parentItems + sortedContent)]
        }

        let groupedContent = sortedContent.sorted { left, right in
            let leftTitle = graphicalGroupTitle(for: left, option: groupOption)
            let rightTitle = graphicalGroupTitle(for: right, option: groupOption)
            if leftTitle != rightTitle {
                let comparison = graphicalComparison(left, right, option: groupOption)
                let newestFirst: Bool = switch groupOption {
                case .dateLastOpened, .dateAdded, .dateModified, .dateCreated, .size: true
                case .name, .kind, .tags: false
                }
                if comparison != .orderedSame {
                    return newestFirst
                        ? comparison == .orderedDescending
                        : comparison == .orderedAscending
                }
                return leftTitle.localizedStandardCompare(rightTitle) == .orderedAscending
            }
            let comparison = graphicalComparison(left, right, option: sortBy)
            if comparison == .orderedSame {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }

        var sections: [GraphicalItemSection] = []
        if !parentItems.isEmpty {
            sections.append(GraphicalItemSection(title: nil, items: parentItems))
        }
        for item in groupedContent {
            let title = graphicalGroupTitle(for: item, option: groupOption)
            if sections.last?.title == title {
                let updatedItems = (sections.last?.items ?? []) + [item]
                sections[sections.count - 1] = GraphicalItemSection(title: title, items: updatedItems)
            } else {
                sections.append(GraphicalItemSection(title: title, items: [item]))
            }
        }
        return sections
    }

    nonisolated private static func graphicalComparison(
        _ left: GraphicalFileItem,
        _ right: GraphicalFileItem,
        option: GraphicalSortOption
    ) -> ComparisonResult {
        switch option {
        case .name:
            left.name.localizedStandardCompare(right.name)
        case .kind:
            left.kindDescription.localizedStandardCompare(right.kindDescription)
        case .dateLastOpened:
            left.lastOpened.compare(right.lastOpened)
        case .dateAdded:
            left.added.compare(right.added)
        case .dateModified:
            left.modified.compare(right.modified)
        case .dateCreated:
            left.created.compare(right.created)
        case .size:
            left.size == right.size ? .orderedSame : (left.size < right.size ? .orderedAscending : .orderedDescending)
        case .tags:
            left.tags.joined(separator: ", ").localizedStandardCompare(
                right.tags.joined(separator: ", ")
            )
        }
    }

    nonisolated private static func graphicalGroupTitle(
        for item: GraphicalFileItem,
        option: GraphicalSortOption
    ) -> String {
        switch option {
        case .name:
            guard let first = item.name.first else { return "#" }
            let value = String(first).uppercased()
            return value.rangeOfCharacter(from: .letters) == nil ? "#" : value
        case .kind:
            return item.kindDescription
        case .dateLastOpened:
            return dateGroupTitle(item.lastOpened)
        case .dateAdded:
            return dateGroupTitle(item.added)
        case .dateModified:
            return dateGroupTitle(item.modified)
        case .dateCreated:
            return dateGroupTitle(item.created)
        case .size:
            switch item.size {
            case 0: return "Zero KB"
            case 1..<(100 * 1_024): return "1 KB – 100 KB"
            case (100 * 1_024)..<(1_024 * 1_024): return "100 KB – 1 MB"
            case (1_024 * 1_024)..<(10 * 1_024 * 1_024): return "1 MB – 10 MB"
            case (10 * 1_024 * 1_024)..<(100 * 1_024 * 1_024): return "10 MB – 100 MB"
            case (100 * 1_024 * 1_024)..<(1_024 * 1_024 * 1_024): return "100 MB – 1 GB"
            default: return "1 GB and larger"
            }
        case .tags:
            return item.tags.first ?? "No Tags"
        }
    }

    nonisolated private static func dateGroupTitle(_ date: Date) -> String {
        guard date != .distantPast else { return "Unknown Date" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days >= 0, days < 7 { return "Previous 7 Days" }
        if days >= 0, days < 30 { return "Previous 30 Days" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    nonisolated static func directoryListing(at path: String) -> GraphicalDirectoryListing {
        let manager = FileManager.default
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .localizedTypeDescriptionKey,
                .creationDateKey,
                .contentModificationDateKey,
                .contentAccessDateKey,
                .addedToDirectoryDateKey,
                .tagNamesKey,
            ]
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

    nonisolated static func lstrDirectoryListing(
        at path: String,
        showsHidden: Bool,
        executableURL: URL? = lstrExecutableURL()
    ) -> GraphicalDirectoryListing? {
        guard let executableURL else { return nil }
        let request = FileListingRequest(path: path, showsHidden: showsHidden, detailed: false)
        guard let output = lstrOutput(
            for: request,
            terminalOutput: false,
            executableURL: executableURL
        ), let root = try? JSONDecoder().decode(LstrJSONNode.self, from: output) else {
            return nil
        }

        let fallback = directoryListing(at: path)
        guard fallback.error == nil else { return fallback }
        let visibleItems = fallback.items.filter {
            showsHidden || !$0.name.hasPrefix(".") || $0.name == ".."
        }
        var itemsByName = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.name, $0) })
        var orderedItems: [GraphicalFileItem] = []
        if let parent = itemsByName.removeValue(forKey: "..") {
            orderedItems.append(parent)
        }
        for node in root.contents ?? [] {
            guard let name = node.name, let item = itemsByName.removeValue(forKey: name) else {
                continue
            }
            orderedItems.append(item)
        }
        orderedItems.append(contentsOf: itemsByName.values.sorted {
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
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        executableURL(
            named: "eza",
            configuredBy: "TERMINAL_TABS_EZA_PATH",
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            bundleResourceURL: bundleResourceURL
        )
    }

    nonisolated static func lstrExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        executableURL(
            named: "lstr",
            configuredBy: "TERMINAL_TABS_LSTR_PATH",
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            bundleResourceURL: bundleResourceURL
        )
    }

    nonisolated private static func executableURL(
        named executableName: String,
        configuredBy environmentKey: String,
        environment: [String: String],
        currentDirectoryPath: String,
        bundleResourceURL: URL?
    ) -> URL? {
        var candidates: [URL] = []
        if let configuredPath = environment[environmentKey],
           !configuredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }
        if let bundleResourceURL {
            candidates.append(
                bundleResourceURL
                    .appending(path: "bin", directoryHint: .isDirectory)
                    .appending(path: executableName)
            )
        }
        candidates.append(
            URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appending(path: ".build/bin/\(executableName)")
        )
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appending(path: executableName)
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

        return executableOutput(at: executableURL, arguments: arguments)
    }

    nonisolated static func lstrOutput(
        for request: FileListingRequest,
        terminalOutput: Bool,
        executableURL: URL? = lstrExecutableURL()
    ) -> Data? {
        guard let executableURL else { return nil }
        return executableOutput(
            at: executableURL,
            arguments: lstrArguments(for: request, terminalOutput: terminalOutput)
        )
    }

    nonisolated static func listingOutput(
        for request: FileListingRequest,
        terminalColumns: Int,
        backend: ListingBackend
    ) -> Data? {
        switch backend {
        case .eza:
            ezaOutput(
                for: request,
                terminalColumns: terminalColumns,
                terminalOutput: true
            )
        case .lstr:
            lstrOutput(for: request, terminalOutput: true)
        }
    }

    nonisolated private static func executableOutput(
        at executableURL: URL,
        arguments: [String]
    ) -> Data? {
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

    nonisolated static func lstrArguments(
        for request: FileListingRequest,
        terminalOutput: Bool
    ) -> [String] {
        var arguments = [
            "--color", terminalOutput ? "always" : "never",
            "--dirs-first",
            "--natural-sort",
            "--level", "1",
        ]
        if terminalOutput, request.detailed {
            arguments.append(contentsOf: ["--permissions", "--size"])
        }
        if !terminalOutput {
            arguments.append(contentsOf: ["--output", "json"])
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
        let resourceKeys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey,
            .tagNamesKey,
        ]
        let values = try? url.resourceValues(forKeys: resourceKeys)
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
                : values?.contentModificationDate ?? .distantPast,
            created: values?.creationDate
                ?? attributes?[.creationDate] as? Date
                ?? .distantPast,
            added: values?.addedToDirectoryDate ?? .distantPast,
            lastOpened: values?.contentAccessDate ?? .distantPast,
            kindDescription: values?.localizedTypeDescription
                ?? (kind == .directory ? "Folder" : "Item"),
            tags: values?.tagNames ?? []
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

    func isTerminalBlockCollapsed(_ id: TerminalBlockID) -> Bool {
        collapsedTerminalBlockIDs.contains(id)
    }

    func toggleTerminalBlockCollapsed(_ id: TerminalBlockID) {
        if !collapsedTerminalBlockIDs.insert(id).inserted {
            collapsedTerminalBlockIDs.remove(id)
        }
        revision &+= 1
    }

    func isTerminalBlockBookmarked(_ id: TerminalBlockID) -> Bool {
        bookmarkedTerminalBlockIDs.contains(id)
    }

    func toggleTerminalBlockBookmarked(_ id: TerminalBlockID) {
        if !bookmarkedTerminalBlockIDs.insert(id).inserted {
            bookmarkedTerminalBlockIDs.remove(id)
        }
        revision &+= 1
    }

    var canRunBlockCommand: Bool {
        !isAlternateScreen && isRunning
    }

    func reinputBlockCommand(_ command: String) {
        guard canRunBlockCommand, !command.isEmpty else { return }
        sendUserInput(Data(command.utf8))
    }

    func rerunBlockCommand(_ command: String) {
        guard canRunBlockCommand, !command.isEmpty else { return }
        sendUserInput(Data(command.utf8))
        sendUserInput(Data([0x0D]))
    }

    func clearTerminalView() {
        guard !isAlternateScreen else { return }
        sendUserInput(Data([0x0C]))
    }

    func paste(_ value: String) {
        guard !value.isEmpty else { return }
        if isBracketedPasteEnabled {
            write(Data("\u{1B}[200~\(value)\u{1B}[201~".utf8))
        } else {
            sendUserInput(Data(value.utf8))
        }
    }

    func sendFocus(_ focused: Bool) {
        guard let handle else { return }
        _ = gt_session_send_focus(handle, focused)
    }

    func submittedCommand(matchingRenderedText text: String) -> String? {
        commandBlocks.reversed().first(where: { text.contains($0.command) })?.command
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

    @discardableResult
    func attachToAI(
        command: String,
        output: String,
        workingDirectory: String,
        sourceBlockID: TerminalBlockID? = nil
    ) -> Bool {
        if let sourceBlockID, hasPendingAIAttachment(for: sourceBlockID) {
            isAIChatVisible = true
            return false
        }
        aiAttachments.append(.terminalBlock(TerminalBlockAttachment(
            command: command,
            output: output,
            workingDirectory: workingDirectory,
            sourceBlockID: sourceBlockID
        )))
        isAIChatVisible = true
        aiError = nil
        return true
    }

    func hasPendingAIAttachment(for sourceBlockID: TerminalBlockID) -> Bool {
        aiAttachments.contains { $0.sourceBlockID == sourceBlockID }
    }

    @discardableResult
    func attachFilesToAI(_ urls: [URL]) -> Bool {
        let attachments = urls.compactMap { AIFileAttachment.load(url: $0) }
            .map(AIInputAttachment.file)
        guard !attachments.isEmpty else { return false }
        aiAttachments.append(contentsOf: attachments)
        isAIChatVisible = true
        aiError = nil
        return true
    }

    func removeAIAttachment(_ id: UUID) {
        aiAttachments.removeAll { $0.id == id }
    }

    var canAttachGraphicalOutputToAI: Bool {
        currentGraphicalListing != nil
    }

    var graphicalItemCount: Int? {
        currentGraphicalListing?.items.count
    }

    func attachGraphicalOutputToAI() {
        guard let attachment = graphicalBlockAttachment() else { return }
        attachToAI(
            command: attachment.command,
            output: attachment.output,
            workingDirectory: attachment.workingDirectory
        )
    }

    func graphicalBlockAttachment() -> TerminalBlockAttachment? {
        currentGraphicalListing.map(Self.aiAttachment(for:))
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
        guard (!question.isEmpty || !aiAttachments.isEmpty), !isAIResponding else { return }
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

        let message = AIChatMessage(role: .user, text: question, attachments: aiAttachments)
        aiMessages.append(message)
        aiDraft = ""
        aiAttachments.removeAll()
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
        aiAttachments.removeAll()
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

    var title: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }

    var panelTitle: String {
        switch self {
        case .horizontal: "Top Panel"
        case .vertical: "Side Panel"
        }
    }

    var panelName: String {
        panelTitle.lowercased()
    }

    var panelSystemImage: String {
        switch self {
        case .horizontal: "rectangle.topthird.inset.filled"
        case .vertical: "sidebar.left"
        }
    }
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
    private static let graphicalShowsHiddenFilesKey = "graphicalShowsHiddenFiles"
    private static let graphicalSortOptionKey = "graphicalSortOption"
    private static let graphicalGroupOptionKey = "graphicalGroupOption"
    private static let graphicalSortDirectionKey = "graphicalSortDirection"
    private static let graphicalFoldersFirstKey = "graphicalFoldersFirst"
    private static let listingBackendKey = "listingBackend"
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
    let scheduledJobs: ScheduledJobStore
    @Published var isSettingsVisible = false
    @Published var isScheduledJobsVisible = false
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
    @Published var graphicalShowsHiddenFiles: Bool {
        didSet {
            UserDefaults.standard.set(
                graphicalShowsHiddenFiles,
                forKey: Self.graphicalShowsHiddenFilesKey
            )
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalShowsHiddenFiles(graphicalShowsHiddenFiles)
            }
        }
    }
    @Published var graphicalSortOption: GraphicalSortOption {
        didSet {
            UserDefaults.standard.set(graphicalSortOption.rawValue, forKey: Self.graphicalSortOptionKey)
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalSortOption(graphicalSortOption)
            }
        }
    }
    @Published var graphicalGroupOption: GraphicalGroupOption {
        didSet {
            UserDefaults.standard.set(graphicalGroupOption.rawValue, forKey: Self.graphicalGroupOptionKey)
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalGroupOption(graphicalGroupOption)
            }
        }
    }
    @Published var graphicalSortDirection: GraphicalSortDirection {
        didSet {
            UserDefaults.standard.set(
                graphicalSortDirection.rawValue,
                forKey: Self.graphicalSortDirectionKey
            )
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalSortDirection(graphicalSortDirection)
            }
        }
    }
    @Published var graphicalFoldersFirst: Bool {
        didSet {
            UserDefaults.standard.set(
                graphicalFoldersFirst,
                forKey: Self.graphicalFoldersFirstKey
            )
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setGraphicalFoldersFirst(graphicalFoldersFirst)
            }
        }
    }
    @Published var listingBackend: ListingBackend {
        didSet {
            UserDefaults.standard.set(listingBackend.rawValue, forKey: Self.listingBackendKey)
            for tab in groups.lazy.flatMap(\.tabs) {
                tab.setListingBackend(listingBackend)
            }
        }
    }
    private var timer: Timer?
    private var lastAutomaticTabColorIndex: Int?

    init(scheduledJobs: ScheduledJobStore? = nil) {
        self.scheduledJobs = scheduledJobs ?? ScheduledJobStore()
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
        graphicalShowsHiddenFiles = UserDefaults.standard.bool(
            forKey: Self.graphicalShowsHiddenFilesKey
        )
        graphicalSortOption = GraphicalSortOption(
            rawValue: UserDefaults.standard.string(forKey: Self.graphicalSortOptionKey) ?? ""
        ) ?? .name
        graphicalGroupOption = GraphicalGroupOption(
            rawValue: UserDefaults.standard.string(forKey: Self.graphicalGroupOptionKey) ?? ""
        ) ?? .none
        graphicalSortDirection = GraphicalSortDirection(
            rawValue: UserDefaults.standard.string(forKey: Self.graphicalSortDirectionKey) ?? ""
        ) ?? .ascending
        if UserDefaults.standard.object(forKey: Self.graphicalFoldersFirstKey) == nil {
            graphicalFoldersFirst = true
        } else {
            graphicalFoldersFirst = UserDefaults.standard.bool(forKey: Self.graphicalFoldersFirstKey)
        }
        listingBackend = ListingBackend(
            rawValue: UserDefaults.standard.string(forKey: Self.listingBackendKey) ?? ""
        ) ?? .eza
        newGroup()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.scheduledJobs.setExecutor { [weak self] job in
            self?.launchScheduledJob(job)
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

    var tabPanelVisibilityActionTitle: String {
        "\(isTabBarVisible ? "Hide" : "Show") \(tabOrientation.panelTitle)"
    }

    func setGraphicalMode(_ enabled: Bool) {
        graphicalMode = enabled
    }

    @discardableResult
    func newGroup(startingIn directory: String? = nil) -> TerminalSession {
        let usedNumbers = Set(groups.compactMap { group -> Int? in
            guard group.name.hasPrefix("Group ") else { return nil }
            return Int(group.name.dropFirst("Group ".count))
        })
        let number = (1...).first { !usedNumbers.contains($0) } ?? groups.count + 1
        let tab = makeTab(startingIn: directory)
        let group = TerminalTabGroup(name: "Group \(number)", tabs: [tab])
        groups.append(group)
        selectedGroupID = group.id
        selectedID = tab.id
        return tab
    }

    @discardableResult
    func newTab(
        in groupID: UUID? = nil,
        startingIn directory: String? = nil
    ) -> TerminalSession {
        guard let index = groupIndex(for: groupID ?? selectedGroupID) else {
            return newGroup(startingIn: directory)
        }
        let tab = makeTab(startingIn: directory)
        groups[index].tabs.append(tab)
        groups[index].isCollapsed = false
        selectedGroupID = groups[index].id
        selectedID = tab.id
        return tab
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

    private func makeTab(startingIn directory: String? = nil) -> TerminalSession {
        let tab = TerminalSession(workingDirectory: directory)
        tab.setGraphicalViewMode(graphicalViewMode, refresh: false)
        tab.setGraphicalShowsHiddenFiles(graphicalShowsHiddenFiles, refresh: false)
        tab.setGraphicalSortOption(graphicalSortOption, refresh: false)
        tab.setGraphicalGroupOption(graphicalGroupOption, refresh: false)
        tab.setGraphicalSortDirection(graphicalSortDirection, refresh: false)
        tab.setGraphicalFoldersFirst(graphicalFoldersFirst, refresh: false)
        tab.setListingBackend(listingBackend, refresh: false)
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
        scheduledJobs.launchDueJobs()
        for tab in groups.lazy.flatMap(\.tabs) { tab.poll() }
    }

    private func launchScheduledJob(_ job: ScheduledJob) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var temporaryDirectory: URL?
            do {
                let command = try await job.script.executionCommand()
                let workingDirectory = try self.prepareWorkingDirectory(for: job)
                if job.runLocation == .temporaryFolder {
                    temporaryDirectory = workingDirectory
                }
                let launchCommand = if let temporaryDirectory {
                    Self.temporaryJobCommand(
                        command,
                        workingDirectory: temporaryDirectory
                    )
                } else {
                    command
                }
                let tab = self.newTab(startingIn: workingDirectory.path)
                tab.rename(to: "Scheduled · \(job.summary)")
                try await tab.executeScheduledScript(launchCommand)
                self.scheduledJobs.markLaunched(job.id)
            } catch is CancellationError {
                if let temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
                self.scheduledJobs.markFailed(job.id, message: "The scheduled launch was cancelled.")
            } catch {
                if let temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
                self.scheduledJobs.markFailed(job.id, message: error.localizedDescription)
            }
        }
    }

    private func prepareWorkingDirectory(for job: ScheduledJob) throws -> URL {
        switch job.runLocation {
        case .selectedFolder:
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: job.workingDirectory,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw ScheduledJobError.invalidWorkingDirectory(job.workingDirectory)
            }
            return URL(fileURLWithPath: job.workingDirectory, isDirectory: true)
                .standardizedFileURL
        case .temporaryFolder:
            let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(
                path: "air-job-\(job.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            return directory
        }
    }

    nonisolated static func temporaryJobCommand(
        _ command: String,
        workingDirectory: URL
    ) -> String {
        var delimiter = "__AIR_TEMP_JOB_\(UUID().uuidString.replacing("-", with: ""))__"
        while command.split(whereSeparator: \Character.isNewline).contains(Substring(delimiter)) {
            delimiter += "_"
        }
        let directory = TerminalSession.shellQuoted(workingDirectory.path)
        let home = TerminalSession.shellQuoted(FileManager.default.homeDirectoryForCurrentUser.path)
        return """
        /bin/bash <<'\(delimiter)'
        __air_job_cleanup() {
          cd /
          rm -rf -- \(directory)
        }
        trap __air_job_cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cd -- \(directory)
        \(command)
        \(delimiter)
        cd -- \(home)
        """
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
