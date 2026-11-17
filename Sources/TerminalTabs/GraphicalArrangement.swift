import Foundation

enum GraphicalSortOption: String, CaseIterable, Identifiable, Sendable {
    case name
    case kind
    case dateLastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .dateLastOpened: "Date Last Opened"
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        case .tags: "Tags"
        }
    }
}

enum GraphicalGroupOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case name
    case kind
    case dateLastOpened
    case dateAdded
    case dateModified
    case dateCreated
    case size
    case tags

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .name: "Name"
        case .kind: "Kind"
        case .dateLastOpened: "Date Last Opened"
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        case .tags: "Tags"
        }
    }

    var sortOption: GraphicalSortOption? {
        switch self {
        case .none: nil
        case .name: .name
        case .kind: .kind
        case .dateLastOpened: .dateLastOpened
        case .dateAdded: .dateAdded
        case .dateModified: .dateModified
        case .dateCreated: .dateCreated
        case .size: .size
        case .tags: .tags
        }
    }
}

enum GraphicalSortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

struct GraphicalItemSection: Equatable, Sendable {
    let title: String?
    let items: [GraphicalFileItem]
}
