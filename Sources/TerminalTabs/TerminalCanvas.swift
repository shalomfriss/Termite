import AppKit
import CoreImage
import GhosttyBridge
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct TerminalCanvas: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let openDirectoryInNewTab: (URL) -> Void

    func makeNSView(context: Context) -> TerminalNSView {
        TerminalNSView(
            session: session,
            openDirectoryInNewTab: openDirectoryInNewTab
        )
    }

    func updateNSView(_ view: TerminalNSView, context: Context) {
        view.update(
            session: session,
            openDirectoryInNewTab: openDirectoryInNewTab
        )
    }
}

enum GraphicalKeyboardDirection {
    case left
    case right
    case up
    case down
}

struct GraphicalKeyboardNavigation {
    static func destinationIndex(
        from currentIndex: Int?,
        itemCount: Int,
        columnCount: Int,
        viewMode: GraphicalViewMode,
        direction: GraphicalKeyboardDirection
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        guard let currentIndex, (0..<itemCount).contains(currentIndex) else { return 0 }

        let destination: Int
        switch (viewMode, direction) {
        case (.list, .up):
            destination = currentIndex - 1
        case (.list, .down):
            destination = currentIndex + 1
        case (.list, .left), (.list, .right):
            return nil
        case (.icons, .left):
            destination = currentIndex - 1
        case (.icons, .right):
            destination = currentIndex + 1
        case (.icons, .up):
            destination = currentIndex - max(1, columnCount)
        case (.icons, .down):
            destination = min(itemCount - 1, currentIndex + max(1, columnCount))
        }
        guard (0..<itemCount).contains(destination), destination != currentIndex else { return nil }
        return destination
    }
}

final class TerminalNSView: NSView,
    @MainActor QLPreviewPanelDataSource,
    @MainActor QLPreviewPanelDelegate,
    NSDraggingSource {
    static let blockContentPadding: CGFloat = 20
    static let blockSpacing: CGFloat = 10
    static let blockTopInset: CGFloat = 10
    static let blockCornerRadius: CGFloat = 4
    private static let blockOuterMargin: CGFloat = 8
    private static let terminalContentInset: CGFloat = 10

    private struct BlockContents: Equatable {
        let id: TerminalBlockID
        let command: String
        let output: String
        let workingDirectory: String
    }

    private enum BlockAction: Equatable {
        case toggleFold
        case toggleBookmark
        case rerun
        case copy
        case attach
    }

    private struct BlockActionHitTarget: Equatable {
        let action: BlockAction
        let blockID: TerminalBlockID
        let block: BlockContents?
        let rect: NSRect
        let isEnabled: Bool
    }

    private struct ImageHitTarget: Equatable {
        let placementID: UInt32
        let rect: NSRect
    }

    private struct LinkHitTarget: Equatable {
        let url: URL
        let row: Int
        let columns: Range<Int>
        let rect: NSRect
    }

    private struct RenderState: Equatable {
        let revision: UInt
        let graphicalMode: Bool
        let isAlternateScreen: Bool
        let isRunning: Bool
        let commandPrediction: String?

        @MainActor
        init(session: TerminalSession) {
            revision = session.revision
            graphicalMode = session.graphicalMode
            isAlternateScreen = session.isAlternateScreen
            isRunning = session.isRunning
            commandPrediction = session.commandPrediction
        }
    }

    private struct ApplicationTextStyle: Equatable {
        let foregroundRed: UInt8
        let foregroundGreen: UInt8
        let foregroundBlue: UInt8
        let flags: UInt16

        init(cell: GTCell) {
            foregroundRed = cell.fg_r
            foregroundGreen = cell.fg_g
            foregroundBlue = cell.fg_b
            flags = cell.style & UInt16(GT_STYLE_BOLD | GT_STYLE_ITALIC | GT_STYLE_FAINT)
        }
    }

    private struct ApplicationBackground: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    var session: TerminalSession
    var openDirectoryInNewTab: (URL) -> Void
    var openURL: (URL) -> Void
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    private let italicFont: NSFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat = 20
    private lazy var regularCellKern = cellWidth
        - ("M" as NSString).size(withAttributes: [.font: font]).width
    private lazy var boldCellKern = cellWidth
        - ("M" as NSString).size(withAttributes: [.font: boldFont]).width
    private lazy var italicCellKern = cellWidth
        - ("M" as NSString).size(withAttributes: [.font: italicFont]).width
    private var lastGrid = (cols: UInt16(0), rows: UInt16(0))
    private var wasFocusReportingEnabled = false
    private var windowKeyObserver: NSObjectProtocol?
    private var contextBlock: BlockContents?
    private var contextGraphicalItem: GraphicalFileItem?
    private var selectedBlockHistoryRows: Set<UInt64> = []
    private var selectedGraphicalPlacementID: UInt32?
    private(set) var hasGraphicalKeyboardFocus = false
    private var hoveredGraphicalPlacementID: UInt32?
    private var dropTargetGraphicalPlacementID: UInt32?
    private var graphicalDragCandidate: (placementID: UInt32, origin: NSPoint)?
    private var hoveredBlockAction: BlockActionHitTarget?
    private var hoveredLink: LinkHitTarget?
    private var linkActivationCandidate: LinkHitTarget?
    private var textSelectionAnchor: TerminalTextPosition?
    private var textSelection: TerminalTextSelection?
    private var imageHitTargets: [ImageHitTarget] = []
    private var blockActionHitTargets: [BlockActionHitTarget] = []
    private var linkHitTargets: [LinkHitTarget] = []
    private var blockActionToolTipTags: [NSView.ToolTipTag] = []
    private var linkToolTipTags: [NSView.ToolTipTag] = []
    private var graphicalTrackingArea: NSTrackingArea?
    private var imageCache: [UInt32: CGImage] = [:]
    private var folderBloomCache: [UInt32: CGImage] = [:]
    private var selectionGlowCache: [String: CGImage] = [:]
    private var quickLookURL: URL?
    private var sharingPicker: NSSharingServicePicker?
    private var renderState: RenderState
    private let ciContext = CIContext(options: [.cacheIntermediates: true])
    private lazy var graphicalBackdropGradient: CGGradient? = {
        let colors = [
            NSColor(srgbRed: 0.15, green: 0.55, blue: 0.59, alpha: 0.15).cgColor,
            NSColor(srgbRed: 0.02, green: 0.12, blue: 0.15, alpha: 0).cgColor,
        ] as CFArray
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        )
    }()

    init(
        session: TerminalSession,
        openDirectoryInNewTab: @escaping (URL) -> Void = { _ in },
        openURL: @escaping (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
    ) {
        self.session = session
        self.openDirectoryInNewTab = openDirectoryInNewTab
        self.openURL = openURL
        renderState = RenderState(session: session)
        let descriptor = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontDescriptor
            .withSymbolicTraits(.italic)
        italicFont = NSFont(descriptor: descriptor, size: 14) ?? font
        cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.024, green: 0.067, blue: 0.094, alpha: 1).cgColor
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { session.sendFocus(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        session.sendFocus(false)
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.focusTerminal() }
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.focusTerminal()
        }
    }

    private func focusTerminal() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(self)
    }

    func update(
        session: TerminalSession,
        openDirectoryInNewTab: @escaping (URL) -> Void
    ) {
        let nextRenderState = RenderState(session: session)
        let needsTerminalLayout = renderState.isAlternateScreen != nextRenderState.isAlternateScreen
        let needsTerminalDisplay = renderState != nextRenderState

        self.session = session
        self.openDirectoryInNewTab = openDirectoryInNewTab
        renderState = nextRenderState
        if !session.graphicalMode || session.isAlternateScreen {
            hasGraphicalKeyboardFocus = false
        }

        if needsTerminalLayout { needsLayout = true }
        if needsTerminalDisplay {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        syncApplicationFocusReporting()
        revealPendingTerminalBlockNavigation()
    }

    func syncApplicationFocusReporting() {
        guard let window else { return }
        defer { wasFocusReportingEnabled = session.isFocusReporting }
        guard session.isFocusReporting, !wasFocusReportingEnabled else { return }
        session.sendFocus(window.firstResponder === self)
    }

    func revealPendingTerminalBlockNavigation() {
        guard let blockID = session.takePendingTerminalBlockNavigation() else { return }
        selectedBlockHistoryRows = [blockID.historyRow]
        selectedGraphicalPlacementID = nil
        textSelection = nil
        textSelectionAnchor = nil
        focusTerminal()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let horizontalInsets = session.isAlternateScreen
            ? 2 * Self.terminalContentInset
            : 2 * (Self.blockOuterMargin + Self.blockContentPadding)
        let cols = UInt16(max(1, min(Int(UInt16.max), Int((bounds.width - horizontalInsets) / cellWidth))))
        let rows = UInt16(max(1, min(Int(UInt16.max), Int(bounds.height / cellHeight))))
        if (cols, rows) != lastGrid {
            lastGrid = (cols, rows)
            session.resize(cols: cols, rows: rows,
                           cellWidth: UInt32(cellWidth), cellHeight: UInt32(cellHeight))
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        if forwardMouseEvent(event, action: Int32(GT_MOUSE_ACTION_PRESS)) {
            textSelectionAnchor = nil
            textSelection = nil
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let target = blockActionHitTargets.last(where: { $0.rect.contains(point) }) {
            hasGraphicalKeyboardFocus = false
            graphicalDragCandidate = nil
            linkActivationCandidate = nil
            textSelectionAnchor = nil
            textSelection = nil
            selectedGraphicalPlacementID = nil
            session.setGraphicalPreviewItem(nil)
            if target.isEnabled { performBlockAction(target) }
            return
        }
        if let target = imageHitTargets.last(where: { $0.rect.contains(point) }),
           let item = session.graphicalItem(for: target.placementID) {
            hasGraphicalKeyboardFocus = true
            linkActivationCandidate = nil
            textSelectionAnchor = nil
            textSelection = nil
            selectedBlockHistoryRows.removeAll()
            selectedGraphicalPlacementID = target.placementID
            session.setGraphicalPreviewItem(item)
            graphicalDragCandidate = (target.placementID, point)
            needsDisplay = true
            if event.clickCount >= 2 {
                session.activateGraphicalItem(item)
            }
            return
        }
        if let target = linkHitTargets.last(where: { $0.rect.contains(point) }) {
            hasGraphicalKeyboardFocus = false
            graphicalDragCandidate = nil
            linkActivationCandidate = target
            textSelection = nil
            textSelectionAnchor = terminalPosition(at: point)
            selectedGraphicalPlacementID = nil
            session.setGraphicalPreviewItem(nil)
            return
        }
        if isGraphicalFilePage(at: point) {
            hasGraphicalKeyboardFocus = true
            textSelection = nil
            textSelectionAnchor = nil
            graphicalDragCandidate = nil
            linkActivationCandidate = nil
            selectedBlockHistoryRows.removeAll()
            selectedGraphicalPlacementID = nil
            session.setGraphicalPreviewItem(nil)
            needsDisplay = true
            return
        }
        hasGraphicalKeyboardFocus = false
        textSelection = nil
        graphicalDragCandidate = nil
        linkActivationCandidate = nil
        textSelectionAnchor = terminalPosition(at: point)
        selectedGraphicalPlacementID = nil
        session.setGraphicalPreviewItem(nil)
        selectBlock(atVisualY: point.y, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        if forwardMouseEvent(
            event,
            action: Int32(GT_MOUSE_ACTION_MOTION),
            forcedButton: Int32(GT_MOUSE_BUTTON_LEFT),
            anyButtonPressed: true
        ) { return }
        linkActivationCandidate = nil
        if let candidate = graphicalDragCandidate {
            let point = convert(event.locationInWindow, from: nil)
            let distance = hypot(point.x - candidate.origin.x, point.y - candidate.origin.y)
            guard distance >= 4,
                  let item = session.graphicalItem(for: candidate.placementID),
                  let target = imageHitTargets.last(where: {
                      $0.placementID == candidate.placementID
                  }) else { return }
            graphicalDragCandidate = nil
            let url = URL(fileURLWithPath: item.path)
            let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: 48, height: 48)
            let frame = NSRect(
                x: point.x - 24,
                y: point.y - 24,
                width: 48,
                height: 48
            )
            draggingItem.setDraggingFrame(frame, contents: icon)
            selectedGraphicalPlacementID = target.placementID
            beginDraggingSession(with: [draggingItem], event: event, source: self)
            return
        }
        guard let anchor = textSelectionAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let extent = terminalPosition(at: point), extent != anchor else { return }
        textSelection = TerminalTextSelection(anchor: anchor, extent: extent)
        selectedBlockHistoryRows.removeAll()
        selectedGraphicalPlacementID = nil
        session.setGraphicalPreviewItem(nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if forwardMouseEvent(
            event,
            action: Int32(GT_MOUSE_ACTION_RELEASE),
            anyButtonPressed: false
        ) { return }
        if let linkActivationCandidate {
            openURL(linkActivationCandidate.url)
            self.linkActivationCandidate = nil
        }
        graphicalDragCandidate = nil
        textSelectionAnchor = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        focusTerminal()
        if !forwardMouseEvent(event, action: Int32(GT_MOUSE_ACTION_PRESS)) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !forwardMouseEvent(
            event,
            action: Int32(GT_MOUSE_ACTION_RELEASE),
            anyButtonPressed: false
        ) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        focusTerminal()
        if !forwardMouseEvent(event, action: Int32(GT_MOUSE_ACTION_PRESS)) {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !forwardMouseEvent(
            event,
            action: Int32(GT_MOUSE_ACTION_RELEASE),
            anyButtonPressed: false
        ) {
            super.otherMouseUp(with: event)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropTarget()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearDropTarget() }
        guard let placementID = dropTargetGraphicalPlacementID,
              let item = session.graphicalItem(for: placementID) else { return false }
        return session.moveGraphicalItems(draggedFileURLs(from: sender), into: item)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearDropTarget()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            bounds,
            cursor: session.isAlternateScreen && session.isMouseReporting ? .arrow : .iBeam
        )
        for target in imageHitTargets {
            addCursorRect(target.rect, cursor: .pointingHand)
        }
        for target in blockActionHitTargets where target.isEnabled {
            addCursorRect(target.rect, cursor: .pointingHand)
        }
        for target in linkHitTargets {
            addCursorRect(target.rect, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let graphicalTrackingArea { removeTrackingArea(graphicalTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        graphicalTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if forwardMouseEvent(
            event,
            action: Int32(GT_MOUSE_ACTION_MOTION),
            forcedButton: Int32(GT_MOUSE_BUTTON_NONE),
            anyButtonPressed: false
        ) { return }
        let point = convert(event.locationInWindow, from: nil)
        let hoveredGraphical = imageHitTargets.last(where: { $0.rect.contains(point) })?.placementID
        let hoveredAction = blockActionHitTargets.last(where: { $0.rect.contains(point) })
        let hoveredLink = linkHitTargets.last(where: { $0.rect.contains(point) })
        guard hoveredGraphical != hoveredGraphicalPlacementID
                || hoveredAction != hoveredBlockAction
                || hoveredLink != self.hoveredLink else { return }
        hoveredGraphicalPlacementID = hoveredGraphical
        hoveredBlockAction = hoveredAction
        self.hoveredLink = hoveredLink
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredGraphicalPlacementID != nil
                || hoveredBlockAction != nil
                || hoveredLink != nil else { return }
        hoveredGraphicalPlacementID = nil
        hoveredBlockAction = nil
        hoveredLink = nil
        needsDisplay = true
    }

    private func updateDropTarget(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard session.graphicalMode else {
            clearDropTarget()
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let urls = draggedFileURLs(from: sender)
        let placementID = imageHitTargets.reversed().first { target in
            guard target.rect.contains(point),
                  let item = session.graphicalItem(for: target.placementID) else { return false }
            return session.canMoveGraphicalItems(urls, into: item)
        }?.placementID
        if placementID != dropTargetGraphicalPlacementID {
            dropTargetGraphicalPlacementID = placementID
            needsDisplay = true
        }
        return placementID == nil ? [] : .move
    }

    private func draggedFileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    private func clearDropTarget() {
        guard dropTargetGraphicalPlacementID != nil else { return }
        dropTargetGraphicalPlacementID = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let amount: CGFloat
        if event.hasPreciseScrollingDeltas {
            amount = event.scrollingDeltaY / cellHeight
        } else {
            amount = event.scrollingDeltaY * 3
        }
        let rows = Int(amount.rounded(.awayFromZero))
        if rows != 0 {
            if session.isAlternateScreen, session.isMouseReporting {
                let button = rows > 0
                    ? Int32(GT_MOUSE_BUTTON_SCROLL_UP)
                    : Int32(GT_MOUSE_BUTTON_SCROLL_DOWN)
                for _ in 0..<min(10, abs(rows)) {
                    _ = forwardMouseEvent(
                        event,
                        action: Int32(GT_MOUSE_ACTION_PRESS),
                        forcedButton: button,
                        anyButtonPressed: false
                    )
                }
                return
            }
            if session.isAlternateScreen {
                let sequence = rows > 0 ? Data("\u{1B}[A".utf8) : Data("\u{1B}[B".utf8)
                for _ in 0..<min(10, abs(rows)) { session.sendUserInput(sequence) }
                return
            }
            session.scroll(rows: -rows)
            needsDisplay = true
        }
    }

    private func forwardMouseEvent(
        _ event: NSEvent,
        action: Int32,
        forcedButton: Int32? = nil,
        anyButtonPressed: Bool? = nil
    ) -> Bool {
        guard session.isAlternateScreen,
              session.isMouseReporting,
              !event.modifierFlags.contains(.shift),
              let handle = session.handle else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let button = forcedButton ?? terminalMouseButton(for: event)
        var modifiers: UInt16 = 0
        if event.modifierFlags.contains(.shift) { modifiers |= UInt16(GT_MOD_SHIFT) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt16(GT_MOD_CONTROL) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt16(GT_MOD_ALT) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt16(GT_MOD_SUPER) }
        let isPressed = anyButtonPressed
            ?? (action != Int32(GT_MOUSE_ACTION_RELEASE))
        return gt_session_send_mouse(
            handle,
            action,
            button,
            modifiers,
            Float(point.x),
            Float(point.y),
            UInt32(max(1, bounds.width.rounded(.up))),
            UInt32(max(1, bounds.height.rounded(.up))),
            UInt32(max(1, cellWidth.rounded(.up))),
            UInt32(cellHeight),
            UInt32(Self.terminalContentInset),
            0,
            isPressed
        )
    }

    private func terminalMouseButton(for event: NSEvent) -> Int32 {
        switch event.buttonNumber {
        case 0: Int32(GT_MOUSE_BUTTON_LEFT)
        case 1: Int32(GT_MOUSE_BUTTON_RIGHT)
        case 2: Int32(GT_MOUSE_BUTTON_MIDDLE)
        default: Int32(GT_MOUSE_BUTTON_NONE)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        focusTerminal()
        let point = convert(event.locationInWindow, from: nil)
        if let target = imageHitTargets.last(where: { $0.rect.contains(point) }),
           let item = session.graphicalItem(for: target.placementID) {
            selectedBlockHistoryRows.removeAll()
            selectedGraphicalPlacementID = target.placementID
            session.setGraphicalPreviewItem(item)
            needsDisplay = true
            contextBlock = nil
            return graphicalItemMenu(for: item)
        }

        contextGraphicalItem = nil
        contextBlock = blockContents(atVisualY: point.y)
        if let contextBlock,
           !selectedBlockHistoryRows.contains(contextBlock.id.historyRow) {
            selectedBlockHistoryRows = [contextBlock.id.historyRow]
            needsDisplay = true
        }

        let menu = NSMenu()
        menu.addItem(menuItem(
            "Copy",
            action: #selector(copyTerminalSelection),
            enabled: selectedTerminalText()?.isEmpty == false
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Run Command Again",
            action: #selector(rerunCommand),
            enabled: contextBlock != nil && session.canRunBlockCommand,
            systemImage: "arrow.clockwise"
        ))
        menu.addItem(menuItem(
            "Reinput Command",
            action: #selector(reinputCommand),
            enabled: contextBlock != nil && session.canRunBlockCommand,
            systemImage: "text.cursor"
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Copy Output",
            action: #selector(copyOutput),
            enabled: contextBlock != nil,
            systemImage: "doc.on.doc"
        ))
        menu.addItem(menuItem("Copy Command", action: #selector(copyCommand), enabled: contextBlock != nil))
        menu.addItem(menuItem(
            "Copy Command and Output",
            action: #selector(copyCommandAndOutput),
            enabled: contextBlock != nil
        ))
        menu.addItem(menuItem("Copy Working Directory", action: #selector(copyWorkingDirectory), enabled: contextBlock != nil))
        if let contextBlock {
            menu.addItem(menuItem(
                session.isTerminalBlockBookmarked(contextBlock.id)
                    ? "Remove Bookmark"
                    : "Bookmark Block",
                action: #selector(toggleContextBlockBookmark),
                enabled: true,
                systemImage: session.isTerminalBlockBookmarked(contextBlock.id)
                    ? "bookmark.fill"
                    : "bookmark"
            ))
            menu.addItem(menuItem(
                session.isTerminalBlockCollapsed(contextBlock.id) ? "Expand Block" : "Collapse Block",
                action: #selector(toggleContextBlockFold),
                enabled: true,
                systemImage: session.isTerminalBlockCollapsed(contextBlock.id)
                    ? "chevron.right"
                    : "chevron.down"
            ))
        }
        menu.addItem(.separator())
        let selectedBlocks = selectedBlockContents()
        menu.addItem(menuItem(
            selectedBlocks.count > 1
                ? "Attach Selected Blocks to AI Chat"
                : "Attach Output to AI Chat",
            action: #selector(attachOutputToAI),
            enabled: selectedBlocks.contains {
                !session.hasPendingAIAttachment(for: $0.id)
            } || (contextBlock == nil && session.canAttachGraphicalOutputToAI),
            systemImage: "sparkles"
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem("Paste", action: #selector(pasteIntoTerminal),
                              enabled: NSPasteboard.general.string(forType: .string) != nil))
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 126 || event.keyCode == 125 {
            selectRelativeBlock(
                event.keyCode == 126 ? -1 : 1,
                extending: event.modifierFlags.contains(.shift)
            )
            return true
        }
        if characters == "a", !session.isAlternateScreen {
            selectAllVisibleBlocks()
            return true
        }
        if characters == "b", !selectedBlockHistoryRows.isEmpty {
            for block in selectedBlockContents() {
                session.toggleTerminalBlockBookmarked(
                    block.id,
                    command: block.command,
                    output: block.output,
                    workingDirectory: block.workingDirectory
                )
            }
            needsDisplay = true
            return true
        }
        if characters == "i", session.canRunBlockCommand,
           let block = selectedBlockContents().last {
            session.reinputBlockCommand(block.command)
            return true
        }
        if characters == "k", !session.isAlternateScreen {
            selectedBlockHistoryRows.removeAll()
            session.clearTerminalView()
            return true
        }
        if characters == "c" {
            if event.modifierFlags.contains(.shift), !selectedBlockHistoryRows.isEmpty {
                copySelectedBlocks(
                    commandOnly: !event.modifierFlags.contains(.option),
                    outputOnly: event.modifierFlags.contains(.option)
                )
                return true
            }
            if let selectedText = selectedTerminalText(), !selectedText.isEmpty {
                copyToPasteboard(selectedText)
                return true
            }
            if let selectedGraphicalPlacementID,
               let item = session.graphicalItem(for: selectedGraphicalPlacementID) {
                session.copyGraphicalItem(item)
                return true
            }
            if !selectedBlockHistoryRows.isEmpty {
                copySelectedBlocks(commandOnly: false, outputOnly: false)
                return true
            }
        }
        if characters == "v",
           let value = NSPasteboard.general.string(forType: .string) {
            clearTextSelection()
            session.paste(value)
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if handleGraphicalKeyDown(event) { return }
        let predictionModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        if event.keyCode == 124,
           predictionModifiers.isEmpty,
           session.acceptCommandPrediction() {
            clearTextSelection()
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains(.shift), event.keyCode == 116 || event.keyCode == 121 {
            let page = max(1, Int(lastGrid.rows) - 2)
            session.scroll(rows: event.keyCode == 116 ? -page : page)
            needsDisplay = true
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let data = TerminalInput.sequence(for: event) {
            clearTextSelection()
            session.sendUserInput(data)
        }
    }

    private func handleGraphicalKeyDown(_ event: NSEvent) -> Bool {
        guard session.graphicalMode,
              hasGraphicalKeyboardFocus,
              !session.isAlternateScreen,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }

        let direction: GraphicalKeyboardDirection?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: direction = nil
        }
        if let direction {
            moveGraphicalSelection(direction)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            guard let selectedGraphicalPlacementID,
                  let item = session.graphicalItem(for: selectedGraphicalPlacementID)
            else { return true }
            session.activateGraphicalItem(item)
            return true
        }
        return false
    }

    private func moveGraphicalSelection(_ direction: GraphicalKeyboardDirection) {
        let navigation = session.graphicalKeyboardNavigation
        let currentIndex = selectedGraphicalPlacementID.flatMap {
            navigation.placementIDs.firstIndex(of: $0)
        }
        guard let destinationIndex = GraphicalKeyboardNavigation.destinationIndex(
            from: currentIndex,
            itemCount: navigation.placementIDs.count,
            columnCount: navigation.columnCount,
            viewMode: session.graphicalViewMode,
            direction: direction
        ) else { return }

        let previousIndex = currentIndex
        let placementID = navigation.placementIDs[destinationIndex]
        selectedGraphicalPlacementID = placementID
        selectedBlockHistoryRows.removeAll()
        textSelection = nil
        textSelectionAnchor = nil
        session.setGraphicalPreviewItem(session.graphicalItem(for: placementID))
        if !imageHitTargets.contains(where: { $0.placementID == placementID }) {
            let rowCount = session.graphicalItemHitLayout(for: placementID).2
            session.scroll(rows: destinationIndex < (previousIndex ?? 0) ? -rowCount : rowCount)
        }
        needsDisplay = true
    }

    private func isGraphicalFilePage(at point: NSPoint) -> Bool {
        guard session.graphicalMode,
              let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return false }
        let frame = framePointer.pointee
        let ranges = blockRanges(frame: frame, cells: cells)
        let layout = blockVisualLayout(frame: frame, cells: cells, ranges: ranges)
        guard let row = layout.row(at: point.y, cellHeight: cellHeight, nearest: false) else {
            return false
        }
        return graphicalListingRows(frame: frame).contains(row)
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLookURL != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            quickLookURL = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (quickLookURL ?? URL(fileURLWithPath: "/")) as NSURL
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let handle = session.handle, let framePointer = gt_session_frame(handle) else {
            drawMessage(session.error ?? "Terminal unavailable")
            return
        }
        let frame = framePointer.pointee
        guard let cells = frame.cells else { return }
        let context = NSGraphicsContext.current?.cgContext
        if session.graphicalMode && !frame.alternate_screen {
            drawGraphicalBackdrop(in: context)
        } else {
            context?.setFillColor(NSColor(red: 0.024, green: 0.067, blue: 0.094, alpha: 1).cgColor)
            context?.fill(bounds)
        }

        if frame.alternate_screen {
            drawApplicationScreen(frame: frame, cells: cells)
            return
        }

        let ranges = blockRanges(frame: frame, cells: cells)
        let visualLayout = blockVisualLayout(frame: frame, cells: cells, ranges: ranges)
        let rowOffsets = visualLayout.rowOffsets
        var rowLeadingOffsets = Array(
            repeating: Self.terminalContentInset,
            count: Int(frame.rows)
        )
        for range in ranges {
            for row in range where rowLeadingOffsets.indices.contains(row) {
                rowLeadingOffsets[row] = Self.blockContentLeadingOffset
            }
        }
        let blockFill = NSColor(red: 0.035, green: 0.094, blue: 0.122, alpha: 1)
        let blockBorder = NSColor(red: 0.20, green: 0.55, blue: 0.62, alpha: 0.25)
        let selectedFill = NSColor(red: 0.050, green: 0.135, blue: 0.165, alpha: 1)
        let selectedBorder = NSColor(red: 0.32, green: 0.84, blue: 0.88, alpha: 0.48)
        for (index, range) in ranges.enumerated() {
            let verticalFrame = visualLayout.blockFrames[index]
            let rect = NSRect(
                x: Self.blockOuterMargin,
                y: verticalFrame.minY,
                width: max(0, bounds.width - Self.blockOuterMargin * 2),
                height: verticalFrame.height
            )
            let isSelected = selectedBlockHistoryRows.contains(
                frame.scroll_offset + UInt64(range.lowerBound)
            )
            let fillPath = NSBezierPath(
                roundedRect: rect,
                xRadius: Self.blockCornerRadius,
                yRadius: Self.blockCornerRadius
            )
            (isSelected ? selectedFill : blockFill).setFill()
            fillPath.fill()

            let borderPath = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Self.blockCornerRadius - 0.5,
                yRadius: Self.blockCornerRadius - 0.5
            )
            (isSelected ? selectedBorder : blockBorder).setStroke()
            borderPath.lineWidth = 1
            borderPath.stroke()
        }
        updateBlockActionHitTargets(
            frame: frame,
            cells: cells,
            ranges: ranges,
            visualLayout: visualLayout
        )
        updateGraphicalHitTargets(
            frame,
            rowOffsets: rowOffsets,
            rowLeadingOffsets: rowLeadingOffsets,
            hiddenRows: visualLayout.hiddenRows
        )
        updateLinkHitTargets(
            frame: frame,
            cells: cells,
            rowOffsets: rowOffsets,
            rowLeadingOffsets: rowLeadingOffsets,
            hiddenRows: visualLayout.hiddenRows
        )
        drawGraphicalItemSurfaces()

        for y in 0..<Int(frame.rows) where !visualLayout.hiddenRows.contains(y) {
            let isInBlock = ranges.contains { $0.contains(y) }
            for x in 0..<Int(frame.cols) {
                let cell = cells[y * Int(frame.cols) + x]
                let rect = NSRect(x: CGFloat(x) * cellWidth + rowLeadingOffsets[y],
                                  y: CGFloat(y) * cellHeight + rowOffsets[y],
                                  width: cellWidth + 0.5, height: cellHeight)
                let hasDefaultBackground = cell.bg_r == 6 && cell.bg_g == 17 && cell.bg_b == 24
                let shouldDrawBackground = !hasDefaultBackground
                    || (!session.graphicalMode && !isInBlock)
                if shouldDrawBackground {
                    color(cell.bg_r, cell.bg_g, cell.bg_b).setFill()
                    rect.fill()
                }
                let historyRow = frame.scroll_offset + UInt64(y)
                if textSelection?.contains(
                    row: historyRow,
                    column: x,
                    totalColumns: Int(frame.cols)
                ) == true {
                    NSColor(srgbRed: 0.29, green: 0.82, blue: 0.80, alpha: 0.34).setFill()
                    rect.fill()
                }
                guard cell.text_len > 0, cell.style & UInt16(GT_STYLE_INVISIBLE) == 0 else { continue }
                let text = withUnsafeBytes(of: cell.text) { raw -> String in
                    String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
                }
                var foreground = color(cell.fg_r, cell.fg_g, cell.fg_b)
                if cell.style & UInt16(GT_STYLE_FAINT) != 0 { foreground = foreground.withAlphaComponent(0.58) }
                let chosenFont: NSFont
                if cell.style & UInt16(GT_STYLE_BOLD) != 0 { chosenFont = boldFont }
                else if cell.style & UInt16(GT_STYLE_ITALIC) != 0 { chosenFont = italicFont }
                else { chosenFont = font }
                let link = linkHitTargets.first {
                    $0.row == y && $0.columns.contains(x)
                }
                if let link {
                    let isHovered = link == hoveredLink
                    foreground = NSColor(
                        srgbRed: isHovered ? 0.48 : 0.38,
                        green: isHovered ? 0.96 : 0.84,
                        blue: isHovered ? 0.96 : 0.86,
                        alpha: 1
                    )
                }
                (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + 1),
                                        withAttributes: [.font: chosenFont, .foregroundColor: foreground])
                if link != nil || cell.style & UInt16(GT_STYLE_UNDERLINE_MASK) != 0 {
                    foreground.setFill()
                    NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
                }
                if cell.style & UInt16(GT_STYLE_STRIKETHROUGH) != 0 {
                    foreground.setFill()
                    NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1).fill()
                }
            }
        }

        // Keep labels crisp by painting the item surfaces before terminal text,
        // then composite the antialiased icons over the completed cell grid.
        drawImages(
            frame,
            rowOffsets: rowOffsets,
            rowLeadingOffsets: rowLeadingOffsets,
            hiddenRows: visualLayout.hiddenRows
        )
        drawBlockActions()
        drawCommandPrediction(
            frame: frame,
            rowOffsets: rowOffsets,
            rowLeadingOffsets: rowLeadingOffsets,
            hiddenRows: visualLayout.hiddenRows
        )

        if frame.cursor_visible, !visualLayout.hiddenRows.contains(Int(frame.cursor_y)) {
            let cursorRow = Int(frame.cursor_y)
            let cursorOffset = rowOffsets.indices.contains(cursorRow) ? rowOffsets[cursorRow] : 0
            let cursorLeadingOffset = rowLeadingOffsets.indices.contains(cursorRow)
                ? rowLeadingOffsets[cursorRow]
                : Self.terminalContentInset
            let cursor = NSRect(x: CGFloat(frame.cursor_x) * cellWidth + cursorLeadingOffset,
                                y: CGFloat(frame.cursor_y) * cellHeight + cursorOffset,
                                width: cellWidth, height: cellHeight)
            color(frame.cursor_r, frame.cursor_g, frame.cursor_b).withAlphaComponent(0.72).setFill()
            cursor.fill(using: .screen)
        }

        if !session.isRunning {
            let status = gt_session_exit_status(handle)
            drawBadge("Process exited with status \(status)")
        }
        if !frame.alternate_screen { drawScrollbar(frame) }
    }

    private func drawCommandPrediction(
        frame: GTFrame,
        rowOffsets: [CGFloat],
        rowLeadingOffsets: [CGFloat],
        hiddenRows: Set<Int>
    ) {
        guard frame.cursor_visible,
              let suffix = session.commandPredictionSuffix,
              !suffix.isEmpty else { return }

        let columnCount = Int(frame.cols)
        let rowCount = Int(frame.rows)
        guard columnCount > 0, rowCount > 0 else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(
                srgbRed: 0.50,
                green: 0.65,
                blue: 0.71,
                alpha: 0.48
            ),
        ]
        var column = Int(frame.cursor_x)
        var row = Int(frame.cursor_y)

        for character in suffix {
            guard character != "\n", character != "\r" else { break }
            if character == "\t" {
                column += 4 - column % 4
                continue
            }
            if column >= columnCount {
                column = 0
                row += 1
            }
            guard row < rowCount else { break }
            guard !hiddenRows.contains(row) else {
                column += 1
                continue
            }

            let rowOffset = rowOffsets.indices.contains(row) ? rowOffsets[row] : 0
            let leadingOffset = rowLeadingOffsets.indices.contains(row)
                ? rowLeadingOffsets[row]
                : Self.terminalContentInset
            (String(character) as NSString).draw(
                at: NSPoint(
                    x: CGFloat(column) * cellWidth + leadingOffset,
                    y: CGFloat(row) * cellHeight + rowOffset + 1
                ),
                withAttributes: attributes
            )
            column += 1
        }
    }

    private func drawApplicationScreen(frame: GTFrame, cells: UnsafePointer<GTCell>) {
        clearApplicationScreenHitTargets()
        let leadingOffset = Self.terminalContentInset
        let defaultBackground = (r: UInt8(6), g: UInt8(17), b: UInt8(24))

        for y in 0..<Int(frame.rows) {
            drawApplicationBackgroundRow(
                frame: frame,
                cells: cells,
                row: y,
                leadingOffset: leadingOffset,
                defaultBackground: defaultBackground
            )
            drawApplicationTextRow(
                frame: frame,
                cells: cells,
                row: y,
                leadingOffset: leadingOffset
            )
        }

        drawImages(
            frame,
            rowOffsets: Array(repeating: 0, count: Int(frame.rows)),
            rowLeadingOffsets: Array(repeating: leadingOffset, count: Int(frame.rows)),
            hiddenRows: []
        )

        if frame.cursor_visible {
            let cursor = NSRect(
                x: CGFloat(frame.cursor_x) * cellWidth + leadingOffset,
                y: CGFloat(frame.cursor_y) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            color(frame.cursor_r, frame.cursor_g, frame.cursor_b)
                .withAlphaComponent(0.72)
                .setFill()
            cursor.fill(using: .screen)
        }
    }

    private func drawApplicationBackgroundRow(
        frame: GTFrame,
        cells: UnsafePointer<GTCell>,
        row: Int,
        leadingOffset: CGFloat,
        defaultBackground: (r: UInt8, g: UInt8, b: UInt8)
    ) {
        var runStartColumn = 0
        var runColor: ApplicationBackground?

        for column in 0...Int(frame.cols) {
            let nextColor: ApplicationBackground?
            if column < Int(frame.cols) {
                let cell = cells[row * Int(frame.cols) + column]
                if cell.bg_r == defaultBackground.r,
                   cell.bg_g == defaultBackground.g,
                   cell.bg_b == defaultBackground.b {
                    nextColor = nil
                } else {
                    nextColor = ApplicationBackground(
                        red: cell.bg_r,
                        green: cell.bg_g,
                        blue: cell.bg_b
                    )
                }
            } else {
                nextColor = nil
            }
            if nextColor == runColor { continue }
            if let runColor {
                color(runColor.red, runColor.green, runColor.blue).setFill()
                NSRect(
                    x: CGFloat(runStartColumn) * cellWidth + leadingOffset,
                    y: CGFloat(row) * cellHeight,
                    width: CGFloat(column - runStartColumn) * cellWidth + 0.5,
                    height: cellHeight
                ).fill()
            }
            runStartColumn = column
            runColor = nextColor
        }

        guard textSelection != nil else { return }
        let selectionColor = NSColor(
            srgbRed: 0.29,
            green: 0.82,
            blue: 0.80,
            alpha: 0.34
        )
        let historyRow = frame.scroll_offset + UInt64(row)
        for column in 0..<Int(frame.cols) where textSelection?.contains(
            row: historyRow,
            column: column,
            totalColumns: Int(frame.cols)
        ) == true {
            selectionColor.setFill()
            NSRect(
                x: CGFloat(column) * cellWidth + leadingOffset,
                y: CGFloat(row) * cellHeight,
                width: cellWidth + 0.5,
                height: cellHeight
            ).fill()
        }
    }

    private func drawApplicationTextRow(
        frame: GTFrame,
        cells: UnsafePointer<GTCell>,
        row: Int,
        leadingOffset: CGFloat
    ) {
        var runBytes: [UInt8] = []
        runBytes.reserveCapacity(Int(frame.cols))
        var runStartColumn = 0
        var runStyle: ApplicationTextStyle?

        func flushRun() {
            guard !runBytes.isEmpty, let style = runStyle else { return }
            drawApplicationText(
                String(decoding: runBytes, as: UTF8.self),
                column: runStartColumn,
                row: row,
                leadingOffset: leadingOffset,
                style: style,
                appliesCellKern: true
            )
            runBytes.removeAll(keepingCapacity: true)
            runStyle = nil
        }

        for column in 0..<Int(frame.cols) {
            let cell = cells[row * Int(frame.cols) + column]
            guard cell.text_len > 0,
                  cell.style & UInt16(GT_STYLE_INVISIBLE) == 0 else {
                flushRun()
                continue
            }

            let firstByte = withUnsafeBytes(of: cell.text) { $0[0] }
            let hasLineDecoration = cell.style
                & UInt16(GT_STYLE_UNDERLINE_MASK | GT_STYLE_STRIKETHROUGH) != 0
            let canJoinRun = cell.text_len == 1
                && firstByte >= 0x20
                && firstByte <= 0x7E
                && !hasLineDecoration
            let style = ApplicationTextStyle(cell: cell)

            if canJoinRun {
                if firstByte == 0x20, runBytes.isEmpty { continue }
                if let runStyle, runStyle != style { flushRun() }
                if runBytes.isEmpty {
                    runStartColumn = column
                    runStyle = style
                }
                runBytes.append(firstByte)
                continue
            }

            flushRun()
            let text = withUnsafeBytes(of: cell.text) { raw -> String in
                String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
            }
            drawApplicationText(
                text,
                column: column,
                row: row,
                leadingOffset: leadingOffset,
                style: style,
                appliesCellKern: false
            )
            let foreground = applicationForeground(for: style)
            if cell.style & UInt16(GT_STYLE_UNDERLINE_MASK) != 0 {
                foreground.setFill()
                NSRect(
                    x: CGFloat(column) * cellWidth + leadingOffset,
                    y: CGFloat(row + 1) * cellHeight - 2,
                    width: cellWidth + 0.5,
                    height: 1
                ).fill()
            }
            if cell.style & UInt16(GT_STYLE_STRIKETHROUGH) != 0 {
                foreground.setFill()
                NSRect(
                    x: CGFloat(column) * cellWidth + leadingOffset,
                    y: CGFloat(row) * cellHeight + cellHeight / 2,
                    width: cellWidth + 0.5,
                    height: 1
                ).fill()
            }
        }
        flushRun()
    }

    private func drawApplicationText(
        _ text: String,
        column: Int,
        row: Int,
        leadingOffset: CGFloat,
        style: ApplicationTextStyle,
        appliesCellKern: Bool
    ) {
        let chosenFont: NSFont
        let cellKern: CGFloat
        if style.flags & UInt16(GT_STYLE_BOLD) != 0 {
            chosenFont = boldFont
            cellKern = boldCellKern
        } else if style.flags & UInt16(GT_STYLE_ITALIC) != 0 {
            chosenFont = italicFont
            cellKern = italicCellKern
        } else {
            chosenFont = font
            cellKern = regularCellKern
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: chosenFont,
            .foregroundColor: applicationForeground(for: style),
        ]
        if appliesCellKern { attributes[.kern] = cellKern }
        (text as NSString).draw(
            at: NSPoint(
                x: CGFloat(column) * cellWidth + leadingOffset,
                y: CGFloat(row) * cellHeight + 1
            ),
            withAttributes: attributes
        )
    }

    private func applicationForeground(for style: ApplicationTextStyle) -> NSColor {
        let foreground = color(
            style.foregroundRed,
            style.foregroundGreen,
            style.foregroundBlue
        )
        return style.flags & UInt16(GT_STYLE_FAINT) != 0
            ? foreground.withAlphaComponent(0.58)
            : foreground
    }

    private func clearApplicationScreenHitTargets() {
        imageHitTargets.removeAll(keepingCapacity: true)
        blockActionHitTargets.removeAll(keepingCapacity: true)
        linkHitTargets.removeAll(keepingCapacity: true)
        hoveredBlockAction = nil
        hoveredLink = nil
        linkActivationCandidate = nil
        for tag in blockActionToolTipTags { removeToolTip(tag) }
        for tag in linkToolTipTags { removeToolTip(tag) }
        blockActionToolTipTags.removeAll(keepingCapacity: true)
        linkToolTipTags.removeAll(keepingCapacity: true)
    }

    static func blockBackgroundRect(
        for range: Range<Int>,
        cellHeight: CGFloat,
        width: CGFloat
    ) -> NSRect {
        NSRect(
            x: blockOuterMargin,
            y: CGFloat(range.lowerBound) * cellHeight,
            width: max(0, width - blockOuterMargin * 2),
            height: CGFloat(range.count) * cellHeight
        )
    }

    static var blockContentLeadingOffset: CGFloat {
        blockOuterMargin + blockContentPadding
    }

    private func terminalPosition(at point: NSPoint) -> TerminalTextPosition? {
        guard let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return nil }
        let frame = framePointer.pointee
        guard frame.rows > 0, frame.cols > 0 else { return nil }
        let ranges = blockRanges(frame: frame, cells: cells)
        let visualLayout = blockVisualLayout(frame: frame, cells: cells, ranges: ranges)
        guard let row = visualLayout.row(at: point.y, cellHeight: cellHeight, nearest: true) else {
            return nil
        }
        let leadingOffset = ranges.contains(where: { $0.contains(row) })
            ? Self.blockContentLeadingOffset
            : Self.terminalContentInset
        let column = min(
            max(0, Int(floor((point.x - leadingOffset) / cellWidth))),
            Int(frame.cols) - 1
        )
        return TerminalTextPosition(
            row: frame.scroll_offset + UInt64(row),
            column: column
        )
    }

    private func blockVisualLayout(
        frame: GTFrame,
        cells: UnsafePointer<GTCell>,
        ranges: [Range<Int>]
    ) -> TerminalBlockVisualLayout {
        var lastContentRow = frame.cursor_visible ? Int(frame.cursor_y) : 0
        for row in 0..<Int(frame.rows) where rowHasVisibleContent(row, frame: frame, cells: cells) {
            lastContentRow = max(lastContentRow, row)
        }
        if let finalRange = ranges.last {
            lastContentRow = max(lastContentRow, finalRange.upperBound - 1)
        }
        let collapsedRangeStarts = Set(ranges.compactMap { range in
            let blockID = TerminalBlockID(
                sessionID: session.id,
                historyRow: frame.scroll_offset + UInt64(range.lowerBound)
            )
            return session.isTerminalBlockCollapsed(blockID) ? range.lowerBound : nil
        })
        let graphicalRows = graphicalListingRows(frame: frame)
        let textRows = Set((0..<Int(frame.rows)).filter {
            rowHasVisibleContent($0, frame: frame, cells: cells)
        })
        return TerminalBlockVisualLayout.make(
            ranges: ranges,
            rowCount: Int(frame.rows),
            cellHeight: cellHeight,
            viewportHeight: bounds.height,
            lastContentRow: lastContentRow,
            collapsedRangeStarts: collapsedRangeStarts,
            collapsedVisibleRows: TerminalBlockRangeResolver.collapsedVisibleRows(
                ranges: ranges,
                collapsedRangeStarts: collapsedRangeStarts,
                graphicalRows: graphicalRows,
                textRows: textRows
            ),
            contentPadding: Self.blockContentPadding,
            blockSpacing: Self.blockSpacing,
            topInset: Self.blockTopInset
        )
    }

    private func selectedTerminalText() -> String? {
        guard let textSelection,
              let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return nil }
        let frame = framePointer.pointee
        let columns = Int(frame.cols)
        let rows = (0..<Int(frame.rows)).map { row in
            (0..<columns).map { column in
                cellText(cells[row * columns + column])
            }
        }
        return TerminalTextSelectionExtractor.text(
            cellRows: rows,
            firstRow: frame.scroll_offset,
            selection: textSelection
        )
    }

    private func clearTextSelection() {
        guard textSelection != nil || textSelectionAnchor != nil else { return }
        textSelection = nil
        textSelectionAnchor = nil
        needsDisplay = true
    }

    private func drawGraphicalBackdrop(in context: CGContext?) {
        guard let context else { return }
        let base = NSColor(srgbRed: 0.020, green: 0.052, blue: 0.069, alpha: 1)
        context.setFillColor(base.cgColor)
        context.fill(bounds)

        guard let graphicalBackdropGradient else { return }
        let radius = max(bounds.width, bounds.height) * 0.82
        context.drawRadialGradient(
            graphicalBackdropGradient,
            startCenter: CGPoint(x: bounds.minX + bounds.width * 0.18, y: bounds.minY),
            startRadius: 0,
            endCenter: CGPoint(x: bounds.minX + bounds.width * 0.18, y: bounds.minY),
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
    }

    private func updateBlockActionHitTargets(
        frame: GTFrame,
        cells: UnsafePointer<GTCell>,
        ranges: [Range<Int>],
        visualLayout: TerminalBlockVisualLayout
    ) {
        let previousTargets = blockActionHitTargets
        var targets: [BlockActionHitTarget] = []

        for (index, range) in ranges.enumerated() {
            guard visualLayout.blockFrames.indices.contains(index) else { continue }
            let blockFrame = visualLayout.blockFrames[index]
            let blockID = TerminalBlockID(
                sessionID: session.id,
                historyRow: frame.scroll_offset + UInt64(range.lowerBound)
            )
            let block = blockContents(for: range, frame: frame, cells: cells)
            var descriptors: [(
                action: BlockAction,
                block: BlockContents?,
                isEnabled: Bool
            )] = []
            if range.count > 1 {
                descriptors.append((
                    action: .toggleFold,
                    block: nil,
                    isEnabled: true
                ))
            }
            descriptors.append((
                action: .toggleBookmark,
                block: block,
                isEnabled: true
            ))
            if let block {
                descriptors.append((
                    action: .rerun,
                    block: block,
                    isEnabled: session.canRunBlockCommand
                ))
                descriptors.append((
                    action: .copy,
                    block: block,
                    isEnabled: true
                ))
                descriptors.append((
                    action: .attach,
                    block: block,
                    isEnabled: !session.hasPendingAIAttachment(for: block.id)
                ))
            }
            let rects = TerminalBlockActionLayout.rects(
                actionCount: descriptors.count,
                trailingEdge: bounds.maxX - Self.blockOuterMargin,
                top: blockFrame.minY + 5
            )
            for (descriptor, rect) in zip(descriptors, rects) {
                targets.append(BlockActionHitTarget(
                    action: descriptor.action,
                    blockID: blockID,
                    block: descriptor.block,
                    rect: rect,
                    isEnabled: descriptor.isEnabled
                ))
            }
        }

        blockActionHitTargets = targets
        if previousTargets != targets { refreshBlockActionToolTips() }
        if let hoveredBlockAction,
           !targets.contains(where: {
               $0.action == hoveredBlockAction.action && $0.blockID == hoveredBlockAction.blockID
           }) {
            self.hoveredBlockAction = nil
        }
        invalidateCursorRectsIfChanged(from: previousTargets)
    }

    private func drawBlockActions() {
        for target in blockActionHitTargets {
            let isHovered = hoveredBlockAction?.action == target.action
                && hoveredBlockAction?.blockID == target.blockID
            let isAttached = target.action == .attach && !target.isEnabled
            let isBookmarked = target.action == .toggleBookmark
                && session.isTerminalBlockBookmarked(target.blockID)
            let buttonRect = target.rect.insetBy(dx: 2, dy: 2)
            let background = NSBezierPath(
                roundedRect: buttonRect,
                xRadius: 5,
                yRadius: 5
            )
            if isHovered, target.isEnabled {
                NSColor.white.withAlphaComponent(0.11).setFill()
            } else if isAttached || isBookmarked {
                NSColor(srgbRed: 0.27, green: 0.83, blue: 0.81, alpha: 0.12).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.045).setFill()
            }
            background.fill()
            NSColor.white.withAlphaComponent(isHovered ? 0.16 : 0.07).setStroke()
            background.lineWidth = 1
            background.stroke()

            let symbolName: String
            switch target.action {
            case .toggleFold:
                symbolName = session.isTerminalBlockCollapsed(target.blockID)
                    ? "chevron.right"
                    : "chevron.down"
            case .toggleBookmark:
                symbolName = isBookmarked ? "bookmark.fill" : "bookmark"
            case .rerun:
                symbolName = "arrow.clockwise"
            case .copy:
                symbolName = "doc.on.doc"
            case .attach:
                symbolName = isAttached ? "checkmark.circle.fill" : "paperclip"
            }
            guard let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: blockActionHelp(for: target)
            ) else {
                continue
            }
            let tint = isAttached || isBookmarked
                ? NSColor(srgbRed: 0.43, green: 0.95, blue: 0.91, alpha: 0.92)
                : NSColor.white.withAlphaComponent(target.isEnabled ? 0.72 : 0.30)
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(.init(hierarchicalColor: tint))
            let configuredImage = image.withSymbolConfiguration(configuration) ?? image
            let iconRect = NSRect(
                x: buttonRect.midX - 6,
                y: buttonRect.midY - 6,
                width: 12,
                height: 12
            )
            configuredImage.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }

    private func refreshBlockActionToolTips() {
        for tag in blockActionToolTipTags { removeToolTip(tag) }
        blockActionToolTipTags = blockActionHitTargets.map { target in
            addToolTip(
                target.rect,
                owner: blockActionHelp(for: target) as NSString,
                userData: nil
            )
        }
    }

    private func blockActionHelp(for target: BlockActionHitTarget) -> String {
        switch target.action {
        case .toggleFold:
            session.isTerminalBlockCollapsed(target.blockID) ? "Expand block" : "Collapse block"
        case .toggleBookmark:
            session.isTerminalBlockBookmarked(target.blockID)
                ? "Remove block bookmark"
                : "Bookmark block"
        case .rerun:
            target.isEnabled ? "Run command again" : "Run again when the prompt is ready"
        case .copy:
            "Copy block output"
        case .attach:
            target.isEnabled ? "Attach block to AI Chat" : "Already attached to AI Chat"
        }
    }

    private func performBlockAction(_ target: BlockActionHitTarget) {
        selectedBlockHistoryRows = [target.blockID.historyRow]
        switch target.action {
        case .toggleFold:
            session.toggleTerminalBlockCollapsed(target.blockID)
        case .toggleBookmark:
            session.toggleTerminalBlockBookmarked(
                target.blockID,
                command: target.block?.command ?? "",
                output: target.block?.output ?? "",
                workingDirectory: target.block?.workingDirectory
            )
        case .rerun:
            guard let block = target.block else { return }
            session.rerunBlockCommand(block.command)
        case .copy:
            guard let block = target.block else { return }
            copyToPasteboard(block.output.isEmpty ? block.command : block.output)
        case .attach:
            guard let block = target.block else { return }
            session.attachToAI(
                command: block.command,
                output: session.fullOutput(for: block.command) ?? block.output,
                workingDirectory: block.workingDirectory,
                sourceBlockID: block.id
            )
        }
        refreshBlockActionToolTips()
        needsDisplay = true
    }

    private func updateLinkHitTargets(
        frame: GTFrame,
        cells: UnsafePointer<GTCell>,
        rowOffsets: [CGFloat],
        rowLeadingOffsets: [CGFloat],
        hiddenRows: Set<Int>
    ) {
        let previousTargets = linkHitTargets
        if frame.alternate_screen {
            linkHitTargets = []
            hoveredLink = nil
            linkActivationCandidate = nil
            if previousTargets != linkHitTargets { refreshLinkToolTips() }
            invalidateCursorRectsIfChanged(from: previousTargets)
            return
        }
        let columnCount = Int(frame.cols)
        var targets: [LinkHitTarget] = []
        for row in 0..<Int(frame.rows) where !hiddenRows.contains(row) {
            let rowCells = (0..<columnCount).map { column in
                cellText(cells[row * columnCount + column])
            }
            for match in TerminalLinkDetector.links(in: rowCells) {
                guard !match.columns.isEmpty,
                      rowOffsets.indices.contains(row),
                      rowLeadingOffsets.indices.contains(row) else { continue }
                targets.append(LinkHitTarget(
                    url: match.url,
                    row: row,
                    columns: match.columns,
                    rect: NSRect(
                        x: CGFloat(match.columns.lowerBound) * cellWidth
                            + rowLeadingOffsets[row],
                        y: CGFloat(row) * cellHeight + rowOffsets[row],
                        width: CGFloat(match.columns.count) * cellWidth,
                        height: cellHeight
                    )
                ))
            }
        }

        linkHitTargets = targets
        if previousTargets != targets { refreshLinkToolTips() }
        if let hoveredLink, !targets.contains(hoveredLink) {
            self.hoveredLink = nil
        }
        if let linkActivationCandidate, !targets.contains(linkActivationCandidate) {
            self.linkActivationCandidate = nil
        }
        invalidateCursorRectsIfChanged(from: previousTargets)
    }

    private func refreshLinkToolTips() {
        for tag in linkToolTipTags { removeToolTip(tag) }
        linkToolTipTags = linkHitTargets.map { target in
            addToolTip(
                target.rect,
                owner: "Open \(target.url.absoluteString)" as NSString,
                userData: nil
            )
        }
    }

    private func updateGraphicalHitTargets(
        _ frame: GTFrame,
        rowOffsets: [CGFloat],
        rowLeadingOffsets: [CGFloat],
        hiddenRows: Set<Int>
    ) {
        let previousTargets = imageHitTargets
        guard session.graphicalMode, !frame.alternate_screen,
              let images = frame.images, frame.image_count > 0 else {
            imageHitTargets = []
            selectedGraphicalPlacementID = nil
            hoveredGraphicalPlacementID = nil
            dropTargetGraphicalPlacementID = nil
            invalidateCursorRectsIfChanged(from: previousTargets)
            return
        }

        imageHitTargets = (0..<Int(frame.image_count)).compactMap { index in
            let placement = images[index]
            guard placement.placement_id != 0,
                  !hiddenRows.contains(Int(placement.viewport_row)) else { return nil }
            let imageRect = imageRect(
                for: placement,
                rowOffsets: rowOffsets,
                rowLeadingOffsets: rowLeadingOffsets
            )
            let layout = session.graphicalItemHitLayout(for: placement.placement_id)
            let tileStartX = max(6, imageRect.minX - cellWidth * CGFloat(layout.0))
            return ImageHitTarget(
                placementID: placement.placement_id,
                rect: NSRect(
                    x: tileStartX,
                    y: imageRect.minY,
                    width: min(
                        cellWidth * CGFloat(layout.1),
                        max(0, bounds.maxX - 8 - tileStartX)
                    ),
                    height: cellHeight * CGFloat(layout.2)
                )
            )
        }

        if let selectedGraphicalPlacementID,
           !imageHitTargets.contains(where: { $0.placementID == selectedGraphicalPlacementID }),
           !session.isCurrentGraphicalPlacement(selectedGraphicalPlacementID) {
            self.selectedGraphicalPlacementID = nil
        }
        if let hoveredGraphicalPlacementID,
           !imageHitTargets.contains(where: { $0.placementID == hoveredGraphicalPlacementID }) {
            self.hoveredGraphicalPlacementID = nil
        }
        if let dropTargetGraphicalPlacementID,
           !imageHitTargets.contains(where: { $0.placementID == dropTargetGraphicalPlacementID }) {
            self.dropTargetGraphicalPlacementID = nil
        }
        invalidateCursorRectsIfChanged(from: previousTargets)
    }

    private func drawGraphicalItemSurfaces() {
        guard session.graphicalMode else { return }
        for target in imageHitTargets {
            if target.placementID == dropTargetGraphicalPlacementID {
                drawGraphicalDropTarget(in: target.rect)
            } else if target.placementID == selectedGraphicalPlacementID {
                drawGraphicalSelection(in: target.rect)
            } else if target.placementID == hoveredGraphicalPlacementID {
                drawGraphicalHover(in: target.rect)
            }
        }
    }

    private func imageRect(
        for placement: GTImage,
        rowOffsets: [CGFloat],
        rowLeadingOffsets: [CGFloat]
    ) -> NSRect {
        let placementRow = Int(placement.viewport_row)
        let rowOffset = rowOffsets.indices.contains(placementRow) ? rowOffsets[placementRow] : 0
        let leadingOffset = rowLeadingOffsets.indices.contains(placementRow)
            ? rowLeadingOffsets[placementRow]
            : Self.terminalContentInset
        return NSRect(
            x: CGFloat(placement.viewport_col) * cellWidth
                + CGFloat(placement.cell_offset_x)
                + leadingOffset,
            y: CGFloat(placement.viewport_row) * cellHeight
                + CGFloat(placement.cell_offset_y)
                + rowOffset,
            width: CGFloat(placement.pixel_width),
            height: CGFloat(placement.pixel_height)
        )
    }

    private func drawImages(
        _ frame: GTFrame,
        rowOffsets: [CGFloat],
        rowLeadingOffsets: [CGFloat],
        hiddenRows: Set<Int>
    ) {
        guard let images = frame.images, frame.image_count > 0 else { return }
        for index in 0..<Int(frame.image_count) {
            let placement = images[index]
            guard !hiddenRows.contains(Int(placement.viewport_row)) else { continue }
            guard let cgImage = cachedImage(for: placement) else { continue }
            let displayedImage = folderBloomImage(for: placement, baseImage: cgImage) ?? cgImage
            let rect = imageRect(
                for: placement,
                rowOffsets: rowOffsets,
                rowLeadingOffsets: rowLeadingOffsets
            )
            NSImage(cgImage: displayedImage, size: rect.size).draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }

    private func drawGraphicalHover(in rect: NSRect) {
        let highlight = rect.insetBy(dx: 3, dy: 2)
        let path = NSBezierPath(
            roundedRect: highlight,
            xRadius: 8,
            yRadius: 8
        )
        NSColor.white.withAlphaComponent(0.055).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawGraphicalSelection(in rect: NSRect) {
        let highlight = rect.insetBy(dx: 3, dy: 2)
        let glowPadding: CGFloat = 9
        let scale = window?.backingScaleFactor ?? 2
        if let glowImage = selectionGlowImage(for: highlight.size, scale: scale) {
            let glowRect = highlight.insetBy(dx: -glowPadding, dy: -glowPadding)
            NSImage(cgImage: glowImage, size: glowRect.size).draw(
                in: glowRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        let fill = NSColor(srgbRed: 0.24, green: 0.78, blue: 0.78, alpha: 0.14)
        fill.setFill()
        NSBezierPath(
            roundedRect: highlight,
            xRadius: 8,
            yRadius: 8
        ).fill()

        let turquoise = NSColor(srgbRed: 0.43, green: 0.95, blue: 0.91, alpha: 0.94)
        turquoise.setStroke()
        let border = NSBezierPath(
            roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 7.5,
            yRadius: 7.5
        )
        border.lineWidth = 1
        border.stroke()
    }

    private func drawGraphicalDropTarget(in rect: NSRect) {
        let highlight = rect.insetBy(dx: 2, dy: 1)
        let path = NSBezierPath(roundedRect: highlight, xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.22, green: 0.82, blue: 0.78, alpha: 0.24).setFill()
        path.fill()
        NSColor(srgbRed: 0.48, green: 1.0, blue: 0.93, alpha: 0.98).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func selectionGlowImage(for size: NSSize, scale: CGFloat) -> CGImage? {
        let glowPadding: CGFloat = 9
        let pixelWidth = max(1, Int(ceil(size.width * scale)))
        let pixelHeight = max(1, Int(ceil(size.height * scale)))
        let pixelPadding = Int(ceil(glowPadding * scale))
        let key = "\(pixelWidth)x\(pixelHeight)@\(pixelPadding)"
        if let cached = selectionGlowCache[key] { return cached }

        let innerExtent = CGRect(
            x: pixelPadding,
            y: pixelPadding,
            width: pixelWidth,
            height: pixelHeight
        )
        guard let roundedRectangle = CIFilter(name: "CIRoundedRectangleGenerator"),
              let bloom = CIFilter(name: "CIBloom") else { return nil }
        roundedRectangle.setValue(CIVector(cgRect: innerExtent), forKey: "inputExtent")
        roundedRectangle.setValue(6 * scale, forKey: "inputRadius")
        roundedRectangle.setValue(
            CIColor(red: 0.38, green: 0.96, blue: 0.90, alpha: 0.20),
            forKey: "inputColor"
        )
        guard let baseImage = roundedRectangle.outputImage else { return nil }

        bloom.setValue(baseImage, forKey: kCIInputImageKey)
        bloom.setValue(5.5 * scale, forKey: kCIInputRadiusKey)
        bloom.setValue(1.05, forKey: kCIInputIntensityKey)
        let outputExtent = CGRect(
            x: 0,
            y: 0,
            width: pixelWidth + pixelPadding * 2,
            height: pixelHeight + pixelPadding * 2
        )
        guard let output = bloom.outputImage?.cropped(to: outputExtent),
              let image = ciContext.createCGImage(output, from: outputExtent) else { return nil }
        selectionGlowCache[key] = image
        return image
    }

    private func cachedImage(for placement: GTImage) -> CGImage? {
        if let cached = imageCache[placement.image_id] { return cached }
        guard placement.pixel_format == 1,
              let pixels = placement.pixels,
              placement.image_width > 0,
              placement.image_height > 0 else { return nil }
        let required = Int(placement.image_width * placement.image_height * 4)
        guard placement.pixels_len >= required else { return nil }
        let data = Data(bytes: pixels, count: required) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: Int(placement.image_width),
                height: Int(placement.image_height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Int(placement.image_width) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        imageCache[placement.image_id] = image
        return image
    }

    private func folderBloomImage(for placement: GTImage, baseImage: CGImage) -> CGImage? {
        guard session.graphicalItem(for: placement.placement_id)?.kind == .directory else { return nil }
        if let cached = folderBloomCache[placement.image_id] { return cached }
        guard let filter = CIFilter(name: "CIBloom") else { return nil }
        let input = CIImage(cgImage: baseImage)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(1.4, forKey: kCIInputRadiusKey)
        filter.setValue(0.34, forKey: kCIInputIntensityKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let image = ciContext.createCGImage(output, from: input.extent) else { return nil }
        folderBloomCache[placement.image_id] = image
        return image
    }

    private func invalidateCursorRectsIfChanged(from previousTargets: [ImageHitTarget]) {
        guard previousTargets != imageHitTargets else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window = self.window else { return }
            window.invalidateCursorRects(for: self)
        }
    }

    private func invalidateCursorRectsIfChanged(from previousTargets: [BlockActionHitTarget]) {
        guard previousTargets != blockActionHitTargets else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window = self.window else { return }
            window.invalidateCursorRects(for: self)
        }
    }

    private func invalidateCursorRectsIfChanged(from previousTargets: [LinkHitTarget]) {
        guard previousTargets != linkHitTargets else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window = self.window else { return }
            window.invalidateCursorRects(for: self)
        }
    }

    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> NSColor {
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private func drawScrollbar(_ frame: GTFrame) {
        guard frame.scroll_total > frame.scroll_length, frame.scroll_length > 0 else { return }
        let trackHeight = max(1, bounds.height - 8)
        let fraction = CGFloat(frame.scroll_length) / CGFloat(frame.scroll_total)
        let thumbHeight = max(28, trackHeight * fraction)
        let maximumOffset = max(1, frame.scroll_total - frame.scroll_length)
        let progress = CGFloat(frame.scroll_offset) / CGFloat(maximumOffset)
        let thumbY = 4 + (trackHeight - thumbHeight) * progress
        let rect = NSRect(x: bounds.maxX - 5, y: thumbY, width: 3, height: thumbHeight)
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        enabled: Bool,
        systemImage: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        }
        return item
    }

    func graphicalItemMenu(for item: GraphicalFileItem) -> NSMenu {
        contextGraphicalItem = item
        if session.graphicalItemIsDirectory(item) {
            return folderMenu(for: item)
        }
        return fileMenu(for: item)
    }

    private func folderMenu(for item: GraphicalFileItem) -> NSMenu {
        let menu = NSMenu()
        let canModify = item.name != ".." && item.path != "/"

        menu.addItem(menuItem("Open", action: #selector(openGraphicalItem), enabled: true))
        menu.addItem(menuItem("List", action: #selector(listGraphicalDirectory), enabled: true))
        menu.addItem(menuItem(
            "Open in New Tab",
            action: #selector(openGraphicalFolderInNewTab),
            enabled: true
        ))
        menu.addItem(menuItem(
            "Show in Finder",
            action: #selector(showGraphicalItemInFinder),
            enabled: true
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem("Get Info", action: #selector(showGraphicalItemInfo), enabled: true))
        if canModify {
            menu.addItem(menuItem("Rename", action: #selector(renameGraphicalItem), enabled: true))
            menu.addItem(menuItem(
                "Compress “\(item.name)”",
                action: #selector(compressGraphicalItem),
                enabled: true
            ))
            menu.addItem(menuItem("Duplicate", action: #selector(duplicateGraphicalItem), enabled: true))
        }
        menu.addItem(menuItem("Quick Look", action: #selector(quickLookGraphicalItem), enabled: true))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy", action: #selector(copyGraphicalItem), enabled: true))
        menu.addItem(menuItem(
            "Paste Item",
            action: #selector(pasteGraphicalItem),
            enabled: canPasteFiles
        ))
        menu.addItem(shareMenuItem(for: item))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Attach Directory Listing to AI Chat",
            action: #selector(attachOutputToAI),
            enabled: session.canAttachGraphicalOutputToAI
        ))
        if canModify {
            menu.addItem(.separator())
            menu.addItem(menuItem(
                "Move to Trash",
                action: #selector(moveGraphicalItemToTrash),
                enabled: true
            ))
        }
        return menu
    }

    private func fileMenu(for item: GraphicalFileItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Open", action: #selector(openGraphicalItem), enabled: true))
        menu.addItem(openWithMenuItem(for: item))
        if session.graphicalItemCanDisplayAsText(item) {
            menu.addItem(menuItem(
                "Cat",
                action: #selector(catGraphicalFile),
                enabled: true,
                systemImage: "doc.text"
            ))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy", action: #selector(copyGraphicalItem), enabled: true))
        menu.addItem(menuItem(
            "Paste",
            action: #selector(pasteGraphicalItem),
            enabled: canPasteFiles
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Attach Directory Listing to AI Chat",
            action: #selector(attachOutputToAI),
            enabled: session.canAttachGraphicalOutputToAI
        ))
        return menu
    }

    private var canPasteFiles: Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func shareMenuItem(for item: GraphicalFileItem) -> NSMenuItem {
        let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: item.path)])
        sharingPicker = picker
        let shareItem = picker.standardShareMenuItem
        shareItem.title = "Share"
        return shareItem
    }

    func openWithMenuItem(for item: GraphicalFileItem) -> NSMenuItem {
        let parentItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open With")
        let itemURL = URL(fileURLWithPath: item.path)
        var seenApplicationURLs: Set<URL> = []
        let applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: itemURL)
            .filter { seenApplicationURLs.insert($0.standardizedFileURL).inserted }
            .sorted {
                applicationName(for: $0).localizedStandardCompare(applicationName(for: $1))
                    == .orderedAscending
            }

        if applicationURLs.isEmpty {
            submenu.addItem(menuItem(
                "No Recommended Applications",
                action: #selector(openGraphicalItem),
                enabled: false
            ))
        } else {
            for applicationURL in applicationURLs {
                let applicationItem = menuItem(
                    applicationName(for: applicationURL),
                    action: #selector(openGraphicalItemWithApplication(_:)),
                    enabled: true
                )
                applicationItem.representedObject = applicationURL
                let icon = NSWorkspace.shared.icon(forFile: applicationURL.path).copy() as? NSImage
                icon?.size = NSSize(width: 16, height: 16)
                applicationItem.image = icon
                submenu.addItem(applicationItem)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            "Other…",
            action: #selector(chooseApplicationForGraphicalItem),
            enabled: true
        ))
        parentItem.submenu = submenu
        return parentItem
    }

    private func applicationName(for url: URL) -> String {
        let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName
        let name = localizedName ?? url.lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    private func selectBlock(atVisualY visualY: CGFloat, modifiers: NSEvent.ModifierFlags) {
        guard let handle = session.handle, let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else {
            selectedBlockHistoryRows.removeAll()
            needsDisplay = true
            return
        }
        let frame = framePointer.pointee
        let ranges = blockRanges(frame: frame, cells: cells)
        guard let clickedRow = blockVisualLayout(frame: frame, cells: cells, ranges: ranges)
            .blockRange(at: visualY)
            .map({ frame.scroll_offset + UInt64($0.lowerBound) }) else {
            selectedBlockHistoryRows.removeAll()
            needsDisplay = true
            return
        }
        let visibleRows = ranges.map { frame.scroll_offset + UInt64($0.lowerBound) }
        if modifiers.contains(.command) {
            if !selectedBlockHistoryRows.insert(clickedRow).inserted {
                selectedBlockHistoryRows.remove(clickedRow)
            }
        } else if modifiers.contains(.shift),
                  let anchor = selectedBlockHistoryRows.sorted().last,
                  let anchorIndex = visibleRows.firstIndex(of: anchor),
                  let clickedIndex = visibleRows.firstIndex(of: clickedRow) {
            let lower = min(anchorIndex, clickedIndex)
            let upper = max(anchorIndex, clickedIndex)
            selectedBlockHistoryRows.formUnion(visibleRows[lower...upper])
        } else {
            selectedBlockHistoryRows = [clickedRow]
        }
        needsDisplay = true
    }

    private func selectedBlockContents() -> [BlockContents] {
        guard let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return [] }
        let frame = framePointer.pointee
        return blockRanges(frame: frame, cells: cells).compactMap { range in
            let historyRow = frame.scroll_offset + UInt64(range.lowerBound)
            guard selectedBlockHistoryRows.contains(historyRow) else { return nil }
            return blockContents(for: range, frame: frame, cells: cells)
        }
    }

    private func selectAllVisibleBlocks() {
        guard let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return }
        let frame = framePointer.pointee
        selectedBlockHistoryRows = Set(blockRanges(frame: frame, cells: cells).map {
            frame.scroll_offset + UInt64($0.lowerBound)
        })
        needsDisplay = true
    }

    private func selectRelativeBlock(_ delta: Int, extending: Bool) {
        guard let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return }
        let frame = framePointer.pointee
        let rows = blockRanges(frame: frame, cells: cells).map {
            frame.scroll_offset + UInt64($0.lowerBound)
        }
        guard !rows.isEmpty else { return }
        let current = delta < 0 ? selectedBlockHistoryRows.min() : selectedBlockHistoryRows.max()
        let currentIndex = current.flatMap { rows.firstIndex(of: $0) }
            ?? (delta < 0 ? rows.count : -1)
        let targetIndex = min(rows.count - 1, max(0, currentIndex + delta))
        if extending {
            selectedBlockHistoryRows.insert(rows[targetIndex])
        } else {
            selectedBlockHistoryRows = [rows[targetIndex]]
        }
        needsDisplay = true
    }

    private func copySelectedBlocks(commandOnly: Bool, outputOnly: Bool) {
        let values = selectedBlockContents().map { block -> String in
            let output = session.fullOutput(for: block.command) ?? block.output
            if commandOnly { return block.command }
            if outputOnly { return output }
            return [block.command, output].filter { !$0.isEmpty }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        copyToPasteboard(values.joined(separator: "\n\n"))
    }

    @objc private func copyOutput() {
        guard let contextBlock else { return }
        copyToPasteboard(session.fullOutput(for: contextBlock.command) ?? contextBlock.output)
    }
    @objc private func copyCommand() { copyToPasteboard(contextBlock?.command) }
    @objc private func copyCommandAndOutput() {
        guard let contextBlock else { return }
        let output = session.fullOutput(for: contextBlock.command) ?? contextBlock.output
        copyToPasteboard([contextBlock.command, output].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
    @objc private func copyWorkingDirectory() { copyToPasteboard(contextBlock?.workingDirectory) }
    @objc private func rerunCommand() {
        guard let contextBlock else { return }
        session.rerunBlockCommand(contextBlock.command)
    }
    @objc private func reinputCommand() {
        guard let contextBlock else { return }
        session.reinputBlockCommand(contextBlock.command)
    }
    @objc private func toggleContextBlockBookmark() {
        guard let contextBlock else { return }
        session.toggleTerminalBlockBookmarked(
            contextBlock.id,
            command: contextBlock.command,
            output: contextBlock.output,
            workingDirectory: contextBlock.workingDirectory
        )
        needsDisplay = true
    }
    @objc private func toggleContextBlockFold() {
        guard let contextBlock else { return }
        session.toggleTerminalBlockCollapsed(contextBlock.id)
        needsDisplay = true
    }
    @objc private func copyTerminalSelection() { copyToPasteboard(selectedTerminalText()) }

    @objc private func openGraphicalItem() {
        guard let contextGraphicalItem else { return }
        session.activateGraphicalItem(contextGraphicalItem)
    }

    @objc private func listGraphicalDirectory() {
        guard let contextGraphicalItem else { return }
        session.listGraphicalDirectory(contextGraphicalItem)
    }

    @objc private func catGraphicalFile() {
        guard let contextGraphicalItem else { return }
        session.catGraphicalFile(contextGraphicalItem)
    }

    @objc private func openGraphicalFolderInNewTab() {
        guard let contextGraphicalItem,
              session.graphicalItemIsDirectory(contextGraphicalItem) else { return }
        openDirectoryInNewTab(URL(fileURLWithPath: contextGraphicalItem.path, isDirectory: true))
    }

    @objc private func showGraphicalItemInFinder() {
        guard let contextGraphicalItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: contextGraphicalItem.path),
        ])
    }

    @objc private func showGraphicalItemInfo() {
        guard let contextGraphicalItem else { return }
        let url = URL(fileURLWithPath: contextGraphicalItem.path)
        let kind = session.graphicalItemIsDirectory(contextGraphicalItem) ? "Folder" : "File"
        let size = Int64(clamping: contextGraphicalItem.size).formatted(.byteCount(style: .file))
        let modified = contextGraphicalItem.modified.formatted(date: .abbreviated, time: .shortened)
        let alert = NSAlert()
        alert.messageText = "“\(contextGraphicalItem.name)” Info"
        alert.informativeText = """
        Kind: \(kind)
        Size: \(size)
        Modified: \(modified)
        Permissions: \(contextGraphicalItem.permissions)
        Where: \(url.deletingLastPathComponent().path)
        """
        alert.icon = NSWorkspace.shared.icon(forFile: url.path)
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    @objc private func renameGraphicalItem() {
        guard let contextGraphicalItem, let window else { return }
        let source = URL(fileURLWithPath: contextGraphicalItem.path)
        let field = NSTextField(string: contextGraphicalItem.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.selectText(nil)

        let alert = NSAlert()
        alert.messageText = "Rename “\(contextGraphicalItem.name)”"
        alert.informativeText = "Enter a new name for this folder."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                _ = try GraphicalFileOperations.rename(source, to: field.stringValue)
                self.session.showCurrentDirectoryGraphically()
            } catch {
                self.presentOperationError(error)
            }
        }
    }

    @objc private func compressGraphicalItem() {
        guard let contextGraphicalItem else { return }
        let source = URL(fileURLWithPath: contextGraphicalItem.path)
        Task { @MainActor [weak self] in
            do {
                try await TerminalSession.ensureUbiquitousItemIsAvailable(at: source)
                _ = try await GraphicalFileOperations.compress(source)
                self?.session.showCurrentDirectoryGraphically()
            } catch {
                self?.presentOperationError(error)
            }
        }
    }

    @objc private func duplicateGraphicalItem() {
        guard let contextGraphicalItem else { return }
        let source = URL(fileURLWithPath: contextGraphicalItem.path)
        Task { @MainActor [weak self] in
            do {
                try await TerminalSession.ensureUbiquitousItemIsAvailable(at: source)
                _ = try await NSWorkspace.shared.duplicate([source])
                self?.session.showCurrentDirectoryGraphically()
            } catch {
                self?.presentOperationError(error)
            }
        }
    }

    @objc private func quickLookGraphicalItem() {
        guard let contextGraphicalItem else { return }
        let url = URL(fileURLWithPath: contextGraphicalItem.path)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await TerminalSession.ensureUbiquitousItemIsAvailable(at: url)
                self.quickLookURL = url
                self.focusTerminal()
                guard let panel = QLPreviewPanel.shared() else { return }
                panel.updateController()
                panel.makeKeyAndOrderFront(nil)
            } catch {
                self.presentOperationError(error)
            }
        }
    }

    @objc private func moveGraphicalItemToTrash() {
        guard let contextGraphicalItem else { return }
        let source = URL(fileURLWithPath: contextGraphicalItem.path)
        Task { @MainActor [weak self] in
            do {
                _ = try await NSWorkspace.shared.recycle([source])
                self?.session.showCurrentDirectoryGraphically()
            } catch {
                self?.presentOperationError(error)
            }
        }
    }

    @objc private func openGraphicalItemWithApplication(_ sender: NSMenuItem) {
        guard let contextGraphicalItem,
              let applicationURL = sender.representedObject as? URL else { return }
        openGraphicalItemWithApplication(contextGraphicalItem, applicationURL: applicationURL)
    }

    @objc private func chooseApplicationForGraphicalItem() {
        guard contextGraphicalItem != nil, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,
                  let self,
                  let contextGraphicalItem = self.contextGraphicalItem,
                  let applicationURL = panel.url else { return }
            self.openGraphicalItemWithApplication(
                contextGraphicalItem,
                applicationURL: applicationURL
            )
        }
    }

    private func openGraphicalItemWithApplication(
        _ item: GraphicalFileItem,
        applicationURL: URL
    ) {
        let url = URL(fileURLWithPath: item.path)
        Task { @MainActor [weak self] in
            do {
                try await TerminalSession.ensureUbiquitousItemIsAvailable(at: url)
                let configuration = NSWorkspace.OpenConfiguration()
                try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                )
            } catch {
                self?.presentOperationError(error)
            }
        }
    }

    @objc private func copyGraphicalItem() {
        guard let contextGraphicalItem else { return }
        session.copyGraphicalItem(contextGraphicalItem)
    }

    @objc private func pasteGraphicalItem() {
        guard let contextGraphicalItem else { return }
        if !session.pasteGraphicalItems(onto: contextGraphicalItem) { NSSound.beep() }
    }

    @objc private func attachOutputToAI() {
        let selectedBlocks = selectedBlockContents()
        if !selectedBlocks.isEmpty {
            for block in selectedBlocks {
                session.attachToAI(
                    command: block.command,
                    output: session.fullOutput(for: block.command) ?? block.output,
                    workingDirectory: block.workingDirectory,
                    sourceBlockID: block.id
                )
            }
        } else if let block = contextBlock {
            session.attachToAI(
                command: block.command,
                output: session.fullOutput(for: block.command) ?? block.output,
                workingDirectory: block.workingDirectory,
                sourceBlockID: block.id
            )
        } else {
            session.attachGraphicalOutputToAI()
        }
    }

    @objc private func pasteIntoTerminal() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        session.paste(value)
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func present(_ alert: NSAlert) {
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentOperationError(_ error: any Error) {
        present(NSAlert(error: error))
    }

    private func blockRanges(frame: GTFrame, cells: UnsafePointer<GTCell>) -> [Range<Int>] {
        guard !frame.alternate_screen else { return [] }
        let rowCount = Int(frame.rows)
        let inputRows = (0..<rowCount).map { row in
            (0..<Int(frame.cols)).contains { column in
                cells[row * Int(frame.cols) + column].semantic_content
                    == UInt8(GT_SEMANTIC_INPUT)
            }
        }
        let semantics = TerminalBlockRangeResolver.normalizedSemantics(
            rowSemantics: (0..<rowCount).map { frame.row_semantics?[$0] ?? 0 },
            inputRows: inputRows
        )
        var visibleRows = (0..<rowCount).map {
            rowHasVisibleContent($0, frame: frame, cells: cells)
        }
        for row in graphicalImageRows(frame: frame) {
            visibleRows[row] = true
        }
        let ranges = TerminalBlockRangeResolver.ranges(
            rowSemantics: semantics,
            visibleRows: visibleRows,
            cursorRow: frame.cursor_visible ? Int(frame.cursor_y) : nil,
            inputRows: inputRows
        )
        return TerminalBlockRangeResolver.mergingGraphicalOutputWithActivePrompt(
            ranges: ranges,
            graphicalRows: graphicalListingRows(frame: frame),
            cursorRow: frame.cursor_visible ? Int(frame.cursor_y) : nil
        )
    }

    private func graphicalImageRows(frame: GTFrame) -> Set<Int> {
        guard let images = frame.images else { return [] }
        var rows: Set<Int> = []
        for index in 0..<Int(frame.image_count) {
            let placement = images[index]
            let layoutRowHeight = session.graphicalItem(for: placement.placement_id) == nil
                ? 1
                : session.graphicalItemHitLayout(for: placement.placement_id).2
            guard let range = TerminalGraphicalRowCoverage.range(
                placementRow: Int(placement.viewport_row),
                cellOffsetY: CGFloat(placement.cell_offset_y),
                pixelHeight: CGFloat(placement.pixel_height),
                layoutRowHeight: layoutRowHeight,
                rowCount: Int(frame.rows),
                cellHeight: cellHeight
            ) else { continue }
            rows.formUnion(range)
        }
        return rows
    }

    private func graphicalListingRows(frame: GTFrame) -> Set<Int> {
        guard let images = frame.images else { return [] }
        var rows: Set<Int> = []
        for index in 0..<Int(frame.image_count) {
            let placement = images[index]
            guard session.graphicalItem(for: placement.placement_id) != nil,
                  let range = TerminalGraphicalRowCoverage.range(
                      placementRow: Int(placement.viewport_row),
                      cellOffsetY: CGFloat(placement.cell_offset_y),
                      pixelHeight: CGFloat(placement.pixel_height),
                      layoutRowHeight: session.graphicalItemHitLayout(
                          for: placement.placement_id
                      ).2,
                      rowCount: Int(frame.rows),
                      cellHeight: cellHeight
                  ) else { continue }
            rows.formUnion(range)
        }
        return rows
    }

    private func rowHasVisibleContent(_ row: Int, frame: GTFrame, cells: UnsafePointer<GTCell>) -> Bool {
        (0..<Int(frame.cols)).contains { x in
            let cell = cells[row * Int(frame.cols) + x]
            return cell.text_len > 0 && cell.style & UInt16(GT_STYLE_INVISIBLE) == 0
        }
    }

    private func blockContents(at row: Int) -> BlockContents? {
        guard let handle = session.handle, let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return nil }
        let frame = framePointer.pointee
        let ranges = blockRanges(frame: frame, cells: cells)
        guard let range = ranges.last(where: { $0.contains(row) }) else {
            return nil
        }
        return blockContents(for: range, frame: frame, cells: cells)
    }

    private func blockContents(
        for range: Range<Int>,
        frame: GTFrame,
        cells: UnsafePointer<GTCell>
    ) -> BlockContents? {
        let blockID = TerminalBlockID(
            sessionID: session.id,
            historyRow: frame.scroll_offset + UInt64(range.lowerBound)
        )
        var commandRows: [String] = []
        for y in range {
            var text = ""
            for x in 0..<Int(frame.cols) {
                let cell = cells[y * Int(frame.cols) + x]
                if cell.semantic_content == UInt8(GT_SEMANTIC_INPUT) { text += cellText(cell) }
            }
            if !text.isEmpty { commandRows.append(text) }
        }
        var command = commandRows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var renderedCommandRows: Set<Int> = []
        if command.isEmpty {
            let containsGraphicalImage = frame.images.map { images in
                (0..<Int(frame.image_count)).contains { index in
                    images[index].placement_id != 0
                        && range.contains(Int(images[index].viewport_row))
                }
            } ?? false
            if containsGraphicalImage, let attachment = session.graphicalBlockAttachment() {
                return BlockContents(
                    id: blockID,
                    command: attachment.command,
                    output: attachment.output,
                    workingDirectory: attachment.workingDirectory
                )
            }
            let visibleRows = range.map { row in
                (0..<Int(frame.cols)).map { column in
                    cellText(cells[row * Int(frame.cols) + column])
                }.joined().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            guard let recordedCommand = session.submittedCommand(
                matchingRenderedText: visibleRows.joined()
            ) else { return nil }
            command = recordedCommand

            var renderedPrefix = ""
            for (index, visibleRow) in visibleRows.enumerated() {
                renderedPrefix += visibleRow
                renderedCommandRows.insert(range.lowerBound + index)
                if renderedPrefix.contains(command) { break }
            }
        }
        guard !command.isEmpty else { return nil }

        var outputRows: [String] = []
        if range.lowerBound + 1 < range.upperBound {
            for y in (range.lowerBound + 1)..<range.upperBound {
                if renderedCommandRows.contains(y) { continue }
                let containsCommandInput = (0..<Int(frame.cols)).contains { x in
                    cells[y * Int(frame.cols) + x].semantic_content == UInt8(GT_SEMANTIC_INPUT)
                }
                if containsCommandInput { continue }
                var text = ""
                for x in 0..<Int(frame.cols) { text += cellText(cells[y * Int(frame.cols) + x]) }
                outputRows.append(text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            }
        }
        while outputRows.first?.isEmpty == true { outputRows.removeFirst() }
        while outputRows.last?.isEmpty == true { outputRows.removeLast() }
        return BlockContents(
            id: blockID,
            command: command,
            output: outputRows.joined(separator: "\n"),
            workingDirectory: session.workingDirectory(for: command)
        )
    }

    private func blockContents(atVisualY visualY: CGFloat) -> BlockContents? {
        guard let handle = session.handle,
              let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else { return nil }
        let frame = framePointer.pointee
        let ranges = blockRanges(frame: frame, cells: cells)
        guard let range = blockVisualLayout(frame: frame, cells: cells, ranges: ranges)
            .blockRange(at: visualY) else { return nil }
        return blockContents(for: range, frame: frame, cells: cells)
    }

    private func cellText(_ cell: GTCell) -> String {
        guard cell.text_len > 0, cell.style & UInt16(GT_STYLE_INVISIBLE) == 0 else { return "" }
        return withUnsafeBytes(of: cell.text) { raw in
            String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
        }
    }

    private func drawMessage(_ message: String) {
        NSColor(red: 0.024, green: 0.067, blue: 0.094, alpha: 1).setFill()
        bounds.fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (message as NSString).draw(in: bounds.insetBy(dx: 40, dy: 80), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
    }

    private func drawBadge(_ message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(red: 0.75, green: 0.78, blue: 0.75, alpha: 1),
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: bounds.maxX - size.width - 28, y: bounds.maxY - size.height - 20,
                          width: size.width + 16, height: size.height + 8)
        NSColor(red: 0.035, green: 0.094, blue: 0.122, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (message as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attributes)
    }
}
