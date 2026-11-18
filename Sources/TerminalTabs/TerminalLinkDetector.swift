import Foundation

enum TerminalLinkDetector {
    struct Match: Equatable {
        let url: URL
        let columns: Range<Int>
    }

    private struct CellSegment {
        let column: Int
        let utf16Range: NSRange
    }

    private static let prefixes = ["https://", "http://", "www."]
    private static let terminatingCharacters = CharacterSet(charactersIn: "\"'<>`{}|\\^")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")

    static func links(in cells: [String]) -> [Match] {
        let row = rowTextAndSegments(for: cells)
        guard !row.text.isEmpty else { return [] }

        var matches: [Match] = []
        var searchStart = row.text.startIndex
        while searchStart < row.text.endIndex,
              let prefixRange = nextPrefixRange(in: row.text, startingAt: searchStart) {
            var candidateEnd = prefixRange.upperBound
            while candidateEnd < row.text.endIndex {
                let character = row.text[candidateEnd]
                guard !character.isWhitespace, !isTerminating(character) else { break }
                candidateEnd = row.text.index(after: candidateEnd)
            }

            candidateEnd = trimmedEnd(
                in: row.text,
                from: prefixRange.lowerBound,
                to: candidateEnd
            )
            let candidateRange = prefixRange.lowerBound..<candidateEnd
            if let match = match(
                for: candidateRange,
                in: row.text,
                segments: row.segments
            ) {
                matches.append(match)
            }

            searchStart = candidateEnd > prefixRange.lowerBound
                ? candidateEnd
                : row.text.index(after: prefixRange.lowerBound)
        }
        return matches
    }

    private static func rowTextAndSegments(
        for cells: [String]
    ) -> (text: String, segments: [CellSegment]) {
        var text = ""
        var segments: [CellSegment] = []
        var utf16Location = 0
        for (column, cell) in cells.enumerated() {
            let renderedCell = cell.isEmpty ? " " : cell
            let utf16Length = renderedCell.utf16.count
            text.append(renderedCell)
            segments.append(CellSegment(
                column: column,
                utf16Range: NSRange(location: utf16Location, length: utf16Length)
            ))
            utf16Location += utf16Length
        }
        return (text, segments)
    }

    private static func nextPrefixRange(
        in text: String,
        startingAt searchStart: String.Index
    ) -> Range<String.Index>? {
        prefixes.compactMap { prefix in
            text.range(
                of: prefix,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
            )
        }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func trimmedEnd(
        in text: String,
        from start: String.Index,
        to untrimmedEnd: String.Index
    ) -> String.Index {
        var end = untrimmedEnd
        while end > start {
            let lastIndex = text.index(before: end)
            let character = text[lastIndex]
            if isTrailingPunctuation(character)
                || isUnbalancedClosingDelimiter(character, in: text[start..<end]) {
                end = lastIndex
            } else {
                break
            }
        }
        return end
    }

    private static func match(
        for range: Range<String.Index>,
        in text: String,
        segments: [CellSegment]
    ) -> Match? {
        guard !range.isEmpty else { return nil }
        let displayedValue = String(text[range])
        let urlValue = displayedValue.lowercased().hasPrefix("www.")
            ? "https://\(displayedValue)"
            : displayedValue
        guard let components = URLComponents(string: urlValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else { return nil }

        let utf16Range = NSRange(range, in: text)
        let coveredColumns = segments.compactMap { segment in
            NSIntersectionRange(utf16Range, segment.utf16Range).length > 0
                ? segment.column
                : nil
        }
        guard let firstColumn = coveredColumns.first,
              let lastColumn = coveredColumns.last else { return nil }
        return Match(url: url, columns: firstColumn..<(lastColumn + 1))
    }

    private static func isTerminating(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            terminatingCharacters.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(trailingPunctuation.contains)
    }

    private static func isUnbalancedClosingDelimiter(
        _ character: Character,
        in candidate: Substring
    ) -> Bool {
        let delimiters: [(closing: Character, opening: Character)] = [
            (")", "("), ("]", "["),
        ]
        guard let delimiter = delimiters.first(where: { $0.closing == character }) else {
            return false
        }
        return candidate.count(where: { $0 == delimiter.closing })
            > candidate.count(where: { $0 == delimiter.opening })
    }
}
