import AppKit
import Foundation

@MainActor
enum CodeSyntaxHighlighter {
    private static let baseColor = NSColor(
        calibratedRed: 0.82,
        green: 0.88,
        blue: 0.92,
        alpha: 1
    )
    private static let keywordColor = NSColor(
        calibratedRed: 0.79,
        green: 0.57,
        blue: 0.98,
        alpha: 1
    )
    private static let typeColor = NSColor(
        calibratedRed: 0.32,
        green: 0.84,
        blue: 0.88,
        alpha: 1
    )
    private static let numberColor = NSColor(
        calibratedRed: 0.96,
        green: 0.68,
        blue: 0.42,
        alpha: 1
    )
    private static let stringColor = NSColor(
        calibratedRed: 0.63,
        green: 0.84,
        blue: 0.52,
        alpha: 1
    )
    private static let commentColor = NSColor(
        calibratedRed: 0.43,
        green: 0.58,
        blue: 0.63,
        alpha: 1
    )

    private static let keywordExpression = expression(
        #"\b(actor|async|await|break|case|catch|class|const|continue|default|defer|do|else|enum|export|extends|fallthrough|false|final|finally|for|from|func|function|guard|if|implements|import|in|init|interface|internal|let|match|mut|nil|null|override|package|private|protocol|public|repeat|return|self|static|struct|super|switch|throw|throws|trait|true|try|typealias|var|where|while|yield)\b"#
    )
    private static let typeExpression = expression(
        #"\b(Any|Array|Bool|Boolean|Character|Data|Dictionary|Double|Error|Float|Int|Int32|Int64|Never|Number|Object|Result|Set|String|UInt|UInt32|UInt64|URL|UUID|Void)\b"#
    )
    private static let numberExpression = expression(
        #"\b(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
    )
    private static let functionExpression = expression(
        #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#
    )
    private static let protectedExpression = expression(
        #"(?s:(/\*.*?\*/))|(?m:(//[^\n]*$))|(?m:(#[^\n]*$))|(?m:(--[^\n]*$))|(\"(?:\\.|[^\"\\])*\")|('(?:\\.|[^'\\])*')|(`(?:\\.|[^`\\])*`)"#
    )

    static func attributedString(
        for source: String,
        highlightsSyntax: Bool
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.defaultTabInterval = 4 * font.maximumAdvancement.width
        paragraphStyle.lineSpacing = 1

        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        guard highlightsSyntax, !source.isEmpty else { return result }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let protectedMatches = protectedExpression.matches(
            in: source,
            range: fullRange
        )
        let protectedRanges = protectedMatches.map(\.range)

        apply(
            keywordExpression,
            color: keywordColor,
            to: result,
            source: source,
            protectedRanges: protectedRanges
        )
        apply(
            typeExpression,
            color: typeColor,
            to: result,
            source: source,
            protectedRanges: protectedRanges
        )
        apply(
            numberExpression,
            color: numberColor,
            to: result,
            source: source,
            protectedRanges: protectedRanges
        )
        apply(
            functionExpression,
            color: typeColor,
            to: result,
            source: source,
            protectedRanges: protectedRanges
        )

        let commentFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for match in protectedMatches {
            let isComment = (1...4).contains { match.range(at: $0).location != NSNotFound }
            result.addAttribute(
                .foregroundColor,
                value: isComment ? commentColor : stringColor,
                range: match.range
            )
            if isComment {
                result.addAttribute(.font, value: commentFont, range: match.range)
            }
        }
        return result
    }

    private static func apply(
        _ expression: NSRegularExpression,
        color: NSColor,
        to result: NSMutableAttributedString,
        source: String,
        protectedRanges: [NSRange]
    ) {
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in expression.matches(in: source, range: fullRange)
        where !intersectsProtectedRange(match.range, protectedRanges: protectedRanges) {
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func intersectsProtectedRange(
        _ candidate: NSRange,
        protectedRanges: [NSRange]
    ) -> Bool {
        var lowerBound = 0
        var upperBound = protectedRanges.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if NSMaxRange(protectedRanges[middle]) <= candidate.location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard protectedRanges.indices.contains(lowerBound) else { return false }
        return protectedRanges[lowerBound].location < NSMaxRange(candidate)
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
