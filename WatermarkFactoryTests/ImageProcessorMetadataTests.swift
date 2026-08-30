import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WatermarkFactory

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
        }
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

    private func export(_ source: URL, to output: URL, format: ExportFormat) throws {
        let watermark = tempDir.appendingPathComponent("watermark.png")
        try writeImage(watermark, type: .png)
        _ = try ImageProcessor.export(sourceURL: source, watermarkURL: watermark, outputURL: output, settings: WatermarkSettings(sizeFraction: 0.2, opacity: 0, anchor: .center, offsetX: 0, offsetY: 0, layoutMode: .single, padding: 0, spacing: 0, rotationPattern: .none, customAngle: 0, exportFormat: format, jpegQuality: 0.9, outputPrefix: "", outputSuffix: ""))
    }

    private func writeImage(_ url: URL, type: UTType, width: Int = 4, height: Int = 4, properties: [CFString: Any] = [:]) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            XCTFail("Could not create image destination")
            return
        }
        CGImageDestinationAddImage(destination, try makeImage(width: width, height: height), properties as CFDictionary)
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
