import AppKit

enum GraphicalFileIcon {
    static let pixelSize = 32
    @MainActor private static var cache: [GraphicalFileItem.Kind: Data] = [:]

    @MainActor
    static func pixels(for kind: GraphicalFileItem.Kind) -> Data {
        if let cached = cache[kind] { return cached }
        let descriptor = descriptor(for: kind)
        let pointConfiguration = NSImage.SymbolConfiguration(
            pointSize: 23,
            weight: .medium
        )
        let colorConfiguration = NSImage.SymbolConfiguration(
            hierarchicalColor: descriptor.color
        )
        let configuration = pointConfiguration.applying(colorConfiguration)
        guard let image = NSImage(
            systemSymbolName: descriptor.symbol,
            accessibilityDescription: descriptor.accessibilityDescription
        )?.withSymbolConfiguration(configuration) else {
            return Data(repeating: 0, count: pixelSize * pixelSize * 4)
        }

        var proposedRect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: [.interpolation: NSImageInterpolation.high]
        ) else {
            return Data(repeating: 0, count: pixelSize * pixelSize * 4)
        }

        var pixels = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: pixelSize,
                    height: pixelSize,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelSize * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                  ) else { return }
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(pixelSize))
            context.scaleBy(x: 1, y: -1)
            context.setShadow(
                offset: CGSize(width: 0, height: 1.5),
                blur: 3,
                color: NSColor.black.withAlphaComponent(0.32).cgColor
            )
            context.draw(source, in: CGRect(x: 3, y: 3, width: 26, height: 26))
        }

        // Core Graphics renders premultiplied RGBA; Kitty graphics expects
        // straight RGBA bytes. Restore the edge colors before transmission.
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0, alpha < 255 else { continue }
            pixels[offset] = UInt8(min(255, Int(pixels[offset]) * 255 / alpha))
            pixels[offset + 1] = UInt8(min(255, Int(pixels[offset + 1]) * 255 / alpha))
            pixels[offset + 2] = UInt8(min(255, Int(pixels[offset + 2]) * 255 / alpha))
        }
        let data = Data(pixels)
        cache[kind] = data
        return data
    }

    @MainActor
    private static func descriptor(
        for kind: GraphicalFileItem.Kind
    ) -> (symbol: String, color: NSColor, accessibilityDescription: String) {
        switch kind {
        case .directory:
            ("folder.fill", NSColor(srgbRed: 0.31, green: 0.86, blue: 0.88, alpha: 1), "Folder")
        case .file:
            ("doc.fill", NSColor(srgbRed: 0.73, green: 0.80, blue: 0.84, alpha: 1), "File")
        case .executable:
            ("terminal.fill", NSColor(srgbRed: 0.48, green: 0.86, blue: 0.64, alpha: 1), "Executable")
        case .symbolicLink:
            ("link", NSColor(srgbRed: 0.49, green: 0.69, blue: 0.91, alpha: 1), "Symbolic link")
        }
    }
}
