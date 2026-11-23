import AppKit
import Foundation

@MainActor
enum MarkdownRenderer {
    private static let presentationIntentKey = NSAttributedString.Key("NSPresentationIntent")
    private static let inlinePresentationIntentKey = NSAttributedString.Key(
        "NSInlinePresentationIntent"
    )
    private static let listItemDelimiterKey = NSAttributedString.Key("NSListItemDelimiter")

    private static let textColor = NSColor(
        calibratedRed: 0.82,
        green: 0.88,
        blue: 0.92,
        alpha: 1
    )
    private static let mutedTextColor = NSColor(
        calibratedRed: 0.50,
        green: 0.65,
        blue: 0.71,
        alpha: 1
    )
    private static let accentColor = NSColor(
        calibratedRed: 0.32,
        green: 0.84,
        blue: 0.88,
        alpha: 1
    )
    private static let codeBackgroundColor = NSColor(
        calibratedRed: 0.047,
        green: 0.125,
        blue: 0.153,
        alpha: 1
    )

    static func attributedString(
        for source: String,
        baseURL: URL
    ) throws -> NSAttributedString {
        let parsed = try NSAttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            ),
            baseURL: baseURL
        )
        guard parsed.length > 0 else { return NSAttributedString() }

        let result = NSMutableAttributedString()
        let fullRange = NSRange(location: 0, length: parsed.length)
        var previousTableRowIdentity: Int?

        parsed.enumerateAttribute(
            presentationIntentKey,
            in: fullRange
        ) { value, range, _ in
            guard let intent = value as? PresentationIntent else { return }
            let block = NSMutableAttributedString(
                attributedString: parsed.attributedSubstring(from: range)
            )
            let style = blockStyle(for: intent)
            applyBlockStyle(style, to: block)
            applyInlineStyles(to: block, baseFont: style.font)
            removeMarkdownMetadata(from: block)

            if style.isTableCell {
                let rowIdentity = tableRowIdentity(in: intent)
                if !result.string.isEmpty {
                    result.append(
                        NSAttributedString(
                            string: rowIdentity == previousTableRowIdentity ? "\t" : "\n"
                        )
                    )
                }
                previousTableRowIdentity = rowIdentity
            } else {
                if !result.string.isEmpty { result.append(NSAttributedString(string: "\n")) }
                previousTableRowIdentity = nil
            }

            if !style.prefix.isEmpty {
                result.append(
                    NSAttributedString(
                        string: style.prefix,
                        attributes: [
                            .font: style.font,
                            .foregroundColor: style.foregroundColor,
                            .paragraphStyle: style.paragraphStyle,
                        ]
                    )
                )
            }
            result.append(block)
        }

        return result
    }

    private static func blockStyle(for intent: PresentationIntent) -> MarkdownBlockStyle {
        let kinds = intent.components.map(\.kind)
        let listDepth = kinds.reduce(into: 0) { count, kind in
            switch kind {
            case .orderedList, .unorderedList:
                count += 1
            default:
                break
            }
        }
        let indent = CGFloat(max(0, listDepth - 1)) * 18
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 7
        paragraphStyle.headIndent = indent
        paragraphStyle.firstLineHeadIndent = indent

        var font = NSFont.systemFont(ofSize: 13)
        var foregroundColor = textColor
        var prefix = ""
        var isTableCell = false

        for kind in kinds {
            switch kind {
            case let .header(level):
                let size: CGFloat = switch level {
                case 1: 24
                case 2: 20
                case 3: 17
                case 4: 15
                default: 13
                }
                font = NSFont.systemFont(
                    ofSize: size,
                    weight: level <= 2 ? .bold : .semibold
                )
                paragraphStyle.paragraphSpacing = level <= 2 ? 11 : 8
            case let .listItem(ordinal):
                prefix = kinds.contains { kind in
                    if case .orderedList = kind { return true }
                    return false
                } ? "\(ordinal). " : "• "
                paragraphStyle.headIndent = indent + 18
                paragraphStyle.firstLineHeadIndent = indent
                paragraphStyle.paragraphSpacing = 3
            case .codeBlock:
                font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                paragraphStyle.headIndent = 10
                paragraphStyle.firstLineHeadIndent = 10
                paragraphStyle.tailIndent = -10
                paragraphStyle.paragraphSpacing = 9
            case .blockQuote:
                prefix = "│ "
                foregroundColor = mutedTextColor
                paragraphStyle.headIndent = 16
                paragraphStyle.firstLineHeadIndent = 0
            case .thematicBreak:
                prefix = "────────────────────────"
                foregroundColor = mutedTextColor
            case .tableCell:
                isTableCell = true
                paragraphStyle.defaultTabInterval = 120
                paragraphStyle.paragraphSpacing = 4
            default:
                break
            }
        }

        return MarkdownBlockStyle(
            font: font,
            foregroundColor: foregroundColor,
            paragraphStyle: paragraphStyle,
            prefix: prefix,
            isCodeBlock: kinds.contains { kind in
                if case .codeBlock = kind { return true }
                return false
            },
            isTableCell: isTableCell
        )
    }

    private static func applyBlockStyle(
        _ style: MarkdownBlockStyle,
        to block: NSMutableAttributedString
    ) {
        let range = NSRange(location: 0, length: block.length)
        block.addAttributes(
            [
                .font: style.font,
                .foregroundColor: style.foregroundColor,
                .paragraphStyle: style.paragraphStyle,
            ],
            range: range
        )
        if style.isCodeBlock {
            block.addAttribute(
                .backgroundColor,
                value: codeBackgroundColor,
                range: range
            )
        }
        block.enumerateAttribute(.link, in: range) { value, linkRange, _ in
            guard value != nil else { return }
            block.addAttributes(
                [
                    .foregroundColor: accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: linkRange
            )
        }
    }

    private static func applyInlineStyles(
        to block: NSMutableAttributedString,
        baseFont: NSFont
    ) {
        let range = NSRange(location: 0, length: block.length)
        block.enumerateAttribute(
            inlinePresentationIntentKey,
            in: range
        ) { value, inlineRange, _ in
            guard let number = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: number.uintValue)
            var font = baseFont
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(
                    ofSize: max(11, baseFont.pointSize - 1),
                    weight: .regular
                )
                block.addAttribute(
                    .backgroundColor,
                    value: codeBackgroundColor,
                    range: inlineRange
                )
            }
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.strikethrough) {
                block.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: inlineRange
                )
            }
            block.addAttribute(.font, value: font, range: inlineRange)
        }
    }

    private static func removeMarkdownMetadata(from block: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: block.length)
        block.removeAttribute(presentationIntentKey, range: range)
        block.removeAttribute(inlinePresentationIntentKey, range: range)
        block.removeAttribute(listItemDelimiterKey, range: range)
    }

    private static func tableRowIdentity(in intent: PresentationIntent) -> Int? {
        intent.components.first { component in
            switch component.kind {
            case .tableHeaderRow, .tableRow:
                true
            default:
                false
            }
        }?.identity
    }
}
