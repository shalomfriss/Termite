import AppKit

enum GraphicalFileIcon {
    static let pixelSize = 32
    @MainActor private static var cache: [GraphicalFileItem.Kind: Data] = [:]

    @MainActor
    static func pixels(for kind: GraphicalFileItem.Kind) -> Data {
        if let cached = cache[kind] { return cached }
        let data = kind == .directory ? directoryPixels() : symbolPixels(for: kind)
        cache[kind] = data
        return data
    }

    @MainActor
    private static func directoryPixels() -> Data {
        // Load PNG directly via CGDataProvider to avoid NSImage's coordinate-system flip,
        // which would cause renderCGImage's own flip to double-invert the image.
        guard let url = Bundle.module.url(forResource: "FolderIcon", withExtension: "png"),
              let provider = CGDataProvider(url: url as CFURL),
              let source = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return symbolPixels(for: .directory)
        }
        return renderCGImage(source)
    }

    @MainActor
    private static func symbolPixels(for kind: GraphicalFileItem.Kind) -> Data {
        let descriptor = descriptor(for: kind)
        let configuration = NSImage.SymbolConfiguration(pointSize: 23, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: descriptor.color))
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
        return renderCGImage(source, inset: 3)
    }

    private static func renderCGImage(_ source: CGImage, inset: CGFloat = 0) -> Data {
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
            if inset > 0 {
                context.setShadow(
                    offset: CGSize(width: 0, height: 1.5),
                    blur: 3,
                    color: NSColor.black.withAlphaComponent(0.32).cgColor
                )
            }
            let rect = CGRect(x: inset, y: inset,
                              width: CGFloat(pixelSize) - inset * 2,
                              height: CGFloat(pixelSize) - inset * 2)
            context.draw(source, in: rect)
        }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0, alpha < 255 else { continue }
            pixels[offset]     = UInt8(min(255, Int(pixels[offset])     * 255 / alpha))
            pixels[offset + 1] = UInt8(min(255, Int(pixels[offset + 1]) * 255 / alpha))
            pixels[offset + 2] = UInt8(min(255, Int(pixels[offset + 2]) * 255 / alpha))
        }
        return Data(pixels)
    }

    @MainActor
    private static func descriptor(
        for kind: GraphicalFileItem.Kind
    ) -> (symbol: String, color: NSColor, accessibilityDescription: String) {
        switch kind {
        case .directory:
            ("folder.fill", NSColor(srgbRed: 0.96, green: 0.70, blue: 0.18, alpha: 1), "Folder")
        case .file:
            ("doc.fill", NSColor(srgbRed: 0.73, green: 0.80, blue: 0.84, alpha: 1), "File")
        case .executable:
            ("terminal.fill", NSColor(srgbRed: 0.48, green: 0.86, blue: 0.64, alpha: 1), "Executable")
        case .symbolicLink:
            ("link", NSColor(srgbRed: 0.49, green: 0.69, blue: 0.91, alpha: 1), "Symbolic link")
        }
    }
}
