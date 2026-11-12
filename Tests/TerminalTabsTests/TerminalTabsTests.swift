import XCTest
import GhosttyBridge
@testable import TerminalTabs

final class TerminalTabsTests: XCTestCase {
    func testAIBlockAttachmentIncludesTerminalContext() {
        let attachment = TerminalBlockAttachment(
            command: "swift test",
            output: "2 failures",
            workingDirectory: "/tmp/project"
        )
        XCTAssertTrue(attachment.promptContent.contains("swift test"))
        XCTAssertTrue(attachment.promptContent.contains("2 failures"))
        XCTAssertTrue(attachment.promptContent.contains("/tmp/project"))
    }

    @MainActor
    func testCapturedTerminalOutputRemovesANSIAndPrompt() {
        let raw = Data("\r\n\u{001B}[31mfailed\u{001B}[0m\r\nuser@host % ".utf8)
        XCTAssertEqual(TerminalSession.cleanTerminalOutput(raw), "failed")
    }

    @MainActor
    func testAttachingBlockOpensAIChat() {
        let session = TerminalSession(cols: 40, rows: 10)
        session.attachToAI(command: "ls", output: "Package.swift", workingDirectory: "/tmp")
        XCTAssertTrue(session.isAIChatVisible)
        XCTAssertEqual(session.aiAttachment?.command, "ls")
        XCTAssertEqual(session.aiAttachment?.output, "Package.swift")
    }

    func testGraphicalDirectoryListingCreatesAIAttachment() {
        let listing = GraphicalDirectoryListing(
            path: "/tmp/project",
            items: [
                GraphicalFileItem(
                    path: "/tmp/project/Sources",
                    name: "Sources",
                    kind: .directory,
                    permissions: "drwxr-xr-x",
                    size: 96
                ),
                GraphicalFileItem(
                    path: "/tmp/project/Package.swift",
                    name: "Package.swift",
                    kind: .file,
                    permissions: "-rw-r--r--",
                    size: 512
                ),
            ],
            error: nil,
            isLoading: false
        )

        let attachment = TerminalSession.aiAttachment(for: listing)

        XCTAssertEqual(attachment.workingDirectory, "/tmp/project")
        XCTAssertTrue(attachment.command.contains("ls -la"))
        XCTAssertTrue(attachment.output.contains("Sources"))
        XCTAssertTrue(attachment.output.contains("Package.swift"))
    }

    @MainActor
    func testTabCanBeRenamedAndReset() {
        let session = TerminalSession(cols: 40, rows: 10)
        session.rename(to: "Server")
        XCTAssertEqual(session.title, "Server")
        session.rename(to: "  ")
        XCTAssertFalse(session.title.isEmpty)
    }

    func testGraphicalDirectoryListingClassifiesItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tabs-graphical-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("README.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("hello".utf8)))
        let link = root.appendingPathComponent("docs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        let listing = TerminalSession.directoryListing(at: root.path)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.items.first?.name, "..")
        XCTAssertEqual(listing.items.first?.path, root.deletingLastPathComponent().path)
        XCTAssertEqual(listing.items.first(where: { $0.name == "project" })?.kind, .directory)
        XCTAssertEqual(listing.items.first(where: { $0.name == "README.md" })?.kind, .file)
        XCTAssertEqual(listing.items.first(where: { $0.name == "docs" })?.kind, .symbolicLink)
        XCTAssertEqual(listing.items.first(where: { $0.name == "project" })?.permissions.count, 10)
    }

    func testGraphicalDirectoryShellQuotesPaths() {
        XCTAssertEqual(
            TerminalSession.shellQuoted("/tmp/it's here"),
            "'/tmp/it'\\''s here'"
        )
    }

    func testGraphicalLabelsWrapAndPreserveFileType() {
        XCTAssertEqual(
            TerminalSession.graphicalLabelLines(name: "README.md", maxWidth: 14),
            ["README.md"]
        )
        let wrapped = TerminalSession.graphicalLabelLines(
            name: "an-extremely-long-filename-for-testing.swift",
            maxWidth: 14
        )
        XCTAssertLessThanOrEqual(wrapped.count, 2)
        XCTAssertTrue(wrapped.allSatisfy { $0.count <= 14 })
        XCTAssertTrue(wrapped.joined().hasSuffix("…g.swift"))
    }

    func testGraphicalLabelsPreserveLastCharacterWithoutFileType() {
        let wrapped = TerminalSession.graphicalLabelLines(
            name: "a-very-long-directory-name",
            maxWidth: 10
        )
        XCTAssertEqual(wrapped.count, 2)
        XCTAssertTrue(wrapped.joined().hasSuffix("…e"))
    }

    func testGraphicalPasteDestinationDoesNotOverwriteExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tabs-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.txt")
        let firstCopy = root.appendingPathComponent("note copy.txt")
        try Data("one".utf8).write(to: source)
        try Data("two".utf8).write(to: firstCopy)

        let destination = TerminalSession.availablePasteDestination(for: source, in: root)
        XCTAssertEqual(destination.lastPathComponent, "note copy 2.txt")
    }

    @MainActor
    func testGraphicalCopyAndPasteCopiesFolderContents() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tabs-copy-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("contents".utf8).write(to: source.appendingPathComponent("file.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = NSPasteboard(name: .init("TerminalTabsTests.\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        let session = TerminalSession(cols: 20, rows: 8)
        session.copyGraphicalItem(
            GraphicalFileItem(path: source.path, name: "Source", kind: .directory),
            pasteboard: pasteboard
        )
        let pasted = session.pasteGraphicalItems(
            onto: GraphicalFileItem(
                path: destination.path,
                name: "Destination",
                kind: .directory
            ),
            pasteboard: pasteboard
        )

        XCTAssertTrue(pasted)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Source/file.txt").path
        ))
    }

    @MainActor
    func testActivatingGraphicalDirectoryRunsCD() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 40, rows: 10)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        session.setGraphicalMode(true)
        var imageCount = 0
        for _ in 0..<100 where imageCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
            imageCount = gt_session_frame(try XCTUnwrap(session.handle)).map {
                Int($0.pointee.image_count)
            } ?? 0
        }
        let target = FileManager.default.currentDirectoryPath + "/Scripts"
        session.activateGraphicalItem(
            GraphicalFileItem(path: target, name: "Scripts", kind: .directory)
        )
        for _ in 0..<100 where session.workingDirectory != target {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        XCTAssertEqual(session.workingDirectory, target)

        var navigatedImageCount = 0
        for _ in 0..<100 where navigatedImageCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
            navigatedImageCount = gt_session_frame(try XCTUnwrap(session.handle)).map {
                Int($0.pointee.image_count)
            } ?? 0
        }
        XCTAssertGreaterThan(navigatedImageCount, 0)

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        let frame = try XCTUnwrap(gt_session_frame(try XCTUnwrap(session.handle))).pointee
        let visibleRows = (0..<Int(frame.rows)).map {
            rowText(frame: frame, row: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            !$0.isEmpty
        }
        XCTAssertGreaterThanOrEqual(visibleRows.count, 2)
        XCTAssertNotEqual(
            visibleRows.last,
            visibleRows.dropLast().last,
            "Graphical navigation should not render duplicate prompt rows"
        )
    }

    @MainActor
    func testEnablingGraphicalModeImmediatelyShowsCurrentDirectory() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 80, rows: 24)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        session.setGraphicalMode(true)
        var imageCount = 0
        for _ in 0..<100 where imageCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
            imageCount = gt_session_frame(try XCTUnwrap(session.handle)).map {
                Int($0.pointee.image_count)
            } ?? 0
        }
        XCTAssertGreaterThan(imageCount, 0)
        let frame = try XCTUnwrap(gt_session_frame(try XCTUnwrap(session.handle))).pointee
        let firstImage = try XCTUnwrap(frame.images).pointee
        let hitLayout = session.graphicalItemHitLayout(for: firstImage.placement_id)
        XCTAssertEqual(hitLayout.0, 3)
        XCTAssertEqual(hitLayout.1, 8)
        XCTAssertLessThanOrEqual(hitLayout.2, 3)
    }

    @MainActor
    func testGraphicalModeInterceptsLS() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 40, rows: 10)
        session.graphicalMode = true
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        session.sendUserInput(Data("ls".utf8))
        session.sendUserInput(Data([0x0D]))
        var imageCount = 0
        for _ in 0..<100 where imageCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
            imageCount = gt_session_frame(try XCTUnwrap(session.handle)).map {
                Int($0.pointee.image_count)
            } ?? 0
        }
        XCTAssertGreaterThan(imageCount, 0)
    }

    func testGraphicalModeRecognizesFileListingCommands() {
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(TerminalSession.fileListingPath(for: "ls -la", workingDirectory: cwd), cwd)
        XCTAssertEqual(TerminalSession.fileListingPath(for: "ll", workingDirectory: cwd), cwd)
        XCTAssertEqual(TerminalSession.fileListingPath(for: "eza --icons", workingDirectory: cwd), cwd)
        XCTAssertEqual(TerminalSession.fileListingPath(for: "ez a", workingDirectory: cwd), cwd)
        XCTAssertEqual(TerminalSession.fileListingPath(for: "lstr", workingDirectory: cwd), cwd)
        XCTAssertEqual(TerminalSession.fileListingPath(for: "lsd -la", workingDirectory: cwd), cwd)
        XCTAssertEqual(
            TerminalSession.fileListingPath(for: "tree Scripts", workingDirectory: cwd),
            URL(fileURLWithPath: cwd).appendingPathComponent("Scripts").path
        )
        XCTAssertNil(TerminalSession.fileListingPath(for: "printf hello", workingDirectory: cwd))
    }

    func testGraphicalListingPreservesCommandLayoutOptions() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let plain = try XCTUnwrap(TerminalSession.fileListingRequest(
            for: "ls",
            workingDirectory: cwd
        ))
        XCTAssertFalse(plain.showsHidden)
        XCTAssertFalse(plain.detailed)

        let all = try XCTUnwrap(TerminalSession.fileListingRequest(
            for: "ls -a",
            workingDirectory: cwd
        ))
        XCTAssertTrue(all.showsHidden)
        XCTAssertFalse(all.detailed)

        let long = try XCTUnwrap(TerminalSession.fileListingRequest(
            for: "ll",
            workingDirectory: cwd
        ))
        XCTAssertFalse(long.showsHidden)
        XCTAssertTrue(long.detailed)

        let longAll = try XCTUnwrap(TerminalSession.fileListingRequest(
            for: "ls -la",
            workingDirectory: cwd
        ))
        XCTAssertTrue(longAll.showsHidden)
        XCTAssertTrue(longAll.detailed)
    }

    func testEzaArgumentsPreserveListingLayoutOptions() {
        let request = FileListingRequest(path: "/tmp/project", showsHidden: true, detailed: true)

        let terminalArguments = TerminalSession.ezaArguments(
            for: request,
            terminalColumns: 96,
            terminalOutput: true
        )
        XCTAssertTrue(terminalArguments.contains("--long"))
        XCTAssertTrue(terminalArguments.contains("--all"))
        XCTAssertTrue(terminalArguments.contains("--width=96"))
        XCTAssertEqual(terminalArguments.suffix(2), ["--", "/tmp/project"])

        let graphicalArguments = TerminalSession.ezaArguments(
            for: request,
            terminalColumns: 96,
            terminalOutput: false
        )
        XCTAssertTrue(graphicalArguments.contains("--oneline"))
        XCTAssertTrue(graphicalArguments.contains("--absolute=on"))
        XCTAssertTrue(graphicalArguments.contains("--no-quotes"))
    }

    func testEzaExecutableUsesConfiguredPath() {
        let executable = TerminalSession.ezaExecutableURL(
            environment: ["TERMINAL_TABS_EZA_PATH": "/bin/ls", "PATH": ""],
            currentDirectoryPath: "/tmp"
        )
        XCTAssertEqual(executable?.path, "/bin/ls")
    }

    func testLstrArgumentsPreserveListingLayoutOptions() {
        let request = FileListingRequest(path: "/tmp/project", showsHidden: true, detailed: true)

        let terminalArguments = TerminalSession.lstrArguments(
            for: request,
            terminalOutput: true
        )
        XCTAssertTrue(terminalArguments.contains("--permissions"))
        XCTAssertTrue(terminalArguments.contains("--size"))
        XCTAssertTrue(terminalArguments.contains("--all"))
        XCTAssertFalse(terminalArguments.contains("json"))
        XCTAssertEqual(terminalArguments.suffix(2), ["--", "/tmp/project"])

        let graphicalArguments = TerminalSession.lstrArguments(
            for: request,
            terminalOutput: false
        )
        XCTAssertTrue(graphicalArguments.contains("--output"))
        XCTAssertTrue(graphicalArguments.contains("json"))
        XCTAssertTrue(graphicalArguments.contains("--dirs-first"))
        XCTAssertTrue(graphicalArguments.contains("--natural-sort"))
    }

    func testLstrExecutableUsesConfiguredPath() {
        let executable = TerminalSession.lstrExecutableURL(
            environment: ["TERMINAL_TABS_LSTR_PATH": "/bin/ls", "PATH": ""],
            currentDirectoryPath: "/tmp"
        )
        XCTAssertEqual(executable?.path, "/bin/ls")
    }

    func testBundledEzaOrdersGraphicalDirectoryListing() throws {
        let executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/bin/eza")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("The bundled eza executable has not been built.")
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-eza-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources"),
            withIntermediateDirectories: false
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appending(path: "Package.swift").path,
            contents: Data()
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appending(path: ".hidden").path,
            contents: Data()
        ))

        let visible = try XCTUnwrap(TerminalSession.ezaDirectoryListing(
            at: root.path,
            showsHidden: false,
            executableURL: executableURL
        ))
        XCTAssertEqual(visible.items.map(\.name), ["..", "Sources", "Package.swift"])

        let all = try XCTUnwrap(TerminalSession.ezaDirectoryListing(
            at: root.path,
            showsHidden: true,
            executableURL: executableURL
        ))
        XCTAssertTrue(all.items.contains(where: { $0.name == ".hidden" }))
    }

    func testBundledLstrOrdersGraphicalDirectoryListing() throws {
        let executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/bin/lstr")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("The bundled lstr executable has not been built.")
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-lstr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources"),
            withIntermediateDirectories: false
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appending(path: "Package.swift").path,
            contents: Data()
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appending(path: ".hidden").path,
            contents: Data()
        ))

        let visible = try XCTUnwrap(TerminalSession.lstrDirectoryListing(
            at: root.path,
            showsHidden: false,
            executableURL: executableURL
        ))
        XCTAssertEqual(visible.items.map(\.name), ["..", "Sources", "Package.swift"])

        let all = try XCTUnwrap(TerminalSession.lstrDirectoryListing(
            at: root.path,
            showsHidden: true,
            executableURL: executableURL
        ))
        XCTAssertTrue(all.items.contains(where: { $0.name == ".hidden" }))
    }

    @MainActor
    func testAdjacentBlockBackgroundsDoNotOverlap() {
        let first = TerminalNSView.blockBackgroundRect(for: 1..<3, cellHeight: 20, width: 400)
        let second = TerminalNSView.blockBackgroundRect(for: 3..<5, cellHeight: 20, width: 400)

        XCTAssertEqual(first.maxY, second.minY)
    }

    @MainActor
    func testGraphicalOpenWithMenuIncludesOtherApplicationPicker() {
        let session = TerminalSession(cols: 40, rows: 10)
        let view = TerminalNSView(session: session)
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Package.swift").path

        let menuItem = view.openWithMenuItem(for: GraphicalFileItem(
            path: path,
            name: "Package.swift",
            kind: .file
        ))

        XCTAssertEqual(menuItem.title, "Open With")
        XCTAssertTrue(menuItem.submenu?.items.contains(where: { $0.title == "Other…" }) == true)
    }

    @MainActor
    func testWorkingDirectoryTracksShellChanges() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 40, rows: 10)
        for _ in 0..<50 {
            usleep(20_000)
            session.poll()
        }
        session.sendUserInput(Data("cd /tmp".utf8))
        session.sendUserInput(Data([0x0D]))
        let expected = Set(["/tmp", "/private/tmp"])
        for _ in 0..<100 where !expected.contains(session.workingDirectory) {
            usleep(20_000)
            session.poll()
        }
        XCTAssertTrue(expected.contains(session.workingDirectory), "actual cwd: \(session.workingDirectory)")
    }

    func testCommandLineTrackerHandlesTypingAndBackspace() {
        var tracker = CommandLineTracker()
        tracker.append(Data("pww".utf8))
        tracker.append(Data([0x7F]))
        tracker.append(Data("d".utf8))
        XCTAssertEqual(tracker.submit(), "pwd")
        XCTAssertEqual(tracker.text, "")
    }

    @MainActor
    func testStoreAlwaysKeepsOneTab() {
        let store = TerminalStore()
        XCTAssertEqual(store.tabs.count, 1)
        store.close()
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotNil(store.selectedID)
    }

    @MainActor
    func testTabSelectionWraps() {
        let store = TerminalStore()
        store.newTab()
        let second = store.selectedID
        store.selectNext(delta: 1)
        XCTAssertEqual(store.selectedID, store.tabs[0].id)
        store.selectNext(delta: -1)
        XCTAssertEqual(store.selectedID, second)
    }

    @MainActor
    func testTabGroupLifecycle() {
        let store = TerminalStore()
        XCTAssertEqual(store.groups.count, 1)
        store.newGroup()
        XCTAssertEqual(store.groups.count, 2)
        let selectedGroupID = try! XCTUnwrap(store.selectedGroupID)
        store.renameGroup(selectedGroupID, to: "Development")
        XCTAssertEqual(store.selectedGroup?.name, "Development")
        store.toggleGroupCollapsed(selectedGroupID)
        XCTAssertTrue(store.selectedGroup?.isCollapsed == true)
        store.selectAndToggleGroup(selectedGroupID)
        XCTAssertFalse(store.selectedGroup?.isCollapsed ?? true)
        store.newTab()
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertFalse(store.selectedGroup?.isCollapsed ?? true)
        store.closeGroup(selectedGroupID)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertNotNil(store.selected)
    }

    @MainActor
    func testTabLayoutCanChangeAndHide() {
        let store = TerminalStore()
        store.tabOrientation = .vertical
        store.isTabBarVisible = false
        store.graphicalViewMode = .list
        XCTAssertEqual(store.tabOrientation, .vertical)
        XCTAssertFalse(store.isTabBarVisible)
        XCTAssertEqual(store.selected?.graphicalViewMode, .list)
        store.tabOrientation = .horizontal
        store.isTabBarVisible = true
        store.graphicalViewMode = .icons
    }

    @MainActor
    func testListingBackendPropagatesToExistingAndNewTabs() {
        let store = TerminalStore()
        let originalBackend = store.listingBackend
        defer { store.listingBackend = originalBackend }

        store.listingBackend = .lstr
        XCTAssertEqual(store.selected?.listingBackend, .lstr)
        store.newTab()
        XCTAssertEqual(store.selected?.listingBackend, .lstr)
    }

    @MainActor
    func testAutocolorAppliesOnlyToNewTabsWhenEnabled() {
        let store = TerminalStore()
        store.autocolorTabs = true
        store.newTab()
        XCTAssertNotNil(store.selected?.tabAccentColor)

        store.autocolorTabs = false
        store.newTab()
        XCTAssertNil(store.selected?.tabAccentColor)
        store.autocolorTabs = true
    }

    @MainActor
    func testShellOutputIsParsedByGhostty() throws {
        if let error = gt_runtime_error() {
            throw XCTSkip(String(cString: error))
        }
        let session = TerminalSession(cols: 80, rows: 24)
        guard let handle = session.handle else {
            return XCTFail(session.error ?? "Could not create terminal session")
        }
        session.write(Data("printf '__ghostty_probe__\\n'\n".utf8))

        var contents = ""
        for _ in 0..<100 {
            usleep(20_000)
            session.poll()
            guard let frame = gt_session_frame(handle), let cells = frame.pointee.cells else { continue }
            contents = (0..<(Int(frame.pointee.cols) * Int(frame.pointee.rows))).map { index in
                let cell = cells[index]
                return withUnsafeBytes(of: cell.text) { raw in
                    String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
                }
            }.joined()
            if contents.contains("__ghostty_probe__") { break }
        }
        XCTAssertTrue(contents.contains("__ghostty_probe__"))
    }

    @MainActor
    func testUserCommandCreatesSemanticBlock() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 80, rows: 24)
        let handle = try XCTUnwrap(session.handle)
        session.sendUserInput(Data("printf block_probe".utf8))
        session.sendUserInput(Data([0x0D]))

        for _ in 0..<50 {
            usleep(10_000)
            session.poll()
        }
        let frame = try XCTUnwrap(gt_session_frame(handle))
        let cells = try XCTUnwrap(frame.pointee.cells)
        let hasInput = (0..<(Int(frame.pointee.cols) * Int(frame.pointee.rows))).contains {
            cells[$0].semantic_content == UInt8(GT_SEMANTIC_INPUT)
        }
        let hasPromptRow = (0..<Int(frame.pointee.rows)).contains {
            frame.pointee.row_semantics?[$0] == 1
        }
        XCTAssertTrue(hasInput)
        XCTAssertTrue(hasPromptRow)
    }

    @MainActor
    func testTypingDoesNotMoveToANewLine() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 80, rows: 24)
        let handle = try XCTUnwrap(session.handle)
        for _ in 0..<50 {
            usleep(10_000)
            session.poll()
        }
        let before = try XCTUnwrap(gt_session_frame(handle)).pointee.cursor_y
        session.sendUserInput(Data("x".utf8))
        for _ in 0..<10 {
            usleep(10_000)
            session.poll()
        }
        let after = try XCTUnwrap(gt_session_frame(handle)).pointee.cursor_y
        XCTAssertEqual(after, before)
    }

    private func rowText(frame: GTFrame, row: Int) -> String {
        guard let cells = frame.cells, row >= 0, row < Int(frame.rows) else { return "" }
        return (0..<Int(frame.cols)).map { column in
            let cell = cells[row * Int(frame.cols) + column]
            return withUnsafeBytes(of: cell.text) { raw in
                String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
            }
        }.joined()
    }

}
