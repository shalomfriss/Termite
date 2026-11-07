import AppKit
import GhosttyBridge
import SwiftUI

struct TerminalCanvas: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> TerminalNSView {
        TerminalNSView(session: session)
    }

    func updateNSView(_ view: TerminalNSView, context: Context) {
        view.session = session
        view.needsDisplay = true
    }
}

final class TerminalNSView: NSView {
    private struct BlockContents {
        let command: String
        let output: String
        let workingDirectory: String
    }

    var session: TerminalSession
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    private let italicFont: NSFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat = 20
    private var lastGrid = (cols: UInt16(0), rows: UInt16(0))
    private var windowKeyObserver: NSObjectProtocol?
    private var contextBlock: BlockContents?
    private var selectedBlockHistoryRow: UInt64?

    init(session: TerminalSession) {
        self.session = session
        let descriptor = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontDescriptor
            .withSymbolicTraits(.italic)
        italicFont = NSFont(descriptor: descriptor, size: 14) ?? font
        cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.075, green: 0.086, blue: 0.082, alpha: 1).cgColor
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
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
    }

    private func focusTerminal() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        let cols = UInt16(max(1, min(Int(UInt16.max), Int(bounds.width / cellWidth))))
        let rows = UInt16(max(1, min(Int(UInt16.max), Int(bounds.height / cellHeight))))
        if (cols, rows) != lastGrid {
            lastGrid = (cols, rows)
            session.resize(cols: cols, rows: rows,
                           cellWidth: UInt32(cellWidth), cellHeight: UInt32(cellHeight))
        }
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        let point = convert(event.locationInWindow, from: nil)
        selectBlock(at: Int(point.y / cellHeight))
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
            session.scroll(rows: -rows)
            needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        focusTerminal()
        let point = convert(event.locationInWindow, from: nil)
        contextBlock = blockContents(at: Int(point.y / cellHeight))

        let menu = NSMenu()
        menu.addItem(menuItem("Copy Output", action: #selector(copyOutput), enabled: contextBlock != nil))
        menu.addItem(menuItem("Copy Command", action: #selector(copyCommand), enabled: contextBlock != nil))
        menu.addItem(menuItem("Copy Working Directory", action: #selector(copyWorkingDirectory), enabled: contextBlock != nil))
        menu.addItem(.separator())
        menu.addItem(menuItem("Attach Output to AI Chat", action: #selector(attachOutputToAI), enabled: contextBlock != nil))
        menu.addItem(.separator())
        menu.addItem(menuItem("Paste", action: #selector(pasteIntoTerminal),
                              enabled: NSPasteboard.general.string(forType: .string) != nil))
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if event.charactersIgnoringModifiers == "v",
           let value = NSPasteboard.general.string(forType: .string) {
            session.sendUserInput(Data(value.utf8))
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
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
        if let data = TerminalInput.sequence(for: event) { session.sendUserInput(data) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let handle = session.handle, let framePointer = gt_session_frame(handle) else {
            drawMessage(session.error ?? "Terminal unavailable")
            return
        }
        let frame = framePointer.pointee
        guard let cells = frame.cells else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.setFillColor(NSColor(red: 0.075, green: 0.086, blue: 0.082, alpha: 1).cgColor)
        context?.fill(bounds)

        let ranges = blockRanges(frame: frame, cells: cells)
        let blockFill = NSColor(red: 0.105, green: 0.12, blue: 0.115, alpha: 1)
        let blockStroke = NSColor(red: 0.22, green: 0.25, blue: 0.235, alpha: 0.78)
        let selectedFill = NSColor(red: 0.135, green: 0.155, blue: 0.148, alpha: 1)
        let selectedStroke = NSColor(red: 0.39, green: 0.44, blue: 0.415, alpha: 0.9)
        for range in ranges {
            let rect = NSRect(x: 2, y: CGFloat(range.lowerBound) * cellHeight + 1,
                              width: max(0, bounds.width - 4),
                              height: CGFloat(range.count) * cellHeight - 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            let isSelected = frame.scroll_offset + UInt64(range.lowerBound) == selectedBlockHistoryRow
            (isSelected ? selectedFill : blockFill).setFill()
            path.fill()
            (isSelected ? selectedStroke : blockStroke).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        for y in 0..<Int(frame.rows) {
            let isInBlock = ranges.contains { $0.contains(y) }
            for x in 0..<Int(frame.cols) {
                let cell = cells[y * Int(frame.cols) + x]
                let rect = NSRect(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight,
                                  width: cellWidth + 0.5, height: cellHeight)
                let hasDefaultBackground = cell.bg_r == 20 && cell.bg_g == 23 && cell.bg_b == 22
                if !isInBlock || !hasDefaultBackground {
                    color(cell.bg_r, cell.bg_g, cell.bg_b).setFill()
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
                (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + 1),
                                        withAttributes: [.font: chosenFont, .foregroundColor: foreground])
                if cell.style & UInt16(GT_STYLE_UNDERLINE_MASK) != 0 {
                    foreground.setFill()
                    NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
                }
                if cell.style & UInt16(GT_STYLE_STRIKETHROUGH) != 0 {
                    foreground.setFill()
                    NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1).fill()
                }
            }
        }

        if frame.cursor_visible {
            let cursor = NSRect(x: CGFloat(frame.cursor_x) * cellWidth,
                                y: CGFloat(frame.cursor_y) * cellHeight,
                                width: cellWidth, height: cellHeight)
            color(frame.cursor_r, frame.cursor_g, frame.cursor_b).withAlphaComponent(0.72).setFill()
            cursor.fill(using: .screen)
        }

        if !session.isRunning {
            let status = gt_session_exit_status(handle)
            drawBadge("Process exited with status \(status)")
        }
        drawScrollbar(frame)
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

    private func menuItem(_ title: String, action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func selectBlock(at row: Int) {
        guard let handle = session.handle, let framePointer = gt_session_frame(handle),
              let cells = framePointer.pointee.cells else {
            selectedBlockHistoryRow = nil
            needsDisplay = true
            return
        }
        let frame = framePointer.pointee
        selectedBlockHistoryRow = blockRanges(frame: frame, cells: cells)
            .last(where: { $0.contains(row) })
            .map { frame.scroll_offset + UInt64($0.lowerBound) }
        needsDisplay = true
    }

    @objc private func copyOutput() { copyToPasteboard(contextBlock?.output) }
    @objc private func copyCommand() { copyToPasteboard(contextBlock?.command) }
    @objc private func copyWorkingDirectory() { copyToPasteboard(contextBlock?.workingDirectory) }

    @objc private func attachOutputToAI() {
        guard let block = contextBlock else { return }
        session.attachToAI(
            command: block.command,
            output: session.fullOutput(for: block.command) ?? block.output,
            workingDirectory: block.workingDirectory
        )
    }

    @objc private func pasteIntoTerminal() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        session.sendUserInput(Data(value.utf8))
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func blockRanges(frame: GTFrame, cells: UnsafePointer<GTCell>) -> [Range<Int>] {
        var starts: [Int] = []
        for y in 0..<Int(frame.rows) {
            if frame.row_semantics?[y] == 1 { starts.append(y) }
        }
        return starts.enumerated().map { index, start in
            var limit = index + 1 < starts.count ? starts[index + 1] : Int(frame.rows)
            if index == starts.count - 1, frame.cursor_visible, Int(frame.cursor_y) > start {
                // The shell has drawn its next prompt, but it is not marked as
                // a new semantic prompt until typing begins. Keep that row out
                // of the completed command block.
                limit = min(limit, Int(frame.cursor_y))
            }

            var end = limit
            while end > start + 1 && !rowHasVisibleContent(end - 1, frame: frame, cells: cells) {
                end -= 1
            }
            return start..<max(start + 1, end)
        }
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

        var commandRows: [String] = []
        for y in range {
            var text = ""
            for x in 0..<Int(frame.cols) {
                let cell = cells[y * Int(frame.cols) + x]
                if cell.semantic_content == UInt8(GT_SEMANTIC_INPUT) { text += cellText(cell) }
            }
            if !text.isEmpty { commandRows.append(text) }
        }
        let command = commandRows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        var outputRows: [String] = []
        if range.lowerBound + 1 < range.upperBound {
            for y in (range.lowerBound + 1)..<range.upperBound {
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
        return BlockContents(command: command, output: outputRows.joined(separator: "\n"),
                             workingDirectory: session.workingDirectory(for: command))
    }

    private func cellText(_ cell: GTCell) -> String {
        guard cell.text_len > 0, cell.style & UInt16(GT_STYLE_INVISIBLE) == 0 else { return "" }
        return withUnsafeBytes(of: cell.text) { raw in
            String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
        }
    }

    private func drawMessage(_ message: String) {
        NSColor(red: 0.075, green: 0.086, blue: 0.082, alpha: 1).setFill()
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
        NSColor(red: 0.13, green: 0.15, blue: 0.14, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (message as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attributes)
    }
}
