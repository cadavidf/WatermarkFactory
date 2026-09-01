import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WatermarkFactory

/// `CGColor(red:green:blue:alpha:)` builds an untagged/generic-RGB color,
/// which CoreGraphics color-matches (not merely rounds) when composited
/// into an sRGB-tagged context -- pure blue picks up a visible red/green
/// tint after that conversion. Every synthetic test color goes through
/// this instead so pixel-exact assertions test the watermark logic, not a
/// colorspace mismatch in the test fixtures.
private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1).cgColor
}

private struct RGB: Equatable, CustomStringConvertible {
    let r: Int, g: Int, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    var description: String { "(\(r), \(g), \(b))" }
}

final class ImageProcessorMetadataTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPreservesGPSAndScrubsOtherMetadata() throws {
        let source = tempDir.appendingPathComponent("source.tiff")
        let output = tempDir.appendingPathComponent("output.tiff")
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLatitude: 40.7128,
            kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSLongitude: 74.0060,
            kCGImagePropertyGPSAltitude: 12.5,
            kCGImagePropertyGPSTimeStamp: "12:34:56"
        ]
        try writeImage(source, type: .tiff, properties: [
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Private Camera",
                kCGImagePropertyTIFFSoftware: "ChatGPT"
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCopyrightNotice: "private"]
        ])

        try export(source, to: output, format: .tiff)
        let properties = try imageProperties(output)

        XCTAssertEqual(properties.object(forKey: kCGImagePropertyGPSDictionary) as? NSDictionary, gps as NSDictionary)
        let tiff = properties.object(forKey: kCGImagePropertyTIFFDictionary) as? NSDictionary
        XCTAssertEqual(tiff?.object(forKey: kCGImagePropertyTIFFSoftware) as? String, "automality.com")
        XCTAssertNil(tiff?.object(forKey: kCGImagePropertyTIFFMake))
        let iptc = properties.object(forKey: kCGImagePropertyIPTCDictionary) as? NSDictionary
        XCTAssertEqual(creatorValue(in: iptc), "automality.com")
        XCTAssertNil(iptc?.object(forKey: kCGImagePropertyIPTCCopyrightNotice))
    }

    func testMetadataPrivacyRemoveLocationDropsGPSEntirely() throws {
        let source = tempDir.appendingPathComponent("source.tiff")
        let output = tempDir.appendingPathComponent("output.tiff")
        try writeImage(source, type: .tiff, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLatitude: 40.7128,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSLongitude: 74.0060
            ]
        ])

        try export(source, to: output, format: .tiff, metadataPrivacy: .removeLocation)
        let properties = try imageProperties(output)

        XCTAssertNil(properties.object(forKey: kCGImagePropertyGPSDictionary), "removeLocation must drop the GPS dictionary entirely, not just blank fields inside it")
    }

    func testMetadataPrivacyReducedPrecisionRoundsCoordinatesButKeepsOtherGPSFields() throws {
        let source = tempDir.appendingPathComponent("source.tiff")
        let output = tempDir.appendingPathComponent("output.tiff")
        try writeImage(source, type: .tiff, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLatitude: 40.712834591,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSLongitude: 74.006012345,
                kCGImagePropertyGPSAltitude: 12.5
            ]
        ])

        try export(source, to: output, format: .tiff, metadataPrivacy: .reducedPrecision)
        let properties = try imageProperties(output)
        let gps = properties.object(forKey: kCGImagePropertyGPSDictionary) as? NSDictionary

        // Rounded to 2 decimal degrees (~1.1km) -- close enough to place
        // a neighborhood, not an exact address.
        XCTAssertEqual(gps?.object(forKey: kCGImagePropertyGPSLatitude) as? Double ?? 0, 40.71, accuracy: 0.0001)
        XCTAssertEqual(gps?.object(forKey: kCGImagePropertyGPSLongitude) as? Double ?? 0, 74.01, accuracy: 0.0001)
        // Original full-precision values must not survive anywhere in the output.
        XCTAssertNotEqual(gps?.object(forKey: kCGImagePropertyGPSLatitude) as? Double, 40.712834591)
        // Non-coordinate GPS fields pass through unchanged -- this is
        // about location precision specifically, not stripping everything.
        XCTAssertEqual(gps?.object(forKey: kCGImagePropertyGPSAltitude) as? Double, 12.5)
        XCTAssertEqual(gps?.object(forKey: kCGImagePropertyGPSLatitudeRef) as? String, "N")
    }

    func testMetadataPrivacyKeepOriginalPrecisionIsTheDefaultAndPreservesExactCoordinates() throws {
        let source = tempDir.appendingPathComponent("source.tiff")
        let output = tempDir.appendingPathComponent("output.tiff")
        try writeImage(source, type: .tiff, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLatitude: 40.712834591
            ]
        ])

        // No metadataPrivacy argument -- exercises WatermarkSettings' own
        // default (.keepOriginalPrecision), the same default used for any
        // settings saved before this option existed, so old presets don't
        // silently start stripping GPS they were previously relying on.
        try export(source, to: output, format: .tiff)
        let properties = try imageProperties(output)
        let gps = properties.object(forKey: kCGImagePropertyGPSDictionary) as? NSDictionary

        // GPS coordinates round-trip through TIFF's rational (numerator/
        // denominator) encoding, not raw doubles -- confirmed live this
        // produces ~1e-6 degree rounding (40.712834591 -> 40.712833333...),
        // a normal, expected artifact of that format, not data loss this
        // code introduces. accuracy here is set to what real GPS EXIF
        // storage actually delivers, not an idealized exact match.
        XCTAssertEqual(gps?.object(forKey: kCGImagePropertyGPSLatitude) as? Double ?? 0, 40.712834591, accuracy: 0.00001)
    }

    func testNoGPSSourceProducesNoGPSBlock() throws {
        let source = tempDir.appendingPathComponent("source.png")
        let output = tempDir.appendingPathComponent("output.png")
        try writeImage(source, type: .png, properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGComment: "private"]])

        try export(source, to: output, format: .png)
        let properties = try imageProperties(output)

        XCTAssertNil(properties.object(forKey: kCGImagePropertyGPSDictionary))
    }

    func testMalformedExifDoesNotAbortExport() throws {
        let source = tempDir.appendingPathComponent("source.jpg")
        let output = tempDir.appendingPathComponent("output.jpg")
        try writeImage(source, type: .jpeg)
        try insertMalformedExif(into: source)

        XCTAssertNoThrow(try export(source, to: output, format: .jpeg))
        XCTAssertNotNil(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    }

    func testAIProvenanceMarkerIsRemoved() throws {
        let source = tempDir.appendingPathComponent("source.png")
        let output = tempDir.appendingPathComponent("output.png")
        try writeImage(source, type: .png, properties: [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGSoftware: "C2PA Content Credentials ChatGPT",
                kCGImagePropertyPNGDescription: "DALL-E provenance marker"
            ]
        ])

        try export(source, to: output, format: .png)

        XCTAssertFalse(String(describing: try imageProperties(output)).localizedCaseInsensitiveContains("c2pa"))
        XCTAssertFalse(String(describing: try imageProperties(output)).localizedCaseInsensitiveContains("chatgpt"))
        XCTAssertFalse(String(describing: try imageProperties(output)).localizedCaseInsensitiveContains("dall-e"))
    }

    func testAttributionIsWrittenForSupportedSourceFormats() throws {
        for (type, ext, format) in [(UTType.jpeg, "jpg", ExportFormat.jpeg), (.png, "png", .png), (.tiff, "tiff", .tiff)] {
            let source = tempDir.appendingPathComponent("source.\(ext)")
            let output = tempDir.appendingPathComponent("output.\(ext)")
            try writeImage(source, type: type)

            try export(source, to: output, format: format)
            let properties = try imageProperties(output)
            let iptc = properties.object(forKey: kCGImagePropertyIPTCDictionary) as? NSDictionary

            XCTAssertEqual(creatorValue(in: iptc), "automality.com")
            if type == .png {
                let png = properties.object(forKey: kCGImagePropertyPNGDictionary) as? NSDictionary
                XCTAssertEqual(png?.object(forKey: kCGImagePropertyPNGSoftware) as? String, "automality.com")
            }
            if type == .tiff {
                let tiff = properties.object(forKey: kCGImagePropertyTIFFDictionary) as? NSDictionary
                XCTAssertEqual(tiff?.object(forKey: kCGImagePropertyTIFFSoftware) as? String, "automality.com")
            }
            if type == .jpeg {
                // Regression test: CGImageDestination silently drops the
                // TIFF dictionary entirely for JPEG written from a bare
                // CGImage (confirmed via a standalone properties dump,
                // not assumed) -- IPTC alone isn't the whole story for
                // the single most common export format, so also assert
                // the EXIF UserComment carrier added specifically to
                // cover that gap.
                let exif = properties.object(forKey: kCGImagePropertyExifDictionary) as? NSDictionary
                XCTAssertEqual(exif?.object(forKey: kCGImagePropertyExifUserComment) as? String, "automality.com")
            }
        }
    }

    /// The watermark fully covers a same-size canvas (sizeFraction 1.0,
    /// centered, no padding), so a corner pixel of the composed result maps
    /// to the watermark's background corner and the center pixel maps to
    /// its non-background subject -- deterministic regardless of any
    /// vertical flip in the drawing pipeline.
    func testRemoveWatermarkBackgroundStripsFlatBackgroundButKeepsSubject() throws {
        let source = tempDir.appendingPathComponent("source.png")
        let watermark = tempDir.appendingPathComponent("watermark.png")
        try writeImage(source, type: .png, width: 80, height: 80, properties: [:], color: srgb(0, 0, 1))
        try writeBorderedWatermark(watermark, size: 40, border: srgb(1, 0, 0), subject: srgb(0, 1, 0))

        var settings = WatermarkSettings(sizeFraction: 1.0, opacity: 1.0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: .png, jpegQuality: 0.9, outputPrefix: "", outputSuffix: "")
        settings.removeWatermarkBackground = true
        let image = try ImageProcessor.watermarkedImage(sourceURL: source, watermarkURL: watermark, settings: settings)

        let corner = try pixel(image, x: 0, y: 0)
        XCTAssertEqual(corner, RGB(0, 0, 255), "background should be stripped, letting the blue source show through")
        let center = try pixel(image, x: 40, y: 40)
        XCTAssertEqual(center, RGB(0, 255, 0), "the watermark's actual subject should survive untouched")
    }

    /// Corners that don't agree on a color aren't a flat background -- a
    /// photographic or already-complex watermark should be left untouched
    /// rather than guessed at.
    func testRemoveWatermarkBackgroundLeavesDisagreeingCornersUntouched() throws {
        let source = tempDir.appendingPathComponent("source.png")
        let watermark = tempDir.appendingPathComponent("watermark.png")
        try writeImage(source, type: .png, width: 20, height: 20, properties: [:], color: srgb(0, 0, 1))
        try writeQuadrantWatermark(watermark, size: 20)

        var settings = WatermarkSettings(sizeFraction: 1.0, opacity: 1.0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: .png, jpegQuality: 0.9, outputPrefix: "", outputSuffix: "")
        settings.removeWatermarkBackground = true
        let image = try ImageProcessor.watermarkedImage(sourceURL: source, watermarkURL: watermark, settings: settings)

        // Every quadrant color should still be opaque somewhere -- nothing
        // was stripped since the four corners disagree.
        let corner = try pixel(image, x: 0, y: 0)
        XCTAssertNotEqual(corner, RGB(0, 0, 255), "a disagreeing-corners watermark should not have been touched, so its own color should still show, not the source's")
    }

    private func writeBorderedWatermark(_ url: URL, size: Int, border: CGColor, subject: CGColor) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessorError.contextFailed
        }
        context.setShouldAntialias(false)
        context.setFillColor(border)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let inset = size / 4
        context.setFillColor(subject)
        context.fill(CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2))
        guard let image = context.makeImage() else { throw ImageProcessorError.contextFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("Could not create image destination"); return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    /// Four different quadrant colors -- corners deliberately disagree.
    private func writeQuadrantWatermark(_ url: URL, size: Int) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessorError.contextFailed
        }
        let half = size / 2
        let quadrants: [(CGRect, CGColor)] = [
            // None of these is the source's blue -- avoids a coincidental
            // match if a quadrant happens to land under a corner sample
            // (CGRect fills bottom-up in drawing space, while the raw
            // buffer read is top-down, so which quadrant lands at buffer
            // (0,0) isn't the one that's visually top-left).
            (CGRect(x: 0, y: 0, width: half, height: half), srgb(1, 0, 0)),
            (CGRect(x: half, y: 0, width: half, height: half), srgb(0, 1, 0)),
            (CGRect(x: 0, y: half, width: half, height: half), srgb(1, 0.5, 0)),
            (CGRect(x: half, y: half, width: half, height: half), srgb(1, 1, 0))
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }
        guard let image = context.makeImage() else { throw ImageProcessorError.contextFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("Could not create image destination"); return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    /// Reads one pixel's RGB (0-255) from a CGImage via a raw bitmap
    /// context, mirroring the low-level access pattern ImageProcessor
    /// itself uses for background removal / luminance sampling.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGB {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw ImageProcessorError.contextFailed }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessorError.contextFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return RGB(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func testExactOutputSizeUsesRequestedPlatformPixels() throws {
        let source = tempDir.appendingPathComponent("source.jpg")
        let output = tempDir.appendingPathComponent("output.jpg")
        let watermark = tempDir.appendingPathComponent("watermark.png")
        try writeImage(source, type: .jpeg, width: 80, height: 40)
        try writeImage(watermark, type: .png)

        let settings = WatermarkSettings(sizeFraction: 0.2, opacity: 0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: .jpeg, jpegQuality: 0.85, outputWidth: 1200, outputHeight: 1200, outputPrefix: "", outputSuffix: "")
        _ = try ImageProcessor.export(sourceURL: source, watermarkURL: watermark, outputURL: output, settings: settings)

        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 1200)
    }

    func testExportsSingleFrameGIF() throws {
        let source = tempDir.appendingPathComponent("source.jpg")
        let output = tempDir.appendingPathComponent("output.gif")
        let watermark = tempDir.appendingPathComponent("watermark.png")
        try writeImage(source, type: .jpeg, width: 16, height: 16)
        try writeImage(watermark, type: .png, width: 4, height: 4)

        _ = try ImageProcessor.export(sourceURL: source, watermarkURL: watermark, outputURL: output, settings: WatermarkSettings(sizeFraction: 0.2, opacity: 0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: .gif, jpegQuality: 0.9, outputPrefix: "", outputSuffix: ""))

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.gif.identifier)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
    }

    func testCroppedImageUsesFractionalRectAndFailsOpen() throws {
        let image = try makeImage(width: 10, height: 8)
        let cropped = ImageProcessor.croppedImage(image, cropRect: CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.5))

        XCTAssertEqual(cropped.width, 5)
        XCTAssertEqual(cropped.height, 4)
        XCTAssertTrue(ImageProcessor.croppedImage(image, cropRect: .zero) === image)
    }

    func testOutputFilenameInsertsOrderAfterPrefix() {
        let source = tempDir.appendingPathComponent("beach.jpg")
        let settings = WatermarkSettings(sizeFraction: 0.2, opacity: 0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: .jpeg, jpegQuality: 0.9, outputPrefix: "wm_", outputSuffix: "")

        XCTAssertEqual(ImageProcessor.outputFilename(for: source, settings: settings, order: 3, numberedCount: 12), "wm_03_beach.jpg")
        XCTAssertEqual(ImageProcessor.outputFilename(for: source, settings: settings, numberedCount: 12), "wm_beach.jpg")
    }

    func testSmartPlacementMarginAndOpticalOffset() {
        XCTAssertEqual(ImageProcessor.safeMargin(for: CGSize(width: 1000, height: 800)), 32)
        XCTAssertEqual(ImageProcessor.opticalYOffset(for: CGSize(width: 1000, height: 800), anchor: .center), 40)
        XCTAssertEqual(ImageProcessor.opticalYOffset(for: CGSize(width: 1000, height: 800), anchor: .topRight), 0)
    }

    func testSmartPlacementTintRecommendation() {
        XCTAssertEqual(ImageProcessor.recommendedTint(sourceLuminance: 0.2, watermarkLuminance: 0.2), .light)
        XCTAssertEqual(ImageProcessor.recommendedTint(sourceLuminance: 0.8, watermarkLuminance: 0.9), .dark)
        XCTAssertEqual(ImageProcessor.recommendedTint(sourceLuminance: 0.8, watermarkLuminance: 0.2), .original)
    }

    func testSmartPlacementSamplesAverageLuminance() throws {
        let dark = try makeImage(width: 4, height: 4, color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let light = try makeImage(width: 4, height: 4, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        XCTAssertLessThan(ImageProcessor.averageLuminance(in: dark, rect: CGRect(x: 0, y: 0, width: 4, height: 4)), 0.01)
        XCTAssertGreaterThan(ImageProcessor.averageLuminance(in: light, rect: CGRect(x: 0, y: 0, width: 4, height: 4)), 0.99)
    }

    func testSmartPlacementPicksLeastSalientAnchorAndKeepsCurrentTie() {
        let settings = WatermarkSettings(sizeFraction: 0.2, opacity: 1, anchor: .topRight, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: .jpeg, jpegQuality: 0.9, outputPrefix: "", outputSuffix: "")
        let sourceSize = CGSize(width: 1000, height: 1000)
        let watermarkSize = CGSize(width: 100, height: 100)

        XCTAssertEqual(
            ImageProcessor.preferredAnchor(sourceSize: sourceSize, watermarkSize: watermarkSize, settings: settings, padding: 0, saliencyRect: CGRect(x: 800, y: 800, width: 200, height: 200)),
            .topLeft
        )
        XCTAssertEqual(
            ImageProcessor.preferredAnchor(sourceSize: sourceSize, watermarkSize: watermarkSize, settings: settings, padding: 0, saliencyRect: nil),
            .topRight
        )
    }

    func testSecurityScopedAccessStartIsIdempotent() {
        let url = URL(fileURLWithPath: "/fake/image.jpg")
        var started: [URL] = []
        var stopped: [URL] = []
        let tracker = SecurityScopedAccessTracker(
            startAccess: { started.append($0); return true },
            stopAccess: { stopped.append($0) }
        )

        tracker.start(url)
        tracker.start(url)

        XCTAssertEqual(started, [url])
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(tracker.active, [url])
    }

    func testSecurityScopedAccessStopMissingIsNoOp() {
        let url = URL(fileURLWithPath: "/fake/image.jpg")
        var stopped: [URL] = []
        let tracker = SecurityScopedAccessTracker(
            startAccess: { _ in true },
            stopAccess: { stopped.append($0) }
        )

        tracker.stop(url)

        XCTAssertTrue(stopped.isEmpty)
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testSecurityScopedAccessReplaceStopsRemovedURLsOnly() {
        let kept = URL(fileURLWithPath: "/fake/kept.jpg")
        let removed = URL(fileURLWithPath: "/fake/removed.jpg")
        let added = URL(fileURLWithPath: "/fake/added.jpg")
        var started: [URL] = []
        var stopped: [URL] = []
        let tracker = SecurityScopedAccessTracker(
            startAccess: { started.append($0); return true },
            stopAccess: { stopped.append($0) }
        )

        tracker.replace(with: [kept, removed])
        tracker.replace(with: [kept, added])

        XCTAssertEqual(Set(started), [kept, removed, added])
        XCTAssertEqual(stopped, [removed])
        XCTAssertEqual(tracker.active, [kept, added])
    }

    @MainActor
    func testOpenedURLInputPrefersFolderOtherwiseUsesFiles() {
        let folder = URL(fileURLWithPath: "/fake/photos", isDirectory: true)
        let first = URL(fileURLWithPath: "/fake/a.jpg")
        let second = URL(fileURLWithPath: "/fake/b.png")

        XCTAssertEqual(AppState.openedURLInput(from: [first, folder, second], isDirectory: { $0 == folder }), .folder(folder))
        XCTAssertEqual(AppState.openedURLInput(from: [first, second], isDirectory: { _ in false }), .images([first, second]))
        XCTAssertNil(AppState.openedURLInput(from: [], isDirectory: { _ in false }))
    }

    private func export(_ source: URL, to output: URL, format: ExportFormat, metadataPrivacy: MetadataPrivacyLevel = .keepOriginalPrecision) throws {
        let watermark = tempDir.appendingPathComponent("watermark.png")
        try writeImage(watermark, type: .png)
        _ = try ImageProcessor.export(sourceURL: source, watermarkURL: watermark, outputURL: output, settings: WatermarkSettings(sizeFraction: 0.2, opacity: 0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: format, jpegQuality: 0.9, outputPrefix: "", outputSuffix: "", metadataPrivacy: metadataPrivacy))
    }

    private func writeImage(_ url: URL, type: UTType, width: Int = 4, height: Int = 4, properties: [CFString: Any] = [:], color: CGColor? = nil) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            XCTFail("Could not create image destination")
            return
        }
        let image = try makeImage(width: width, height: height, color: color ?? CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try makeImage(width: width, height: height, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    }

    private func makeImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessorError.contextFailed
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ImageProcessorError.contextFailed }
        return image
    }

    private func imageProperties(_ url: URL) throws -> NSDictionary {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
            XCTFail("Could not read image properties")
            return [:]
        }
        return properties
    }

    private func creatorValue(in iptc: NSDictionary?) -> String? {
        let value = iptc?.object(forKey: kCGImagePropertyIPTCByline)
        return (value as? [String])?.first ?? value as? String
    }

    private func insertMalformedExif(into url: URL) throws {
        var data = try Data(contentsOf: url)
        let app1 = Data([0xFF, 0xE1, 0x00, 0x0D]) + Data("Exif\0\0badexif".utf8)
        data.insert(contentsOf: app1, at: jpegMetadataInsertionIndex(in: data))
        try data.write(to: url)
    }

    private func jpegMetadataInsertionIndex(in data: Data) -> Int {
        var index = 2
        while index + 4 < data.count, data[index] == 0xFF {
            let marker = data[index + 1]
            if marker == 0xDA || marker == 0xDB { break }
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            index += 2 + length
        }
        return index
    }
}
