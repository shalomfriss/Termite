import Foundation

enum GraphicalViewMode: String, CaseIterable, Identifiable {
    case icons
    case list
    case columns

    var id: Self { self }

    var title: String {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        case .columns: "Columns"
        }
    }

    var systemImage: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        }
    }
}
