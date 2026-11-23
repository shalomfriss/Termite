import Foundation

enum MarkdownPreviewFileDetector {
    private static let extensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn",
    ]

    static func isMarkdownFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
