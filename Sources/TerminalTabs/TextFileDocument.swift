import Foundation

struct TextFileDocument: Sendable {
    static let maximumByteCount = 4 * 1_024 * 1_024

    let text: String
    let encoding: String.Encoding

    nonisolated static func load(from url: URL) throws -> TextFileDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumByteCount {
            throw CocoaError(.fileReadTooLarge)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumByteCount else {
            throw CocoaError(.fileReadTooLarge)
        }

        for encoding in supportedEncodings {
            if let decoded = String(data: data, encoding: encoding) {
                return TextFileDocument(text: decoded, encoding: encoding)
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    nonisolated func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }

    nonisolated private static let supportedEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .isoLatin1,
    ]
}
