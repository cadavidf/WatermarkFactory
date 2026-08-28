import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageProcessorError: Error {
    case loadFailed
    case contextFailed
    case encodeFailed
}

struct ImageProcessor {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]
    private static let webMaxPixelSize = 2048

    static func thumbnail(for url: URL, maxPixelSize: CGFloat = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    static func imageSize(for url: URL) -> CGSize? {
        guard let image = loadCGImage(url) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    static func watermarkFrame(sourceSize: CGSize, watermarkSize: CGSize, settings: WatermarkSettings) -> CGRect {
        let targetLongestSide = min(sourceSize.width, sourceSize.height) * settings.sizeFraction
        let scale = targetLongestSide / max(watermarkSize.width, watermarkSize.height)
        return rect(for: CGSize(width: watermarkSize.width * scale, height: watermarkSize.height * scale), canvas: sourceSize, anchor: settings.anchor, padding: settings.padding, offsetX: settings.offsetX, offsetY: settings.offsetY)
    }

    static func clampedWatermarkOffsets(sourceSize: CGSize, watermarkSize: CGSize, settings: WatermarkSettings, offsetX: Double, offsetY: Double) -> (x: Double, y: Double) {
        var proposed = settings
        proposed.offsetX = offsetX
        proposed.offsetY = offsetY
        let frame = watermarkFrame(sourceSize: sourceSize, watermarkSize: watermarkSize, settings: proposed)
        let visible = CGFloat(0.2)
        let x = min(max(frame.minX, -frame.width * (1 - visible)), sourceSize.width - frame.width * visible)
        let y = min(max(frame.minY, -frame.height * (1 - visible)), sourceSize.height - frame.height * visible)
        let base = rect(for: frame.size, canvas: sourceSize, anchor: settings.anchor, padding: settings.padding, offsetX: 0, offsetY: 0)
        return (Double(x - base.minX), Double(base.minY - y))
    }

    static func watermarkedImage(sourceURL: URL, watermarkURL: URL, settings: WatermarkSettings) throws -> CGImage {
        guard let source = loadCGImage(sourceURL), let watermark = loadCGImage(watermarkURL) else {
            throw ImageProcessorError.loadFailed
        }
        return try compose(source: source, watermark: watermark, settings: settings, destinationFormat: settings.exportFormat)
    }

    static func encodedWatermarkData(sourceURL: URL, watermarkURL: URL, settings: WatermarkSettings) throws -> Data {
        let image = try watermarkedImage(sourceURL: sourceURL, watermarkURL: watermarkURL, settings: settings)
        let outputImage = try optimizeForWebIfNeeded(image, settings: settings)
        return try encode(image: outputImage, sourceURL: sourceURL, format: settings.exportFormat, quality: jpegQuality(sourceURL: sourceURL, settings: settings)).data
    }

    static func outputFilename(for sourceURL: URL, settings: WatermarkSettings) -> String {
        "\(sanitize(settings.outputPrefix))\(sourceURL.deletingPathExtension().lastPathComponent)\(sanitize(settings.outputSuffix)).\(resolvedFormat(sourceURL: sourceURL, format: settings.exportFormat).ext)"
    }

    static func uniqueOutputURL(for sourceURL: URL, outputFolder: URL, settings: WatermarkSettings, usedURLs: inout Set<URL>) -> URL {
        let filename = outputFilename(for: sourceURL, settings: settings)
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = outputFolder.appendingPathComponent(filename)
        var index = 2
        while usedURLs.contains(candidate) {
            candidate = outputFolder.appendingPathComponent("\(base) (\(index))").appendingPathExtension(ext)
            index += 1
        }
        usedURLs.insert(candidate)
        return candidate
    }

    static func export(sourceURL: URL, watermarkURL: URL, outputURL: URL, settings: WatermarkSettings) throws -> (url: URL, bytes: Int, usedHEICFallback: Bool) {
        let image = try watermarkedImage(sourceURL: sourceURL, watermarkURL: watermarkURL, settings: settings)
        let outputImage = try optimizeForWebIfNeeded(image, settings: settings)
        let encoded = try encode(image: outputImage, sourceURL: sourceURL, format: settings.exportFormat, quality: jpegQuality(sourceURL: sourceURL, settings: settings))
        try encoded.data.write(to: outputURL, options: .atomic)
        return (outputURL, encoded.data.count, encoded.usedHEICFallback)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "\0", with: "")
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    private static func compose(source: CGImage, watermark: CGImage, settings: WatermarkSettings, destinationFormat: ExportFormat) throws -> CGImage {
        let width = source.width
        let height = source.height
        let alphaInfo: CGImageAlphaInfo = destinationFormat == .jpeg ? .noneSkipLast : .premultipliedLast
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: alphaInfo.rawValue) else {
            throw ImageProcessorError.contextFailed
        }

        if destinationFormat == .jpeg {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(settings.opacity)

        let targetLongestSide = min(CGFloat(width), CGFloat(height)) * settings.sizeFraction
        let scale = targetLongestSide / max(CGFloat(watermark.width), CGFloat(watermark.height))
        let watermarkSize = CGSize(width: CGFloat(watermark.width) * scale, height: CGFloat(watermark.height) * scale)

        switch settings.layoutMode {
        case .single:
            context.draw(watermark, in: rect(for: watermarkSize, canvas: CGSize(width: width, height: height), anchor: settings.anchor, padding: settings.padding, offsetX: settings.offsetX, offsetY: settings.offsetY))
        case .tiled:
            drawTiles(context: context, watermark: watermark, canvas: CGSize(width: width, height: height), size: watermarkSize, settings: settings)
        }

        guard let image = context.makeImage() else { throw ImageProcessorError.contextFailed }
        return image
    }

    private static func rect(for size: CGSize, canvas: CGSize, anchor: Anchor, padding: Double, offsetX: Double, offsetY: Double) -> CGRect {
        var x: CGFloat
        var y: CGFloat
        let padding = CGFloat(padding)
        switch anchor {
        case .topLeft, .left, .bottomLeft: x = padding
        case .top, .center, .bottom: x = (canvas.width - size.width) / 2
        case .topRight, .right, .bottomRight: x = canvas.width - size.width - padding
        }
        switch anchor {
        case .bottomLeft, .bottom, .bottomRight: y = padding
        case .left, .center, .right: y = (canvas.height - size.height) / 2
        case .topLeft, .top, .topRight: y = canvas.height - size.height - padding
        }
        return CGRect(x: x + offsetX, y: y - offsetY, width: size.width, height: size.height)
    }

    private static func drawTiles(context: CGContext, watermark: CGImage, canvas: CGSize, size: CGSize, settings: WatermarkSettings) {
        let padding = CGFloat(settings.padding)
        let cellSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let stepX = max(1, cellSize.width + settings.spacing)
        let stepY = max(1, cellSize.height + settings.spacing)
        var row = 0
        var y = -cellSize.height
        while y < canvas.height + cellSize.height {
            let angle: CGFloat
            switch settings.rotationPattern {
            case .none: angle = 0
            case .diagonal: angle = 45
            case .alternating: angle = row.isMultiple(of: 2) ? 0 : 45
            case .custom: angle = settings.customAngle
            }
            var x = -cellSize.width
            while x < canvas.width + cellSize.width {
                context.saveGState()
                context.translateBy(x: x + padding + size.width / 2, y: y + padding + size.height / 2)
                context.rotate(by: angle * .pi / 180)
                context.draw(watermark, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
                context.restoreGState()
                x += stepX
            }
            row += 1
            y += stepY
        }
    }

    private static func encode(image: CGImage, sourceURL: URL, format: ExportFormat, quality: Double) throws -> (data: Data, ext: String, usedHEICFallback: Bool) {
        let resolved = resolvedFormat(sourceURL: sourceURL, format: format)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, resolved.type.identifier as CFString, 1, nil) else {
            throw ImageProcessorError.encodeFailed
        }
        var properties = scrubbedMetadata(sourceURL: sourceURL)
        if resolved.type == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessorError.encodeFailed }
        return (data as Data, resolved.ext, resolved.fallback)
    }

    private static func scrubbedMetadata(sourceURL: URL) -> [CFString: Any] {
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFSoftware: "automality.com",
                kCGImagePropertyTIFFArtist: "automality.com"
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: "automality.com"],
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGSoftware: "automality.com",
                kCGImagePropertyPNGAuthor: "automality.com"
            ]
        ]
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let gps = sourceProperties.object(forKey: kCGImagePropertyGPSDictionary) else {
            return properties
        }
        properties[kCGImagePropertyGPSDictionary] = gps
        return properties
    }

    private static func optimizeForWebIfNeeded(_ image: CGImage, settings: WatermarkSettings) throws -> CGImage {
        guard settings.optimizeForWeb else { return image }
        let longest = max(image.width, image.height)
        guard longest > webMaxPixelSize else { return image }
        let scale = CGFloat(webMaxPixelSize) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessorError.contextFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw ImageProcessorError.contextFailed }
        return resized
    }

    private static func jpegQuality(sourceURL: URL, settings: WatermarkSettings) -> Double {
        guard settings.optimizeForWeb, resolvedFormat(sourceURL: sourceURL, format: settings.exportFormat).type == .jpeg else {
            return settings.jpegQuality
        }
        return min(settings.jpegQuality, 0.8)
    }

    private static func resolvedFormat(sourceURL: URL, format: ExportFormat) -> (type: UTType, ext: String, fallback: Bool) {
        let sourceExt = sourceURL.pathExtension.lowercased()
        switch format {
        case .jpeg: return (.jpeg, "jpg", false)
        case .png: return (.png, "png", false)
        case .tiff: return (.tiff, "tiff", false)
        case .keepOriginal:
            switch sourceExt {
            case "jpg", "jpeg": return (.jpeg, sourceExt, false)
            case "png": return (.png, "png", false)
            case "tif", "tiff": return (.tiff, sourceExt, false)
            default: return (.png, "png", sourceExt == "heic")
            }
        }
    }
}
