import XCTest
@testable import WatermarkFactory

final class IntentParserTests: XCTestCase {
    func testDecodesWellFormedModelOutput() throws {
        let json = """
        {"anchor":"bottomRight","sizeFraction":0.18,"opacity":0.5,"tint":"Original","exportPlatform":"instagram","renamePrefix":"wm_","needsClarification":[],"assistantReply":"I'll use a subtle corner watermark."}
        """

        let slots = try IntentParser.decodeSlots(from: json)

        XCTAssertEqual(slots.anchor, "bottomRight")
        XCTAssertEqual(slots.sizeFraction, 0.18)
        XCTAssertEqual(slots.opacity, 0.5)
        XCTAssertEqual(slots.tint, "Original")
        XCTAssertEqual(slots.exportPlatform, "instagram")
        XCTAssertEqual(slots.renamePrefix, "wm_")
        XCTAssertTrue(slots.needsClarification.isEmpty)
    }

    func testMalformedModelOutputThrows() {
        XCTAssertThrowsError(try IntentParser.decodeSlots(from: "Here is your JSON: nope"))
    }

    func testPresetApplicationUsesCornerSubtleDefaults() {
        let slots = IntentSlots(anchor: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, renamePrefix: nil, needsClarification: [], assistantReply: "")
        let settings = IntentPreset.settings(from: slots, message: "just watermark these")

        XCTAssertEqual(settings.layoutMode, .single)
        XCTAssertEqual(settings.anchor, .bottomRight)
        XCTAssertEqual(settings.sizeFraction, 0.18)
        XCTAssertEqual(settings.opacity, 0.5)
        XCTAssertEqual(settings.watermarkTint, .original)
    }

    func testPresetApplicationHandlesTiledAndPlatformSlots() {
        let slots = IntentSlots(anchor: "tiled", sizeFraction: 0.7, opacity: -1, tint: "Dark", exportPlatform: "print", renamePrefix: "set/1", needsClarification: [], assistantReply: "")
        let settings = IntentPreset.settings(from: slots, message: "tiled brand for print")

        XCTAssertEqual(settings.layoutMode, .tiled)
        XCTAssertEqual(settings.rotationPattern, .diagonal)
        XCTAssertEqual(settings.spacing, 80)
        XCTAssertEqual(settings.sizeFraction, 0.6)
        XCTAssertEqual(settings.opacity, 0)
        XCTAssertEqual(settings.watermarkTint, .dark)
        XCTAssertEqual(settings.exportFormat, .tiff)
        XCTAssertEqual(settings.maxFileSizeKB, 0)
        XCTAssertEqual(settings.outputPrefix, "set1")
    }
}
