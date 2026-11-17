import Foundation

enum GraphicalViewMode: String, CaseIterable, Identifiable {
    case icons
    case list

    var id: Self { self }

    var title: String {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        }
    }

    var systemImage: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}
