import XCTest
@testable import WatermarkFactory

final class WatermarkIntensityPresetTests: XCTestCase {
    func testSixStepsOrderedBySizeAndOpacity() {
        let cases = WatermarkIntensityPreset.allCases
        XCTAssertEqual(cases.count, 6)
        for (a, b) in zip(cases, cases.dropFirst()) {
            XCTAssertLessThan(a.sizeFraction, b.sizeFraction)
            XCTAssertLessThan(a.opacity, b.opacity)
        }
    }

    func testDiscreteIsBarelyOpaqueAndProtectiveIsFullyOpaque() {
        // Discrete lowered from an earlier 0.20; Protective raised from an
        // earlier 0.95 -- both per explicit feedback that Discrete should
        // read as less opaque and Protective as maximally hard to remove.
        XCTAssertLessThanOrEqual(WatermarkIntensityPreset.discrete.opacity, 0.15)
        XCTAssertEqual(WatermarkIntensityPreset.protective.opacity, 1.0, accuracy: 0.0001)
    }

    func testLayoutStyleProgressesFromSingleToTiledRotated() {
        XCTAssertEqual(WatermarkIntensityPreset.discrete.layoutStyle, .single)
        XCTAssertEqual(WatermarkIntensityPreset.protective.layoutStyle, .tiledRotated)
        // Only protective and bold reach tiled; only confident and
        // protective involve rotation -- not every step needs to touch
        // every corner of the layout axis.
        XCTAssertEqual(WatermarkIntensityPreset.bold.layoutMode, .tiled)
        XCTAssertEqual(WatermarkIntensityPreset.confident.rotationPattern, .diagonal)
    }

    func testLayoutStyleMapsCorrectlyToRealSettings() {
        XCTAssertEqual(WatermarkLayoutStyle.single.layoutMode, .single)
        XCTAssertEqual(WatermarkLayoutStyle.single.rotationPattern, .none)
        XCTAssertEqual(WatermarkLayoutStyle.singleRotated.layoutMode, .single)
        XCTAssertEqual(WatermarkLayoutStyle.singleRotated.rotationPattern, .diagonal)
        XCTAssertEqual(WatermarkLayoutStyle.tiled.layoutMode, .tiled)
        XCTAssertEqual(WatermarkLayoutStyle.tiled.rotationPattern, .none)
        XCTAssertEqual(WatermarkLayoutStyle.tiledRotated.layoutMode, .tiled)
        XCTAssertEqual(WatermarkLayoutStyle.tiledRotated.rotationPattern, .diagonal)
    }

    func testLayoutStyleClosestRoundTripsForAllFourCombinations() {
        for style in WatermarkLayoutStyle.allCases {
            let closest = WatermarkLayoutStyle.closest(to: style.layoutMode, rotationPattern: style.rotationPattern)
            XCTAssertEqual(closest, style)
        }
        // A rotation pattern the matrix doesn't represent (.custom) still
        // resolves to the nearest real stop rather than crashing/nil.
        XCTAssertEqual(WatermarkLayoutStyle.closest(to: .single, rotationPattern: .custom), .singleRotated)
        XCTAssertEqual(WatermarkLayoutStyle.closest(to: .single, rotationPattern: .alternating), .singleRotated)
    }

    func testNearestFindsClosestPresetBySizeAndLayout() {
        let nearDiscrete = WatermarkIntensityPreset.nearest(sizeFraction: 0.09, layoutStyle: .single)
        XCTAssertEqual(nearDiscrete, .discrete)

        let nearProtective = WatermarkIntensityPreset.nearest(sizeFraction: 0.58, layoutStyle: .tiledRotated)
        XCTAssertEqual(nearProtective, .protective)
    }

    func testDefaultIsSubtleTheResearchedProfessionalRange() {
        // 10-15% of canvas width is the professional-branding sweet spot;
        // Subtle (13%) is meant to be the app's default starting point.
        XCTAssertEqual(WatermarkIntensityPreset.subtle.sizeFraction, 0.13, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(WatermarkIntensityPreset.subtle.sizeFraction, 0.10)
        XCTAssertLessThanOrEqual(WatermarkIntensityPreset.subtle.sizeFraction, 0.15)
    }

    func testSizeRangeCoversAllNamedPresets() {
        for preset in WatermarkIntensityPreset.allCases {
            XCTAssertTrue(WatermarkIntensityPreset.sizeRange.contains(preset.sizeFraction), "\(preset) sizeFraction out of the matrix's own size range")
        }
    }

    func testBundledAutomalityWatermarkResourceExists() {
        XCTAssertNotNil(AppState.demoWatermarkURL, "automality-watermark.png must be bundled as a plain resource for the demo preview to work")
    }
}
