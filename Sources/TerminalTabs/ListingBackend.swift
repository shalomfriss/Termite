import Foundation

enum ListingBackend: String, CaseIterable, Identifiable, Sendable {
    case eza
    case lstr

    var id: Self { self }

    var title: String {
        switch self {
        case .eza: "eza"
        case .lstr: "lstr"
        }
    }

    var detail: String {
        switch self {
        case .eza: "Compact grid and long-list output"
        case .lstr: "Minimal directory tree output"
        }
    }
}
