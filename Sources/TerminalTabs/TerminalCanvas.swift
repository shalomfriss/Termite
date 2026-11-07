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
    var session: TerminalSession
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    private let italicFont: NSFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat = 20
    private var lastGrid = (cols: UInt16(0), rows: UInt16(0))
    private var windowKeyObserver: NSObjectProtocol?

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
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        if event.charactersIgnoringModifiers == "v",
           let value = NSPasteboard.general.string(forType: .string) {
            session.write(Data(value.utf8))
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let data = TerminalInput.sequence(for: event) { session.write(data) }
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

        for y in 0..<Int(frame.rows) {
            for x in 0..<Int(frame.cols) {
                let cell = cells[y * Int(frame.cols) + x]
                let rect = NSRect(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight,
                                  width: cellWidth + 0.5, height: cellHeight)
                let background = color(cell.bg_r, cell.bg_g, cell.bg_b)
                background.setFill()
                rect.fill()
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
    }

    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> NSColor {
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
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
