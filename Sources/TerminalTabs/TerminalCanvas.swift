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
        view.session = session
        view.openDirectoryInNewTab = openDirectoryInNewTab
        view.needsDisplay = true
    }
}

final class TerminalNSView: NSView,
    @MainActor QLPreviewPanelDataSource,
    @MainActor QLPreviewPanelDelegate {
    private struct BlockContents {
        let command: String
        let output: String
        let workingDirectory: String
    }

    private struct ImageHitTarget: Equatable {
        let placementID: UInt32
        let rect: NSRect
    }

    var session: TerminalSession
    var openDirectoryInNewTab: (URL) -> Void
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    private let italicFont: NSFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat = 20
    private var lastGrid = (cols: UInt16(0), rows: UInt16(0))
    private var windowKeyObserver: NSObjectProtocol?
    private var contextBlock: BlockContents?
    private var contextGraphicalItem: GraphicalFileItem?
    private var selectedBlockHistoryRow: UInt64?
    private var selectedGraphicalPlacementID: UInt32?
    private var imageHitTargets: [ImageHitTarget] = []
    private var imageCache: [UInt32: CGImage] = [:]
    private var folderBloomCache: [UInt32: CGImage] = [:]
    private var selectionGlowCache: [String: CGImage] = [:]
    private var quickLookURL: URL?
    private var sharingPicker: NSSharingServicePicker?
    private let ciContext = CIContext(options: [.cacheIntermediates: true])

    init(
        session: TerminalSession,
        openDirectoryInNewTab: @escaping (URL) -> Void = { _ in }
    ) {
        self.session = session
        self.openDirectoryInNewTab = openDirectoryInNewTab
        let descriptor = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontDescriptor
            .withSymbolicTraits(.italic)
        italicFont = NSFont(descriptor: descriptor, size: 14) ?? font
        cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.024, green: 0.067, blue: 0.094, alpha: 1).cgColor
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

    override func layout() {
        super.layout()
        let cols = UInt16(max(1, min(Int(UInt16.max), Int((bounds.width - 20) / cellWidth))))
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
        if let target = imageHitTargets.last(where: { $0.rect.contains(point) }),
           let item = session.graphicalItem(for: target.placementID) {
            selectedBlockHistoryRow = nil
            selectedGraphicalPlacementID = target.placementID
            needsDisplay = true
            if event.clickCount >= 2 {
                session.activateGraphicalItem(item)
            }
            return
        }
        selectedGraphicalPlacementID = nil
        selectBlock(at: Int(point.y / cellHeight))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for target in imageHitTargets {
            addCursorRect(target.rect, cursor: .pointingHand)
        }
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
        if let target = imageHitTargets.last(where: { $0.rect.contains(point) }),
           let item = session.graphicalItem(for: target.placementID) {
            selectedBlockHistoryRow = nil
            selectedGraphicalPlacementID = target.placementID
            needsDisplay = true
            contextBlock = nil
            return graphicalItemMenu(for: item)
        }

        contextGraphicalItem = nil
        contextBlock = blockContents(at: Int(point.y / cellHeight))

        let menu = NSMenu()
        menu.addItem(menuItem("Copy Output", action: #selector(copyOutput), enabled: contextBlock != nil))
        menu.addItem(menuItem("Copy Command", action: #selector(copyCommand), enabled: contextBlock != nil))
        menu.addItem(menuItem("Copy Working Directory", action: #selector(copyWorkingDirectory), enabled: contextBlock != nil))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Attach Output to AI Chat",
            action: #selector(attachOutputToAI),
            enabled: contextBlock != nil || session.canAttachGraphicalOutputToAI
        ))
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
        context?.setFillColor(NSColor(red: 0.024, green: 0.067, blue: 0.094, alpha: 1).cgColor)
        context?.fill(bounds)

        let ranges = blockRanges(frame: frame, cells: cells)
        let rowOffsets = Array(repeating: CGFloat.zero, count: Int(frame.rows))
        let blockFill = NSColor(red: 0.035, green: 0.094, blue: 0.122, alpha: 1)
        let blockSeparator = NSColor(red: 0.20, green: 0.55, blue: 0.62, alpha: 0.20)
        let selectedFill = NSColor(red: 0.050, green: 0.135, blue: 0.165, alpha: 1)
        let selectedSeparator = NSColor(red: 0.32, green: 0.84, blue: 0.88, alpha: 0.34)
        for range in ranges {
            let rect = Self.blockBackgroundRect(
                for: range,
                cellHeight: cellHeight,
                width: bounds.width
            )
            let isSelected = frame.scroll_offset + UInt64(range.lowerBound) == selectedBlockHistoryRow
            (isSelected ? selectedFill : blockFill).setFill()
            rect.fill()
            (isSelected ? selectedSeparator : blockSeparator).setFill()
            NSRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1).fill()
        }

        for y in 0..<Int(frame.rows) {
            let isInBlock = ranges.contains { $0.contains(y) }
            for x in 0..<Int(frame.cols) {
                let cell = cells[y * Int(frame.cols) + x]
                let rect = NSRect(x: CGFloat(x) * cellWidth + 10,
                                  y: CGFloat(y) * cellHeight + rowOffsets[y],
                                  width: cellWidth + 0.5, height: cellHeight)
                let hasDefaultBackground = cell.bg_r == 6 && cell.bg_g == 17 && cell.bg_b == 24
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

        // Images must be composited after terminal cell backgrounds. A freshly
        // navigated directory is not always part of a semantic command block,
        // so drawing images first lets the normal background pass cover them.
        drawImages(frame, rowOffsets: rowOffsets)

        if frame.cursor_visible {
            let cursorRow = Int(frame.cursor_y)
            let cursorOffset = rowOffsets.indices.contains(cursorRow) ? rowOffsets[cursorRow] : 0
            let cursor = NSRect(x: CGFloat(frame.cursor_x) * cellWidth + 10,
                                y: CGFloat(frame.cursor_y) * cellHeight + cursorOffset,
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

    static func blockBackgroundRect(
        for range: Range<Int>,
        cellHeight: CGFloat,
        width: CGFloat
    ) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(range.lowerBound) * cellHeight,
            width: width,
            height: CGFloat(range.count) * cellHeight
        )
    }

    private func drawImages(_ frame: GTFrame, rowOffsets: [CGFloat]) {
        let previousTargets = imageHitTargets
        var nextTargets: [ImageHitTarget] = []
        guard let images = frame.images, frame.image_count > 0 else {
            imageHitTargets = []
            selectedGraphicalPlacementID = nil
            invalidateCursorRectsIfChanged(from: previousTargets)
            return
        }
        for index in 0..<Int(frame.image_count) {
            let placement = images[index]
            guard let cgImage = cachedImage(for: placement) else { continue }
            let displayedImage = folderBloomImage(for: placement, baseImage: cgImage) ?? cgImage
            let placementRow = Int(placement.viewport_row)
            let rowOffset = rowOffsets.indices.contains(placementRow) ? rowOffsets[placementRow] : 0

            let rect = NSRect(
                x: CGFloat(placement.viewport_col) * cellWidth
                    + CGFloat(placement.cell_offset_x)
                    + 10,
                y: CGFloat(placement.viewport_row) * cellHeight
                    + CGFloat(placement.cell_offset_y)
                    + rowOffset,
                width: CGFloat(placement.pixel_width),
                height: CGFloat(placement.pixel_height)
            )
            if placement.placement_id != 0 {
                let layout = session.graphicalItemHitLayout(for: placement.placement_id)
                let tileStartX = max(0, rect.minX - cellWidth * CGFloat(layout.0))
                let tileRect = NSRect(
                    x: tileStartX,
                    y: rect.minY,
                    width: min(cellWidth * CGFloat(layout.1), bounds.maxX - tileStartX),
                    height: cellHeight * CGFloat(layout.2)
                )
                if selectedGraphicalPlacementID == placement.placement_id {
                    drawGraphicalSelection(in: tileRect)
                }
                nextTargets.append(.init(placementID: placement.placement_id, rect: tileRect))
            }
            NSImage(cgImage: displayedImage, size: rect.size).draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
        imageHitTargets = nextTargets
        if let selectedGraphicalPlacementID,
           !nextTargets.contains(where: { $0.placementID == selectedGraphicalPlacementID }) {
            self.selectedGraphicalPlacementID = nil
        }
        invalidateCursorRectsIfChanged(from: previousTargets)
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

        let turquoise = NSColor(srgbRed: 0.38, green: 0.96, blue: 0.90, alpha: 0.92)
        turquoise.setStroke()
        let border = NSBezierPath(
            roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5.5,
            yRadius: 5.5
        )
        border.lineWidth = 1
        border.stroke()
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
        filter.setValue(2.2, forKey: kCIInputRadiusKey)
        filter.setValue(0.72, forKey: kCIInputIntensityKey)
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

    @objc private func openGraphicalItem() {
        guard let contextGraphicalItem else { return }
        session.activateGraphicalItem(contextGraphicalItem)
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
                _ = try await NSWorkspace.shared.duplicate([source])
                self?.session.showCurrentDirectoryGraphically()
            } catch {
                self?.presentOperationError(error)
            }
        }
    }

    @objc private func quickLookGraphicalItem() {
        guard let contextGraphicalItem else { return }
        quickLookURL = URL(fileURLWithPath: contextGraphicalItem.path)
        focusTerminal()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
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
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: item.path)],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
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
        if let block = contextBlock {
            session.attachToAI(
                command: block.command,
                output: session.fullOutput(for: block.command) ?? block.output,
                workingDirectory: block.workingDirectory
            )
        } else {
            session.attachGraphicalOutputToAI()
        }
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
