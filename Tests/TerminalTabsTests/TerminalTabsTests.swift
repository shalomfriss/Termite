import AppKit
import XCTest
import GhosttyBridge
@testable import Air

final class AirTests: XCTestCase {
    @MainActor
    func testAlternateScreenExposesFullScreenApplicationInputModes() throws {
        let session = TerminalSession(cols: 40, rows: 10)
        let handle = try XCTUnwrap(session.handle)
        let enterApplicationMode = Data(
            "\u{1B}[?1049h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?1004h\u{1B}[?2004h".utf8
        )
        enterApplicationMode.withUnsafeBytes { bytes in
            _ = gt_session_feed_output(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }

        session.refreshFrame()

        XCTAssertTrue(session.isAlternateScreen)
        XCTAssertTrue(session.isMouseReporting)
        XCTAssertTrue(session.isBracketedPasteEnabled)
        XCTAssertTrue(gt_session_frame(handle)?.pointee.focus_reporting == true)

        let recordedBlockCount = session.commandBlocks.count
        session.sendUserInput(Data("x".utf8))
        XCTAssertEqual(session.commandBlocks.count, recordedBlockCount)

        let leaveApplicationMode = Data(
            "\u{1B}[?2004l\u{1B}[?1004l\u{1B}[?1002l\u{1B}[?1049l".utf8
        )
        leaveApplicationMode.withUnsafeBytes { bytes in
            _ = gt_session_feed_output(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        session.refreshFrame()

        XCTAssertFalse(session.isAlternateScreen)
        XCTAssertFalse(session.isMouseReporting)
        XCTAssertFalse(session.isBracketedPasteEnabled)
    }

    @MainActor
    func testMicroRunsAsInteractiveFullScreenBlock() async throws {
        let microPath = "/opt/homebrew/bin/micro"
        guard FileManager.default.isExecutableFile(atPath: microPath) else {
            throw XCTSkip("micro is not installed")
        }
        let file = FileManager.default.temporaryDirectory
            .appending(path: "air-micro-test-\(UUID().uuidString).txt")
        try Data("editable\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let session = TerminalSession(cols: 80, rows: 24)
        let handle = try XCTUnwrap(session.handle)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }

        session.sendUserInput(Data("\(microPath) \(TerminalSession.shellQuoted(file.path))".utf8))
        session.sendUserInput(Data([0x0D]))
        for _ in 0..<150 where !session.isAlternateScreen {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }

        XCTAssertTrue(session.isAlternateScreen)
        XCTAssertTrue(session.isMouseReporting)
        XCTAssertTrue(session.isBracketedPasteEnabled)
        XCTAssertEqual(session.commandBlocks.last?.command.hasPrefix(microPath), true)

        let capturedBeforeRepaints = gt_session_command_output(handle, nil, 0)
        for _ in 0..<20 {
            session.sendUserInput(Data("\u{1B}[B".utf8))
            try await Task.sleep(for: .milliseconds(10))
            session.poll()
        }
        let capturedAfterRepaints = gt_session_command_output(handle, nil, 0)
        XCTAssertLessThanOrEqual(capturedAfterRepaints, capturedBeforeRepaints + 1_024)

        session.sendUserInput(Data([0x11])) // micro: Ctrl-Q
        for _ in 0..<150 where session.isAlternateScreen {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }

        XCTAssertFalse(session.isAlternateScreen)
    }

    @MainActor
    func testTerminalBlockBookmarksToggleIndependently() {
        let session = TerminalSession(cols: 40, rows: 10)
        let first = TerminalBlockID(sessionID: session.id, historyRow: 2)
        let second = TerminalBlockID(sessionID: session.id, historyRow: 8)

        session.toggleTerminalBlockBookmarked(
            first,
            command: "swift   test\n--parallel",
            output: "85 tests passed",
            workingDirectory: "/tmp/project"
        )
        XCTAssertTrue(session.isTerminalBlockBookmarked(first))
        XCTAssertFalse(session.isTerminalBlockBookmarked(second))
        XCTAssertEqual(session.terminalBlockBookmarks.count, 1)
        XCTAssertEqual(session.terminalBlockBookmarks.first?.title, "swift test --parallel")
        XCTAssertEqual(session.terminalBlockBookmarks.first?.workingDirectory, "/tmp/project")

        let bookmark = session.terminalBlockBookmarks[0]
        session.revealTerminalBlock(bookmark)
        XCTAssertEqual(session.takePendingTerminalBlockNavigation(), first)
        XCTAssertNil(session.takePendingTerminalBlockNavigation())

        session.toggleTerminalBlockBookmarked(first)
        XCTAssertFalse(session.isTerminalBlockBookmarked(first))
        XCTAssertTrue(session.terminalBlockBookmarks.isEmpty)
    }

    func testTerminalBlockActionsCompactAgainstTrailingEdge() {
        let singleAction = TerminalBlockActionLayout.rects(
            actionCount: 1,
            trailingEdge: 492,
            top: 20
        )
        let allActions = TerminalBlockActionLayout.rects(
            actionCount: 5,
            trailingEdge: 492,
            top: 20
        )

        XCTAssertEqual(singleAction.count, 1)
        XCTAssertEqual(singleAction[0].maxX, 482)
        XCTAssertEqual(allActions.last?.maxX, 482)
        XCTAssertEqual(allActions[1].minX - allActions[0].maxX, 4)
    }

    func testTerminalBlockBookmarkScrollDeltaMovesInEitherDirection() {
        XCTAssertEqual(
            TerminalSession.terminalBlockScrollDelta(from: 10, to: 25),
            15
        )
        XCTAssertEqual(
            TerminalSession.terminalBlockScrollDelta(from: 10, to: 3),
            -7
        )
    }

    @MainActor
    func testRevealingTerminalBlockBookmarkScrollsTowardItsHistoryRow() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 40, rows: 6)
        let handle = try XCTUnwrap(session.handle)
        let output = Data(
            (0..<40).map { "line \($0)\r\n" }.joined().utf8
        )
        output.withUnsafeBytes { bytes in
            _ = gt_session_feed_output(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        session.refreshFrame()

        let initialOffset = try XCTUnwrap(gt_session_frame(handle)).pointee.scroll_offset
        XCTAssertGreaterThan(initialOffset, 4)
        let targetRow = initialOffset - 4
        let bookmark = TerminalBlockBookmark(
            id: TerminalBlockID(sessionID: session.id, historyRow: targetRow),
            command: "line 30",
            output: "",
            workingDirectory: "/tmp"
        )

        session.revealTerminalBlock(bookmark)

        let revealedOffset = try XCTUnwrap(gt_session_frame(handle)).pointee.scroll_offset
        XCTAssertLessThan(revealedOffset, initialOffset)
        XCTAssertEqual(session.takePendingTerminalBlockNavigation(), bookmark.id)
    }

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
        guard case .terminalBlock(let attachment) = session.aiAttachments.first else {
            return XCTFail("Expected a terminal block attachment")
        }
        XCTAssertEqual(attachment.command, "ls")
        XCTAssertEqual(attachment.output, "Package.swift")

        session.attachToAI(command: "pwd", output: "/tmp", workingDirectory: "/tmp")
        XCTAssertEqual(session.aiAttachments.count, 2)
    }

    @MainActor
    func testSameTerminalBlockCannotBeAttachedTwice() {
        let session = TerminalSession(cols: 40, rows: 10)
        let firstBlock = TerminalBlockID(sessionID: session.id, historyRow: 12)
        let secondBlock = TerminalBlockID(sessionID: session.id, historyRow: 18)

        XCTAssertTrue(session.attachToAI(
            command: "pwd",
            output: "/tmp",
            workingDirectory: "/tmp",
            sourceBlockID: firstBlock
        ))
        XCTAssertFalse(session.attachToAI(
            command: "pwd",
            output: "/tmp",
            workingDirectory: "/tmp",
            sourceBlockID: firstBlock
        ))
        XCTAssertEqual(session.aiAttachments.count, 1)
        XCTAssertTrue(session.hasPendingAIAttachment(for: firstBlock))

        XCTAssertTrue(session.attachToAI(
            command: "pwd",
            output: "/tmp",
            workingDirectory: "/tmp",
            sourceBlockID: secondBlock
        ))
        XCTAssertEqual(session.aiAttachments.count, 2)
    }

    @MainActor
    func testFilesAndFoldersCanBeAttachedToAI() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-ai-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "notes.txt")
        try Data("important context".utf8).write(to: file)

        let session = TerminalSession(cols: 40, rows: 10)
        XCTAssertTrue(session.attachFilesToAI([file, root]))
        XCTAssertEqual(session.aiAttachments.count, 2)
        let promptContent = session.aiAttachments.map(\.promptContent).joined()
        XCTAssertTrue(promptContent.contains("important context"))
        XCTAssertTrue(promptContent.contains("notes.txt"))
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

    func testGraphicalRowHighlightFitsRenderedContent() {
        let width = TerminalSession.graphicalRowHitWidth(
            textColumn: 4,
            renderedTextCount: 12,
            terminalColumns: 80
        )

        XCTAssertEqual(width, 17)
        XCTAssertLessThan(width, 78)
        XCTAssertEqual(
            TerminalSession.graphicalRowHitWidth(
                textColumn: 4,
                renderedTextCount: 120,
                terminalColumns: 80
            ),
            78
        )
    }

    func testGraphicalPreviewWidthStaysWithinUsableBounds() {
        XCTAssertEqual(
            GraphicalPreviewSizing.clampedWidth(100, containerWidth: 1_000),
            240
        )
        XCTAssertEqual(
            GraphicalPreviewSizing.clampedWidth(900, containerWidth: 1_000),
            662
        )
        XCTAssertEqual(
            GraphicalPreviewSizing.clampedWidth(360, containerWidth: 1_000),
            360
        )
        XCTAssertEqual(
            GraphicalPreviewSizing.clampedWidth(360, containerWidth: 300),
            240
        )
    }

    func testTextFileDocumentLoadsAndSavesUsingOriginalEncoding() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "air-text-preview-\(UUID().uuidString).txt"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try "hello".write(to: url, atomically: true, encoding: .utf16)
        let document = try TextFileDocument.load(from: url)
        XCTAssertEqual(document.text, "hello")

        try document.write("updated", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf16), "updated")
    }

    func testCodePreviewFileDetectionRecognizesSourceAndConfigFiles() {
        XCTAssertTrue(CodePreviewFileDetector.isCodeFile(URL(fileURLWithPath: "/tmp/App.swift")))
        XCTAssertTrue(CodePreviewFileDetector.isCodeFile(URL(fileURLWithPath: "/tmp/Dockerfile")))
        XCTAssertTrue(CodePreviewFileDetector.isCodeFile(URL(fileURLWithPath: "/tmp/config.json")))
        XCTAssertFalse(CodePreviewFileDetector.isCodeFile(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testMarkdownPreviewFileDetectionRecognizesMarkdownExtensions() {
        XCTAssertTrue(
            MarkdownPreviewFileDetector.isMarkdownFile(
                URL(fileURLWithPath: "/tmp/README.md")
            )
        )
        XCTAssertTrue(
            MarkdownPreviewFileDetector.isMarkdownFile(
                URL(fileURLWithPath: "/tmp/Guide.MARKDOWN")
            )
        )
        XCTAssertFalse(
            MarkdownPreviewFileDetector.isMarkdownFile(
                URL(fileURLWithPath: "/tmp/notes.txt")
            )
        )
    }

    @MainActor
    func testMarkdownRendererCreatesStyledBlocksAndLinks() throws {
        let rendered = try MarkdownRenderer.attributedString(
            for: "# Title\n\n- One\n- Two\n\n[OpenAI](https://openai.com)",
            baseURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertEqual(rendered.string, "Title\n• One\n• Two\nOpenAI")
        let titleFont = try XCTUnwrap(
            rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertGreaterThan(titleFont.pointSize, 13)
        let linkRange = (rendered.string as NSString).range(of: "OpenAI")
        XCTAssertEqual(
            rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://openai.com")
        )
    }

    @MainActor
    func testCodeSyntaxHighlightingSeparatesKeywordsStringsAndComments() throws {
        let source = "let value = \"let\" // let"
        let highlighted = CodeSyntaxHighlighter.attributedString(
            for: source,
            highlightsSyntax: true
        )
        let string = source as NSString
        let keywordIndex = string.range(of: "let").location
        let identifierIndex = string.range(of: "value").location
        let quotedKeywordIndex = string.range(of: "\"let\"").location + 1
        let commentIndex = string.range(of: "//").location

        let keywordColor = try XCTUnwrap(
            highlighted.attribute(.foregroundColor, at: keywordIndex, effectiveRange: nil) as? NSColor
        )
        let baseColor = try XCTUnwrap(
            highlighted.attribute(.foregroundColor, at: identifierIndex, effectiveRange: nil) as? NSColor
        )
        let stringColor = try XCTUnwrap(
            highlighted.attribute(.foregroundColor, at: quotedKeywordIndex, effectiveRange: nil) as? NSColor
        )
        let commentColor = try XCTUnwrap(
            highlighted.attribute(.foregroundColor, at: commentIndex, effectiveRange: nil) as? NSColor
        )

        XCTAssertNotEqual(keywordColor, baseColor)
        XCTAssertNotEqual(stringColor, keywordColor)
        XCTAssertNotEqual(commentColor, stringColor)
    }

    func testActivePromptReceivesBlockBeforeTypingBegins() {
        let ranges = TerminalBlockRangeResolver.ranges(
            rowSemantics: [0, 1, 0, 0, 0, 0],
            visibleRows: [false, true, true, true, true, false],
            cursorRow: 4
        )

        XCTAssertEqual(ranges, [1..<4, 4..<5])
    }

    func testLeadingGraphicalOutputReceivesBlockBeforeFirstPrompt() {
        let ranges = TerminalBlockRangeResolver.ranges(
            rowSemantics: [0, 0, 1, 0],
            visibleRows: [true, true, true, false],
            cursorRow: 2
        )

        XCTAssertEqual(ranges, [0..<2, 2..<3])
    }

    func testGraphicalOutputMergesWithItsActivePrompt() {
        let ranges = TerminalBlockRangeResolver.mergingGraphicalOutputWithActivePrompt(
            ranges: [0..<3, 3..<4],
            graphicalRows: [0, 1, 2],
            cursorRow: 3
        )

        XCTAssertEqual(ranges, [0..<4])
    }

    func testGraphicalOutputDoesNotMergeWithSubmittedCommandBlock() {
        let ranges = TerminalBlockRangeResolver.mergingGraphicalOutputWithActivePrompt(
            ranges: [0..<3, 3..<6, 6..<7],
            graphicalRows: [0, 1, 2],
            cursorRow: 6
        )

        XCTAssertEqual(ranges, [0..<3, 3..<6, 6..<7])
    }

    func testGraphicalRowCoverageContainsImageAndLabelRows() {
        let range = TerminalGraphicalRowCoverage.range(
            placementRow: 0,
            cellOffsetY: 4,
            pixelHeight: 32,
            layoutRowHeight: 3,
            rowCount: 8,
            cellHeight: 20
        )

        XCTAssertEqual(range, 0..<3)
    }

    func testGraphicalRowCoverageIncludesNegativeImageOffset() {
        let range = TerminalGraphicalRowCoverage.range(
            placementRow: 2,
            cellOffsetY: -6,
            pixelHeight: 20,
            layoutRowHeight: 1,
            rowCount: 8,
            cellHeight: 20
        )

        XCTAssertEqual(range, 1..<3)
    }

    func testCollapsedBlockLayoutHidesOutputAndPreservesSpacing() {
        let layout = TerminalBlockVisualLayout.make(
            ranges: [0..<3, 3..<5],
            rowCount: 8,
            cellHeight: 20,
            viewportHeight: 500,
            lastContentRow: 5,
            collapsedRangeStarts: [0]
        )

        XCTAssertEqual(layout.hiddenRows, [1, 2])
        XCTAssertEqual(layout.blockFrames[0].height, 60)
        XCTAssertEqual(layout.blockFrames[1].minY - layout.blockFrames[0].maxY, 10)
        XCTAssertEqual(layout.rowOffsets[3], 30)
        XCTAssertEqual(layout.row(at: 40, cellHeight: 20, nearest: false), 0)
    }

    func testCollapsedGraphicalBlockPreservesPromptAfterIcons() {
        let collapsedVisibleRows = TerminalBlockRangeResolver.collapsedVisibleRows(
            ranges: [0..<5, 5..<6],
            collapsedRangeStarts: [0],
            graphicalRows: [0, 1, 2, 3],
            textRows: [2, 3, 4, 5]
        )
        let layout = TerminalBlockVisualLayout.make(
            ranges: [0..<5, 5..<6],
            rowCount: 8,
            cellHeight: 20,
            viewportHeight: 500,
            lastContentRow: 5,
            collapsedRangeStarts: [0],
            collapsedVisibleRows: collapsedVisibleRows
        )

        XCTAssertEqual(collapsedVisibleRows, [0: 4])
        XCTAssertEqual(layout.hiddenRows, [0, 1, 2, 3])
        XCTAssertEqual(layout.blockFrames[0].height, 60)
        XCTAssertEqual(layout.blockFrames[1].minY - layout.blockFrames[0].maxY, 10)
        XCTAssertEqual(layout.row(at: 40, cellHeight: 20, nearest: false), 4)
    }

    func testFinderStyleArrangementSortsAndGroupsItems() {
        let now = Date()
        let items = [
            GraphicalFileItem(
                path: "/tmp/small.txt",
                name: "small.txt",
                kind: .file,
                size: 8,
                modified: now.addingTimeInterval(-3_600),
                kindDescription: "Plain Text Document"
            ),
            GraphicalFileItem(
                path: "/tmp/Folder",
                name: "Folder",
                kind: .directory,
                size: 512,
                modified: now,
                kindDescription: "Folder"
            ),
            GraphicalFileItem(
                path: "/tmp/large.zip",
                name: "large.zip",
                kind: .file,
                size: 2_000_000,
                modified: now.addingTimeInterval(-7_200),
                kindDescription: "ZIP Archive",
                tags: ["Work"]
            ),
        ]

        let sorted = TerminalSession.graphicalSections(
            items,
            sortBy: .size,
            groupBy: .none,
            direction: .descending,
            foldersFirst: false
        )
        XCTAssertEqual(sorted.flatMap(\.items).map(\.name), ["large.zip", "Folder", "small.txt"])

        let grouped = TerminalSession.graphicalSections(
            items,
            sortBy: .name,
            groupBy: .kind,
            direction: .ascending,
            foldersFirst: true
        )
        XCTAssertEqual(Set(grouped.compactMap(\.title)), ["Folder", "Plain Text Document", "ZIP Archive"])
        XCTAssertEqual(GraphicalSortOption.allCases.count, 8)
    }

    func testTerminalTextSelectionExtractsForwardAndReverseRanges() {
        let rows = [
            ["a", "b", "c", "d", " "],
            ["e", "f", "g", "h", " "],
        ]
        let selection = TerminalTextSelection(
            anchor: TerminalTextPosition(row: 8, column: 2),
            extent: TerminalTextPosition(row: 7, column: 1)
        )

        XCTAssertEqual(
            TerminalTextSelectionExtractor.text(
                cellRows: rows,
                firstRow: 7,
                selection: selection
            ),
            "bcd\nefg"
        )
    }

    func testTerminalLinkDetectionFindsBrowserURLsAndTrimsSentencePunctuation() {
        let text = "Open https://example.com/docs?q=air#links). now"
        let matches = TerminalLinkDetector.links(in: text.map(String.init))

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url.absoluteString, "https://example.com/docs?q=air#links")
        XCTAssertEqual(matches.first?.columns, 5..<41)
    }

    func testTerminalLinkDetectionMapsWideCellsAndSupportsWWWAddresses() {
        let cells = ["🚀", "", " "] + "www.example.com/path".map(String.init)
        let matches = TerminalLinkDetector.links(in: cells)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url.absoluteString, "https://www.example.com/path")
        XCTAssertEqual(matches.first?.columns, 3..<23)
    }

    func testTerminalLinkDetectionKeepsBalancedURLParentheses() {
        let value = "https://en.wikipedia.org/wiki/Function_(mathematics)"
        let matches = TerminalLinkDetector.links(in: value.map(String.init))

        XCTAssertEqual(matches.first?.url.absoluteString, value)
        XCTAssertEqual(matches.first?.columns, 0..<value.count)
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
    func testGraphicalDragMovesFileIntoFolderWithoutOverwriting() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tabs-drag-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("drag me".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = TerminalSession(cols: 20, rows: 8)
        session.graphicalMode = true
        let destinationItem = GraphicalFileItem(
            path: destination.path,
            name: destination.lastPathComponent,
            kind: .directory
        )

        XCTAssertTrue(session.canMoveGraphicalItems([source], into: destinationItem))
        XCTAssertTrue(session.moveGraphicalItems([source], into: destinationItem))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("note.txt").path
        ))
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

        let pasteboard = NSPasteboard(name: .init("AirTests.\(UUID().uuidString)"))
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
        let staleViewMarker = "stale-graphical-folder-view"
        let staleViewOutput = Data(
            "\u{1B}[H\(staleViewMarker)\u{1B}[5;1H".utf8
        )
        let handle = try XCTUnwrap(session.handle)
        staleViewOutput.withUnsafeBytes { bytes in
            _ = gt_session_feed_output(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        XCTAssertTrue(
            visibleFrameText(try XCTUnwrap(gt_session_frame(handle)).pointee)
                .contains(staleViewMarker)
        )
        let target = FileManager.default.currentDirectoryPath + "/Scripts"
        session.activateGraphicalItem(
            GraphicalFileItem(path: target, name: "Scripts", kind: .directory)
        )
        var exposedInternalCommand = false
        for _ in 0..<300 where session.isGraphicalNavigationInProgress {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
            if let frame = gt_session_frame(try XCTUnwrap(session.handle))?.pointee {
                exposedInternalCommand = exposedInternalCommand
                    || visibleFrameText(frame).contains("cd --")
            }
        }
        XCTAssertFalse(session.isGraphicalNavigationInProgress)
        XCTAssertFalse(
            exposedInternalCommand,
            "Double-click navigation must not draw its internal cd command"
        )
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
        XCTAssertFalse(
            visibleFrameText(frame).contains(staleViewMarker),
            "Opening a folder should clear the previous graphical view"
        )
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
    func testRapidGraphicalNavigationCancelsStaleRequestAndRemainsUsable() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-navigation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let first = root.appending(path: "First", directoryHint: .isDirectory)
        let second = root.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = TerminalSession(cols: 60, rows: 16)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        session.graphicalMode = true
        session.activateGraphicalItem(GraphicalFileItem(
            path: first.path,
            name: first.lastPathComponent,
            kind: .directory
        ))
        session.activateGraphicalItem(GraphicalFileItem(
            path: second.path,
            name: second.lastPathComponent,
            kind: .directory
        ))

        for _ in 0..<300 where session.isGraphicalNavigationInProgress {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        XCTAssertFalse(session.isGraphicalNavigationInProgress)
        XCTAssertEqual(session.workingDirectory, second.path)
        XCTAssertNil(session.graphicalOperationIssue)

        session.activateGraphicalItem(GraphicalFileItem(
            path: first.path,
            name: first.lastPathComponent,
            kind: .directory
        ))
        for _ in 0..<300 where session.isGraphicalNavigationInProgress {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        XCTAssertFalse(session.isGraphicalNavigationInProgress)
        XCTAssertEqual(session.workingDirectory, first.path)
        XCTAssertNil(session.graphicalOperationIssue)
    }

    @MainActor
    func testGraphicalNavigationConcealsItsInternalCommand() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 60, rows: 12)
        let handle = try XCTUnwrap(session.handle)
        let marker = "cd -- /private/tmp/graphical-navigation-probe"

        TerminalSession.graphicalNavigationConcealSequence.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_feed_output(
                handle,
                base,
                TerminalSession.graphicalNavigationConcealSequence.count
            )
        }
        Data(marker.utf8).withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_feed_output(handle, base, marker.utf8.count)
        }

        let frame = try XCTUnwrap(gt_session_frame(handle)).pointee
        XCTAssertFalse(
            visibleFrameText(frame).contains(marker),
            "The shell command used by graphical navigation must never be drawn"
        )

        TerminalSession.graphicalNavigationRevealSequence.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_feed_output(
                handle,
                base,
                TerminalSession.graphicalNavigationRevealSequence.count
            )
        }
        let visibleMarker = "navigation-finished"
        Data(visibleMarker.utf8).withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = gt_session_feed_output(handle, base, visibleMarker.utf8.count)
        }
        let revealedFrame = try XCTUnwrap(gt_session_frame(handle)).pointee
        XCTAssertTrue(visibleFrameText(revealedFrame).contains(visibleMarker))
    }

    func testGraphicalViewModesExcludeColumns() {
        XCTAssertEqual(GraphicalViewMode.allCases, [.icons, .list])
    }

    @MainActor
    func testGraphicalNavigationStartsANewSemanticBlock() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "air-graphical-block-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let child = root.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: child.appending(path: "item.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let session = TerminalSession(cols: 60, rows: 40, workingDirectory: root.path)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        session.setGraphicalMode(true)
        for _ in 0..<100 where session.graphicalItemCount == nil {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        let initialFrame = try XCTUnwrap(gt_session_frame(try XCTUnwrap(session.handle))).pointee
        let initialBlockCount = TerminalBlockRangeResolver.normalizedSemantics(
            rowSemantics: (0..<Int(initialFrame.rows)).map {
                initialFrame.row_semantics?[$0] ?? 0
            },
            inputRows: semanticInputRows(in: initialFrame)
        ).count { $0 == 1 }

        session.activateGraphicalItem(GraphicalFileItem(
            path: child.path,
            name: child.lastPathComponent,
            kind: .directory
        ))
        for _ in 0..<300 where session.isGraphicalNavigationInProgress {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }

        let navigatedFrame = try XCTUnwrap(gt_session_frame(try XCTUnwrap(session.handle))).pointee
        let navigatedBlockCount = TerminalBlockRangeResolver.normalizedSemantics(
            rowSemantics: (0..<Int(navigatedFrame.rows)).map {
                navigatedFrame.row_semantics?[$0] ?? 0
            },
            inputRows: semanticInputRows(in: navigatedFrame)
        ).count { $0 == 1 }
        XCTAssertGreaterThan(navigatedBlockCount, initialBlockCount)
        XCTAssertGreaterThan(Int(navigatedFrame.image_count), 0)
        XCTAssertEqual(session.workingDirectory, child.path)
    }

    func testLocalFilePassesICloudAvailabilityPreparation() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-local-\(UUID().uuidString).txt")
        try Data("local".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await TerminalSession.ensureUbiquitousItemIsAvailable(at: file)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local")
    }

    @MainActor
    func testEnablingGraphicalModeImmediatelyShowsCurrentDirectory() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 80, rows: 24)
        session.setGraphicalMode(true)
        var imageCount = 0
        for _ in 0..<250 where imageCount == 0 {
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
        XCTAssertEqual(hitLayout.1, 10)
        XCTAssertLessThanOrEqual(hitLayout.2, 4)

        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
        }
        let settledFrame = try XCTUnwrap(gt_session_frame(try XCTUnwrap(session.handle))).pointee
        let visibleRows = (0..<Int(settledFrame.rows)).map {
            rowText(frame: settledFrame, row: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if visibleRows.count >= 2 {
            XCTAssertNotEqual(
                visibleRows.last,
                visibleRows.dropLast().last,
                "A newly opened graphical terminal should show only one prompt"
            )
        }
    }

    @MainActor
    func testCollapsedGraphicalFrameChoosesPreservedPromptRow() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "air-collapsed-graphical-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("preview".utf8).write(to: root.appending(path: "note.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let session = TerminalSession(cols: 60, rows: 24, workingDirectory: root.path)
        session.setGraphicalMode(true)
        var frame: GTFrame?
        for _ in 0..<250 {
            try await Task.sleep(for: .milliseconds(20))
            session.poll()
            guard let candidate = gt_session_frame(try XCTUnwrap(session.handle))?.pointee,
                  candidate.image_count > 0 else { continue }
            frame = candidate
            break
        }

        let settledFrame = try XCTUnwrap(frame)
        let cells = try XCTUnwrap(settledFrame.cells)
        let rowCount = Int(settledFrame.rows)
        let columnCount = Int(settledFrame.cols)
        let textRows = Set((0..<rowCount).filter { row in
            (0..<columnCount).contains { column in
                let cell = cells[row * columnCount + column]
                return cell.text_len > 0 && cell.style & UInt16(GT_STYLE_INVISIBLE) == 0
            }
        })
        var graphicalRows: Set<Int> = []
        if let images = settledFrame.images {
            for index in 0..<Int(settledFrame.image_count) {
                let placement = images[index]
                guard session.graphicalItem(for: placement.placement_id) != nil,
                      let range = TerminalGraphicalRowCoverage.range(
                          placementRow: Int(placement.viewport_row),
                          cellOffsetY: CGFloat(placement.cell_offset_y),
                          pixelHeight: CGFloat(placement.pixel_height),
                          layoutRowHeight: session.graphicalItemHitLayout(
                              for: placement.placement_id
                          ).2,
                          rowCount: rowCount,
                          cellHeight: 20
                      ) else { continue }
                graphicalRows.formUnion(range)
            }
        }
        let visibleRows = (0..<rowCount).map {
            textRows.contains($0) || graphicalRows.contains($0)
        }
        let unresolvedRanges = TerminalBlockRangeResolver.ranges(
            rowSemantics: TerminalBlockRangeResolver.normalizedSemantics(
                rowSemantics: (0..<rowCount).map {
                    settledFrame.row_semantics?[$0] ?? 0
                },
                inputRows: semanticInputRows(in: settledFrame)
            ),
            visibleRows: visibleRows,
            cursorRow: settledFrame.cursor_visible ? Int(settledFrame.cursor_y) : nil
        )
        let ranges = TerminalBlockRangeResolver.mergingGraphicalOutputWithActivePrompt(
            ranges: unresolvedRanges,
            graphicalRows: graphicalRows,
            cursorRow: settledFrame.cursor_visible ? Int(settledFrame.cursor_y) : nil
        )
        let graphicalBlock = try XCTUnwrap(ranges.first { range in
            range.contains { graphicalRows.contains($0) }
        })
        let visibleRowsByBlockStart = TerminalBlockRangeResolver.collapsedVisibleRows(
            ranges: ranges,
            collapsedRangeStarts: [graphicalBlock.lowerBound],
            graphicalRows: graphicalRows,
            textRows: textRows
        )
        let promptRow = try XCTUnwrap(visibleRowsByBlockStart[graphicalBlock.lowerBound])

        XCTAssertGreaterThan(promptRow, graphicalRows.filter(graphicalBlock.contains).max() ?? -1)
        XCTAssertTrue(TerminalSession.looksLikeShellPrompt(rowText(frame: settledFrame, row: promptRow)))
    }

    func testShellPromptReadinessRecognizesCommonPromptStyles() {
        XCTAssertTrue(TerminalSession.looksLikeShellPrompt("user@host project % "))
        XCTAssertTrue(TerminalSession.looksLikeShellPrompt("project ❯"))
        XCTAssertTrue(TerminalSession.looksLikeShellPrompt("$"))
        XCTAssertFalse(TerminalSession.looksLikeShellPrompt("Loading shell configuration"))
        XCTAssertFalse(TerminalSession.looksLikeShellPrompt(""))
    }

    @MainActor
    func testAIPanelResizeKeepsBothPanesUsable() {
        XCTAssertEqual(
            ResizableTerminalAIPane.clampedPanelHeight(100, containerHeight: 800),
            180
        )
        XCTAssertEqual(
            ResizableTerminalAIPane.clampedPanelHeight(700, containerHeight: 800),
            608
        )
        XCTAssertEqual(
            ResizableTerminalAIPane.clampedPanelHeight(320, containerHeight: 800),
            320
        )
    }

    @MainActor
    func testGraphicalFileIconsUseHighResolutionSymbols() {
        let kinds: [GraphicalFileItem.Kind] = [.directory, .file, .executable, .symbolicLink]
        for kind in kinds {
            let pixels = GraphicalFileIcon.pixels(for: kind)
            XCTAssertEqual(pixels.count, GraphicalFileIcon.pixelSize * GraphicalFileIcon.pixelSize * 4)
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains {
                pixels[pixels.index(pixels.startIndex, offsetBy: $0)] > 0
            })
        }
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
        XCTAssertEqual(session.submittedCommand(matchingRenderedText: "prompt % ls"), "ls")
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

    func testListingExecutablesCanLoadFromApplicationResources() throws {
        let resources = FileManager.default.temporaryDirectory.appending(
            path: "air-bundled-tools-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let binaryDirectory = resources.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: resources) }
        for name in ["eza", "lstr"] {
            try FileManager.default.createSymbolicLink(
                at: binaryDirectory.appending(path: name),
                withDestinationURL: URL(fileURLWithPath: "/bin/ls")
            )
        }

        let environment = ["PATH": ""]
        let missingWorkingDirectory = "/private/tmp/air-missing-working-directory"
        XCTAssertEqual(
            TerminalSession.ezaExecutableURL(
                environment: environment,
                currentDirectoryPath: missingWorkingDirectory,
                bundleResourceURL: resources
            ),
            binaryDirectory.appending(path: "eza")
        )
        XCTAssertEqual(
            TerminalSession.lstrExecutableURL(
                environment: environment,
                currentDirectoryPath: missingWorkingDirectory,
                bundleResourceURL: resources
            ),
            binaryDirectory.appending(path: "lstr")
        )
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
        let layout = TerminalBlockVisualLayout.make(
            ranges: [0..<3, 3..<5],
            rowCount: 8,
            cellHeight: 20,
            viewportHeight: 500,
            lastContentRow: 5,
            topInset: TerminalNSView.blockTopInset
        )

        XCTAssertEqual(layout.blockFrames[0].minY, 10)
        XCTAssertEqual(layout.blockFrames[0].height, 100)
        XCTAssertEqual(layout.blockFrames[1].minY - layout.blockFrames[0].maxY, 10)
        XCTAssertEqual(layout.rowOffsets[0], 30)
        XCTAssertEqual(layout.rowOffsets[3], 80)
        XCTAssertEqual(TerminalNSView.blockCornerRadius, 4)
        XCTAssertEqual(first.minX, 8)
        XCTAssertEqual(first.maxX, 392)
        XCTAssertEqual(
            TerminalNSView.blockContentLeadingOffset - first.minX,
            TerminalNSView.blockContentPadding
        )
    }

    @MainActor
    func testGraphicalFileSelectionControlsPreview() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "air-graphical-preview-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let file = root.appending(path: "preview.txt")
        let unknownTextFile = root.appending(path: "preview.unknown-air-text")
        let binaryFile = root.appending(path: "preview.bin")
        let disguisedBinaryFile = root.appending(path: "binary.txt")
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Preview contents".utf8).write(to: file)
        try Data("Unknown text contents".utf8).write(to: unknownTextFile)
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: binaryFile)
        try Data([0x41, 0x00, 0xFF, 0x00]).write(to: disguisedBinaryFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = TerminalSession(cols: 40, rows: 10, workingDirectory: root.path)
        session.graphicalMode = true
        let fileItem = GraphicalFileItem(path: file.path, name: file.lastPathComponent, kind: .file)
        let folderItem = GraphicalFileItem(
            path: folder.path,
            name: folder.lastPathComponent,
            kind: .directory
        )
        let unknownTextItem = GraphicalFileItem(
            path: unknownTextFile.path,
            name: unknownTextFile.lastPathComponent,
            kind: .file
        )
        let binaryItem = GraphicalFileItem(
            path: binaryFile.path,
            name: binaryFile.lastPathComponent,
            kind: .file
        )
        let disguisedBinaryItem = GraphicalFileItem(
            path: disguisedBinaryFile.path,
            name: disguisedBinaryFile.lastPathComponent,
            kind: .file
        )

        session.setGraphicalPreviewItem(fileItem)
        XCTAssertEqual(session.graphicalPreviewItem, fileItem)

        session.setGraphicalPreviewItem(folderItem)
        XCTAssertNil(session.graphicalPreviewItem)

        session.setGraphicalPreviewItem(unknownTextItem)
        XCTAssertEqual(session.graphicalPreviewItem, unknownTextItem)

        session.setGraphicalPreviewItem(binaryItem)
        XCTAssertNil(session.graphicalPreviewItem)

        session.setGraphicalPreviewItem(disguisedBinaryItem)
        XCTAssertNil(session.graphicalPreviewItem)

        session.setGraphicalPreviewItem(fileItem)
        session.setGraphicalMode(false)
        XCTAssertNil(session.graphicalPreviewItem)
    }

    func testBlankTerminalRowsDoNotIncreaseBlockSpacing() {
        let layout = TerminalBlockVisualLayout.make(
            ranges: [0..<2, 4..<6],
            rowCount: 8,
            cellHeight: 20,
            viewportHeight: 500,
            lastContentRow: 5
        )

        XCTAssertEqual(layout.blockFrames[1].minY - layout.blockFrames[0].maxY, 10)
        XCTAssertEqual(layout.hiddenRows, [2, 3])
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
    func testGraphicalFileMenuIncludesCat() {
        let session = TerminalSession(cols: 40, rows: 10)
        let view = TerminalNSView(session: session)
        let file = GraphicalFileItem(
            path: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Package.swift").path,
            name: "Package.swift",
            kind: .file
        )

        let catItem = view.graphicalItemMenu(for: file).items.first { $0.title == "Cat" }

        XCTAssertNotNil(catItem)
        XCTAssertNotNil(catItem?.image)
    }

    @MainActor
    func testGraphicalBinaryFileMenuOmitsCat() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-binary-menu-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appending(path: "payload.bin")
        try Data([0x00, 0x01, 0x7F, 0xFF]).write(to: binary)

        let session = TerminalSession(cols: 40, rows: 10)
        let view = TerminalNSView(session: session)
        let menu = view.graphicalItemMenu(for: GraphicalFileItem(
            path: binary.path,
            name: binary.lastPathComponent,
            kind: .file
        ))

        XCTAssertFalse(menu.items.contains(where: { $0.title == "Cat" }))
    }

    @MainActor
    func testCatGraphicalFileUsesQuotedTerminalCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-cat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TerminalSession(cols: 40, rows: 10)
        session.graphicalMode = true
        let path = root.appending(path: "quote's.txt").path
        try Data("readable text".utf8).write(to: URL(fileURLWithPath: path))

        session.catGraphicalFile(GraphicalFileItem(
            path: path,
            name: "quote's.txt",
            kind: .file
        ))
        for _ in 0..<50 where session.commandBlocks.last?.command == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(session.commandBlocks.last?.command, "cat -- '\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
    }

    @MainActor
    func testCreatingGraphicalFolderUsesCurrentDirectoryAndAvoidsDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-new-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TerminalSession(cols: 40, rows: 10, workingDirectory: root.path)
        session.graphicalMode = true

        let created = try session.createGraphicalFolder(named: "Design Assets")

        XCTAssertEqual(created.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertThrowsError(try session.createGraphicalFolder(named: "Design Assets"))
        XCTAssertThrowsError(try session.createGraphicalFolder(named: "nested/folder"))
    }

    @MainActor
    func testGraphicalFolderMenuMatchesFinderActions() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-menu-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TerminalSession(cols: 40, rows: 10)
        let view = TerminalNSView(session: session)

        let menu = view.graphicalItemMenu(for: GraphicalFileItem(
            path: root.path,
            name: root.lastPathComponent,
            kind: .directory
        ))
        let titles = Set(menu.items.map(\.title))

        XCTAssertTrue(titles.contains("Open"))
        XCTAssertTrue(titles.contains("List"))
        XCTAssertTrue(titles.contains("Open in New Tab"))
        XCTAssertTrue(titles.contains("Show in Finder"))
        XCTAssertTrue(titles.contains("Get Info"))
        XCTAssertTrue(titles.contains("Rename"))
        XCTAssertTrue(titles.contains("Compress “\(root.lastPathComponent)”"))
        XCTAssertTrue(titles.contains("Duplicate"))
        XCTAssertTrue(titles.contains("Quick Look"))
        XCTAssertTrue(titles.contains("Copy"))
        XCTAssertTrue(titles.contains("Paste Item"))
        XCTAssertTrue(titles.contains("Share"))
        XCTAssertTrue(titles.contains("Move to Trash"))
        XCTAssertFalse(titles.contains("Open With"))
    }

    @MainActor
    func testParentFolderMenuOmitsDestructiveActions() {
        let session = TerminalSession(cols: 40, rows: 10)
        let view = TerminalNSView(session: session)
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
        let menu = view.graphicalItemMenu(for: GraphicalFileItem(
            path: parent.path,
            name: "..",
            kind: .directory
        ))
        let titles = Set(menu.items.map(\.title))

        XCTAssertFalse(titles.contains("Rename"))
        XCTAssertFalse(titles.contains("Duplicate"))
        XCTAssertFalse(titles.contains("Move to Trash"))
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Compress") }))
    }

    func testGraphicalFolderRenameAndArchiveDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-operations-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Original", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

        let renamed = try GraphicalFileOperations.rename(original, to: "Renamed")
        XCTAssertEqual(renamed.lastPathComponent, "Renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertThrowsError(try GraphicalFileOperations.rename(renamed, to: ".hidden"))

        let firstArchive = GraphicalFileOperations.archiveDestination(for: renamed)
        try Data().write(to: firstArchive)
        XCTAssertEqual(
            GraphicalFileOperations.archiveDestination(for: renamed).lastPathComponent,
            "Renamed 2.zip"
        )
    }

    func testGraphicalFolderCompressionCreatesZipArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-compress-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("contents".utf8).write(to: folder.appending(path: "file.txt"))

        let archive = try await GraphicalFileOperations.compress(folder)

        XCTAssertEqual(archive.lastPathComponent, "Folder.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
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

    func testGitBranchDetectionWalksParentDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "air-git-status-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let nested = root.appending(path: "Sources/App", directoryHint: .isDirectory)
        let gitDirectory = root.appending(path: ".git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let head = gitDirectory.appending(path: "HEAD")
        try Data("ref: refs/heads/feature/status-bar\n".utf8).write(to: head)
        let featureRef = gitDirectory.appending(path: "refs/heads/feature/status-bar")
        let mainRef = gitDirectory.appending(path: "refs/heads/main")
        try FileManager.default.createDirectory(
            at: featureRef.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("1234567890abcdef\n".utf8).write(to: featureRef)
        try Data("1234567890abcdef\n".utf8).write(to: mainRef)
        try Data(
            "# pack-refs with: peeled fully-peeled sorted\n1234567890abcdef refs/heads/release/1.0\n".utf8
        ).write(to: gitDirectory.appending(path: "packed-refs"))

        XCTAssertEqual(TerminalSession.gitBranchName(at: nested.path), "feature/status-bar")
        XCTAssertEqual(
            TerminalSession.gitLocalBranchNames(at: nested.path),
            ["feature/status-bar", "main", "release/1.0"]
        )
        XCTAssertEqual(
            TerminalSession.gitSwitchCommand(for: "feature/one's-work"),
            "git switch -- 'feature/one'\\''s-work'"
        )

        try Data("1234567890abcdef\n".utf8).write(to: head)
        XCTAssertEqual(TerminalSession.gitBranchName(at: nested.path), "1234567")
    }

    @MainActor
    func testTerminalSessionStartsInRequestedDirectory() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "terminal-tabs-start-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TerminalSession(cols: 40, rows: 10, workingDirectory: root.path)

        for _ in 0..<50 {
            usleep(20_000)
            session.poll()
        }

        XCTAssertEqual(
            URL(fileURLWithPath: session.workingDirectory).resolvingSymlinksInPath().path,
            root.resolvingSymlinksInPath().path
        )
    }

    func testCommandLineTrackerHandlesTypingAndBackspace() {
        var tracker = CommandLineTracker()
        tracker.append(Data("pww".utf8))
        tracker.append(Data([0x7F]))
        tracker.append(Data("d".utf8))
        XCTAssertEqual(tracker.submit(), "pwd")
        XCTAssertEqual(tracker.text, "")
    }

    func testCommandLineTrackerSuppressesPredictionAfterEscapeSequence() {
        var tracker = CommandLineTracker()
        tracker.append(Data("git st".utf8))
        tracker.append(Data([0x1B, 0x5B, 0x41]))

        XCTAssertFalse(tracker.isReliable)
        XCTAssertEqual(tracker.submit(), "")
        XCTAssertTrue(tracker.isReliable)
        XCTAssertEqual(tracker.text, "")
    }

    func testCommandLineTrackerHandlesUnicodeAndSuppressesEditingControls() {
        var tracker = CommandLineTracker()
        tracker.append(Data("echo café".utf8))
        XCTAssertEqual(tracker.submit(), "echo café")

        tracker.append(Data("git status".utf8))
        tracker.append(Data([0x01]))
        XCTAssertFalse(tracker.isReliable)
        XCTAssertEqual(tracker.submit(), "")
    }

    func testCommandHistoryPrefersRecentMatchesAndEnforcesLimit() {
        var history = CommandHistory(limit: 3)
        history.record("git status")
        history.record("git stash")
        history.record("swift test")
        history.record("git status")

        XCTAssertEqual(history.commands, ["git stash", "swift test", "git status"])
        XCTAssertEqual(history.prediction(for: "git s"), "git status")

        history.record("git switch main")
        XCTAssertEqual(history.commands, ["swift test", "git status", "git switch main"])
        XCTAssertEqual(history.prediction(for: "git s"), "git switch main")

        history.setLimit(2)
        XCTAssertEqual(history.commands, ["git status", "git switch main"])
    }

    @MainActor
    func testCommandHistoryStorePersistsSettingsAndCommands() throws {
        let suiteName = "AirTests.CommandHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CommandHistoryStore(
            defaults: defaults,
            predictionEnabled: false,
            limit: 25
        )
        store.setPredictionEnabled(true)
        store.setLimit(25)
        store.record("git status")
        store.record("swift test")
        store.record("git switch main")

        let reloaded = CommandHistoryStore(defaults: defaults)
        XCTAssertTrue(reloaded.isPredictionEnabled)
        XCTAssertEqual(reloaded.limit, 25)
        XCTAssertEqual(reloaded.history.commands, ["git status", "swift test", "git switch main"])
        XCTAssertEqual(reloaded.prediction(for: "git s"), "git switch main")

        reloaded.clear()
        XCTAssertTrue(reloaded.history.commands.isEmpty)
    }

    @MainActor
    func testDisabledCommandHistoryDoesNotRecordOrPredict() {
        let store = CommandHistoryStore(predictionEnabled: false, limit: 25)
        store.record("git status")
        XCTAssertTrue(store.history.commands.isEmpty)
        XCTAssertNil(store.prediction(for: "git"))

        store.setPredictionEnabled(true)
        store.record("git status")
        XCTAssertEqual(store.prediction(for: "git"), "git status")
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
    func testScheduledJobStorePersistsAndLaunchesDueJobOnlyOnce() throws {
        let suiteName = "AirTests.ScheduledJobs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "jobs"
        let store = ScheduledJobStore(userDefaults: defaults, storageKey: storageKey)
        var launchedJobs: [ScheduledJob] = []
        store.setExecutor { launchedJobs.append($0) }
        let runDate = Date.now.addingTimeInterval(60)
        let job = try store.schedule(
            at: runDate,
            script: "printf scheduled",
            workingDirectory: FileManager.default.currentDirectoryPath
        )

        store.launchDueJobs(at: runDate.addingTimeInterval(-1))
        XCTAssertTrue(launchedJobs.isEmpty)

        store.launchDueJobs(at: runDate)
        store.launchDueJobs(at: runDate.addingTimeInterval(1))
        XCTAssertEqual(launchedJobs.map(\.id), [job.id])
        XCTAssertEqual(store.jobs.first?.status, .launching)

        store.markLaunched(job.id, at: runDate)
        let restored = ScheduledJobStore(userDefaults: defaults, storageKey: storageKey)
        XCTAssertEqual(restored.jobs.first?.id, job.id)
        XCTAssertEqual(restored.jobs.first?.status, .launched)
        XCTAssertEqual(restored.jobs.first?.launchedAt, runDate)
    }

    func testCronScheduleParsesRangesStepsAndWeekdays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let schedule = try CronSchedule("*/15 9-17 * * 1-5")
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 16,
            hour: 9,
            minute: 30
        )))
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 21,
            hour: 9,
            minute: 30
        )))

        XCTAssertTrue(schedule.matches(monday, calendar: calendar))
        XCTAssertFalse(schedule.matches(saturday, calendar: calendar))
        XCTAssertThrowsError(try CronSchedule("61 * * * *"))
        XCTAssertThrowsError(try CronSchedule("* * *"))
    }

    @MainActor
    func testCronJobRepeatsAndIsPersistedWithCronLabel() throws {
        let suiteName = "AirTests.CronJobs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        var launchedJobs: [ScheduledJob] = []
        store.setExecutor { launchedJobs.append($0) }
        let job = try store.schedule(
            timing: .cron,
            at: nil,
            cronExpression: "*/5 * * * *",
            script: .pasted("printf cron", language: .bash),
            workingDirectory: FileManager.default.currentDirectoryPath
        )
        let firstRun = try XCTUnwrap(job.scheduledAt)

        store.launchDueJobs(at: firstRun)
        store.launchDueJobs(at: firstRun.addingTimeInterval(30))
        XCTAssertEqual(launchedJobs.map(\.id), [job.id])

        store.markLaunched(job.id, at: firstRun)
        let secondRun = try XCTUnwrap(store.jobs.first?.scheduledAt)
        XCTAssertGreaterThan(secondRun, firstRun)
        XCTAssertEqual(store.jobs.first?.status, .scheduled)
        XCTAssertEqual(store.jobs.first?.timing.title, "Cron Job")

        store.launchDueJobs(at: secondRun)
        XCTAssertEqual(launchedJobs.map(\.id), [job.id, job.id])

        let restored = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        XCTAssertEqual(restored.jobs.first?.cronExpression, "*/5 * * * *")
        XCTAssertEqual(restored.jobs.first?.timing, .cron)
    }

    @MainActor
    func testSavedWorkflowHasNoTimeAndRunsOnlyOnDemand() throws {
        let suiteName = "AirTests.SavedWorkflow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        var launchedJobs: [ScheduledJob] = []
        store.setExecutor { job in
            launchedJobs.append(job)
            store.markLaunched(job.id)
        }
        let job = try store.schedule(
            timing: .manual,
            at: nil,
            script: .pasted("printf workflow", language: .bash),
            workingDirectory: FileManager.default.currentDirectoryPath
        )

        store.launchDueJobs(at: .distantFuture)
        XCTAssertTrue(launchedJobs.isEmpty)
        XCTAssertEqual(store.jobs.first?.status, .saved)
        XCTAssertNil(store.jobs.first?.scheduledAt)
        XCTAssertEqual(store.scheduledCount, 0)

        store.runNow(job.id)
        XCTAssertEqual(launchedJobs.map(\.id), [job.id])
        XCTAssertEqual(store.jobs.first?.status, .saved)
        XCTAssertNil(store.jobs.first?.scheduledAt)

        let restored = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        XCTAssertEqual(restored.jobs.first?.timing, .manual)
        XCTAssertEqual(restored.jobs.first?.status, .saved)
        XCTAssertNil(restored.jobs.first?.scheduledAt)
    }

    func testScheduledScriptDetectionPrefersShebangAndBuildsFileCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "air-script-detection-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let misleadingExtension = directory.appending(path: "automation.sh")
        try Data("#!/usr/bin/env python3\nprint('ready')\n".utf8).write(to: misleadingExtension)
        let extensionlessPython = directory.appending(path: "python-automation")
        try Data("print('ready')\n".utf8).write(to: extensionlessPython)
        let extensionlessShell = directory.appending(path: "shell-automation")
        try Data("echo ready\n".utf8).write(to: extensionlessShell)

        let language = try ScheduledScriptLanguage.detect(at: misleadingExtension)
        let script = ScheduledJobScript.file(at: misleadingExtension, language: language)
        let command = try await script.executionCommand()

        XCTAssertEqual(language, .python)
        XCTAssertEqual(try ScheduledScriptLanguage.detect(at: extensionlessPython), .python)
        XCTAssertEqual(try ScheduledScriptLanguage.detect(at: extensionlessShell), .bash)
        XCTAssertTrue(command.hasPrefix("/usr/bin/env python3 -- "))
        XCTAssertTrue(command.contains("automation.sh"))
    }

    func testLegacyScheduledJobDecodesAsPastedBash() throws {
        let id = UUID()
        let date = Date.now
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "scheduledAt": date.timeIntervalSinceReferenceDate,
            "script": "echo legacy",
            "workingDirectory": "/tmp",
            "status": "scheduled",
            "createdAt": date.timeIntervalSinceReferenceDate,
        ])

        let job = try JSONDecoder().decode(ScheduledJob.self, from: data)

        XCTAssertEqual(job.id, id)
        XCTAssertEqual(job.script.source, .pasted)
        XCTAssertEqual(job.script.language, .bash)
        XCTAssertEqual(job.script.pastedText, "echo legacy")
        XCTAssertEqual(job.runLocation, .selectedFolder)
        XCTAssertEqual(job.timing, .scheduled)
        XCTAssertEqual(job.scheduledAt, date)
    }

    @MainActor
    func testDueScheduledJobCreatesNewShellAndExecutesScript() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let suiteName = "AirTests.ScheduledShell.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jobStore = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        let terminalStore = TerminalStore(scheduledJobs: jobStore)
        terminalStore.graphicalMode = false
        let initialTabCount = terminalStore.groups.lazy.flatMap(\.tabs).count
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "terminal-tabs-scheduled-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "result.txt")
        let job = try jobStore.schedule(
            at: .now.addingTimeInterval(-1),
            script: "printf scheduled-job > result.txt",
            workingDirectory: directory.path
        )

        jobStore.launchDueJobs()
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(20))
            for tab in terminalStore.groups.lazy.flatMap(\.tabs) { tab.poll() }
        }

        XCTAssertEqual(terminalStore.groups.lazy.flatMap(\.tabs).count, initialTabCount + 1)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "scheduled-job")
        XCTAssertEqual(jobStore.jobs.first(where: { $0.id == job.id })?.status, .launched)
        XCTAssertTrue(terminalStore.selected?.title.hasPrefix("Scheduled ·") == true)
    }

    @MainActor
    func testPastedPythonScheduledJobUsesPythonInterpreter() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let pythonProbe = Process()
        pythonProbe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        pythonProbe.arguments = ["python3", "--version"]
        pythonProbe.standardOutput = FileHandle.nullDevice
        pythonProbe.standardError = FileHandle.nullDevice
        try pythonProbe.run()
        pythonProbe.waitUntilExit()
        guard pythonProbe.terminationStatus == 0 else {
            throw XCTSkip("python3 is not available")
        }

        let suiteName = "AirTests.ScheduledPython.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jobStore = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        let terminalStore = TerminalStore(scheduledJobs: jobStore)
        terminalStore.graphicalMode = false
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "air-scheduled-python-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "python-result.txt")
        let script = "from pathlib import Path\nPath('python-result.txt').write_text('python-ready')"
        let job = try jobStore.schedule(
            at: .now.addingTimeInterval(-1),
            script: .pasted(script, language: .python),
            workingDirectory: directory.path
        )

        jobStore.launchDueJobs()
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: output.path) {
            try await Task.sleep(for: .milliseconds(20))
            for tab in terminalStore.groups.lazy.flatMap(\.tabs) { tab.poll() }
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "python-ready")
        XCTAssertEqual(jobStore.jobs.first(where: { $0.id == job.id })?.status, .launched)
    }

    @MainActor
    func testTemporaryScheduledJobRunsInTmpAndRemovesItsDirectory() async throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let suiteName = "AirTests.ScheduledTemporary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jobStore = ScheduledJobStore(userDefaults: defaults, storageKey: "jobs")
        let terminalStore = TerminalStore(scheduledJobs: jobStore)
        terminalStore.graphicalMode = false
        let marker = URL(fileURLWithPath: "/tmp").appending(
            path: "air-temp-job-marker-\(UUID().uuidString.lowercased()).txt"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = "printf '%s' \"$PWD\" > \(TerminalSession.shellQuoted(marker.path)); sleep 0.4"
        let job = try jobStore.schedule(
            at: .now.addingTimeInterval(-1),
            script: .pasted(script, language: .bash),
            runLocation: .temporaryFolder,
            workingDirectory: FileManager.default.currentDirectoryPath
        )
        let directoryPrefix = "air-job-\(job.id.uuidString.lowercased())-"
        var observedTemporaryDirectory: URL?

        jobStore.launchDueJobs()
        for _ in 0..<400 where observedTemporaryDirectory == nil {
            try await Task.sleep(for: .milliseconds(20))
            for tab in terminalStore.groups.lazy.flatMap(\.tabs) { tab.poll() }
            observedTemporaryDirectory = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/tmp", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(directoryPrefix) }
        }
        let temporaryDirectory = try XCTUnwrap(observedTemporaryDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for _ in 0..<400 where !FileManager.default.fileExists(atPath: marker.path)
            || FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try await Task.sleep(for: .milliseconds(20))
            for tab in terminalStore.groups.lazy.flatMap(\.tabs) { tab.poll() }
        }

        let executedDirectory = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(executedDirectory.contains("/air-job-\(job.id.uuidString.lowercased())-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
        XCTAssertEqual(jobStore.jobs.first(where: { $0.id == job.id })?.status, .launched)
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
        XCTAssertEqual(store.tabPanelVisibilityActionTitle, "Show Side Panel")
        XCTAssertEqual(store.tabOrientation.panelSystemImage, "sidebar.left")
        XCTAssertEqual(store.selected?.graphicalViewMode, .list)
        store.tabOrientation = .horizontal
        store.isTabBarVisible = true
        store.graphicalViewMode = .icons
        XCTAssertEqual(store.tabPanelVisibilityActionTitle, "Hide Top Panel")
        XCTAssertEqual(store.tabOrientation.panelSystemImage, "rectangle.topthird.inset.filled")
    }

    @MainActor
    func testGraphicalPreviewLayoutModePersists() {
        let store = TerminalStore()
        let originalMode = store.graphicalPreviewLayoutMode
        defer { store.graphicalPreviewLayoutMode = originalMode }

        store.graphicalPreviewLayoutMode = .overlay
        XCTAssertEqual(TerminalStore().graphicalPreviewLayoutMode, .overlay)

        store.graphicalPreviewLayoutMode = .resizeContent
        XCTAssertEqual(TerminalStore().graphicalPreviewLayoutMode, .resizeContent)
    }

    @MainActor
    func testListingBackendPropagatesToExistingAndNewTabs() {
        let store = TerminalStore()
        let originalBackend = store.listingBackend
        let originalShowsHiddenFiles = store.graphicalShowsHiddenFiles
        defer {
            store.listingBackend = originalBackend
            store.graphicalShowsHiddenFiles = originalShowsHiddenFiles
        }

        store.listingBackend = .lstr
        store.graphicalShowsHiddenFiles = true
        XCTAssertEqual(store.selected?.listingBackend, .lstr)
        XCTAssertEqual(store.selected?.graphicalShowsHiddenFiles, true)
        store.newTab()
        XCTAssertEqual(store.selected?.listingBackend, .lstr)
        XCTAssertEqual(store.selected?.graphicalShowsHiddenFiles, true)
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

    private func visibleFrameText(_ frame: GTFrame) -> String {
        guard let cells = frame.cells else { return "" }
        return (0..<(Int(frame.cols) * Int(frame.rows))).map { index in
            let cell = cells[index]
            guard cell.style & UInt16(GT_STYLE_INVISIBLE) == 0 else { return "" }
            return withUnsafeBytes(of: cell.text) { raw in
                String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
            }
        }.joined()
    }

    private func semanticInputRows(in frame: GTFrame) -> [Bool] {
        guard let cells = frame.cells else { return [] }
        return (0..<Int(frame.rows)).map { row in
            (0..<Int(frame.cols)).contains { column in
                cells[row * Int(frame.cols) + column].semantic_content
                    == UInt8(GT_SEMANTIC_INPUT)
            }
        }
    }

}
