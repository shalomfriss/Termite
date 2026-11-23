import AppKit

struct MarkdownBlockStyle {
    let font: NSFont
    let foregroundColor: NSColor
    let paragraphStyle: NSParagraphStyle
    let prefix: String
    let isCodeBlock: Bool
    let isTableCell: Bool
}
