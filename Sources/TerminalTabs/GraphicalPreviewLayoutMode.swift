import Foundation

enum GraphicalPreviewLayoutMode: String, CaseIterable, Identifiable {
    case resizeContent
    case overlay

    var id: Self { self }

    var title: String {
        switch self {
        case .resizeContent:
            "Resize file view"
        case .overlay:
            "Overlay file view"
        }
    }

    var detail: String {
        switch self {
        case .resizeContent:
            "Keeps the file view visible by making room for the preview."
        case .overlay:
            "Shows the preview above the file view without resizing it."
        }
    }
}
