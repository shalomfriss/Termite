import Foundation

struct RepositoryContext: Equatable, Sendable {
    enum RuntimeKind: String, CaseIterable, Hashable, Sendable {
        case node
        case python

        var title: String {
            switch self {
            case .node: "Node"
            case .python: "Python"
            }
        }

        var systemImage: String {
            switch self {
            case .node: "shippingbox"
            case .python: "chevron.left.forwardslash.chevron.right"
            }
        }

        var verificationCommand: String {
            switch self {
            case .node: "node --version"
            case .python: "python --version 2>&1 || python3 --version"
            }
        }
    }

    struct RuntimeInstallation: Identifiable, Equatable, Sendable {
        let version: String
        let binPath: String
        let source: String
        let isProjectLocal: Bool

        var id: String { binPath }
    }

    struct Runtime: Identifiable, Equatable, Sendable {
        let kind: RuntimeKind
        let declaredVersion: String?
        let declarationSource: String
        let installations: [RuntimeInstallation]

        var id: RuntimeKind { kind }
    }

    let rootPath: String
    let displayName: String
    let node: Runtime?
    let python: Runtime?

    var runtimes: [Runtime] {
        [node, python].compactMap(\.self)
    }
}
