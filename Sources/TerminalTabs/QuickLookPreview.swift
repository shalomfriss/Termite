import QuickLookUI
import SwiftUI

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return container
        }
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        preview.previewItem = url as NSURL
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = Self.previewView(in: view),
              preview.previewItem?.previewItemURL != url else { return }
        preview.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        previewView(in: view)?.close()
    }

    private static func previewView(in container: NSView) -> QLPreviewView? {
        container.subviews.first { $0 is QLPreviewView } as? QLPreviewView
    }
}
