import AppKit
import SwiftUI

struct HighlightedTextView: NSViewRepresentable {
    @Binding var source: String
    let highlightsSyntax: Bool
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(source: $source, highlightsSyntax: highlightsSyntax)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.usesFindBar = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        coordinator.source = $source
        let styleChanged = coordinator.highlightsSyntax != highlightsSyntax
        coordinator.highlightsSyntax = highlightsSyntax
        textView.isEditable = isEditable

        if textView.string != source {
            coordinator.replaceText(in: textView, with: source)
        } else if styleChanged {
            coordinator.applyHighlighting(to: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: Binding<String>
        var highlightsSyntax: Bool

        private var isApplyingProgrammaticChange = false
        private var highlightingWorkItem: DispatchWorkItem?

        init(source: Binding<String>, highlightsSyntax: Bool) {
            self.source = source
            self.highlightsSyntax = highlightsSyntax
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange,
                  let textView = notification.object as? NSTextView else { return }

            let editedSource = textView.string
            if source.wrappedValue != editedSource {
                source.wrappedValue = editedSource
            }
            scheduleHighlighting(for: textView)
        }

        func replaceText(in textView: NSTextView, with replacement: String) {
            highlightingWorkItem?.cancel()
            isApplyingProgrammaticChange = true
            textView.textStorage?.setAttributedString(
                CodeSyntaxHighlighter.attributedString(
                    for: replacement,
                    highlightsSyntax: highlightsSyntax
                )
            )
            textView.setSelectedRange(NSRange(location: replacement.utf16.count, length: 0))
            isApplyingProgrammaticChange = false
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !textView.hasMarkedText() else {
                scheduleHighlighting(for: textView)
                return
            }

            let currentSource = textView.string
            let highlightedSource = CodeSyntaxHighlighter.attributedString(
                for: currentSource,
                highlightsSyntax: highlightsSyntax
            )
            guard let textStorage = textView.textStorage,
                  textStorage.length == highlightedSource.length else { return }

            isApplyingProgrammaticChange = true
            textStorage.beginEditing()
            highlightedSource.enumerateAttributes(
                in: NSRange(location: 0, length: highlightedSource.length)
            ) { attributes, range, _ in
                textStorage.setAttributes(attributes, range: range)
            }
            textStorage.endEditing()
            isApplyingProgrammaticChange = false
        }

        private func scheduleHighlighting(for textView: NSTextView) {
            highlightingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlighting(to: textView)
            }
            highlightingWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(140),
                execute: workItem
            )
        }
    }
}
