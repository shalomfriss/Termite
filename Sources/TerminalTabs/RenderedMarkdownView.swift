import AppKit
import SwiftUI

struct RenderedMarkdownView: NSViewRepresentable {
    let source: String
    let baseURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(
                calibratedRed: 0.32,
                green: 0.84,
                blue: 0.88,
                alpha: 1
            ),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        scrollView.documentView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.source != source || coordinator.baseURL != baseURL else { return }
        coordinator.source = source
        coordinator.baseURL = baseURL
        do {
            textView.textStorage?.setAttributedString(
                try MarkdownRenderer.attributedString(for: source, baseURL: baseURL)
            )
        } catch {
            textView.string = "Markdown preview unavailable: \(error.localizedDescription)"
        }
    }

    final class Coordinator {
        var source: String?
        var baseURL: URL?
    }
}
