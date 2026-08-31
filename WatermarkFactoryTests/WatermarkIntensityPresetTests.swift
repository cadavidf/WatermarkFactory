import XCTest
@testable import WatermarkFactory

final class WatermarkIntensityPresetTests: XCTestCase {
    func testSixStepsOrderedByIntrusiveness() {
        let cases = WatermarkIntensityPreset.allCases
        XCTAssertEqual(cases.count, 6)
        for (a, b) in zip(cases, cases.dropFirst()) {
            XCTAssertLessThan(a.sizeFraction, b.sizeFraction)
            XCTAssertLessThan(a.opacity, b.opacity)
        }
    }

    func testOnlyProtectiveTiles() {
        for preset in WatermarkIntensityPreset.allCases where preset != .protective {
            XCTAssertEqual(preset.layoutMode, .single)
        }
        XCTAssertEqual(WatermarkIntensityPreset.protective.layoutMode, .tiled)
    }

    func testInterpolationAtExactStepsMatchesThatStep() {
        for preset in WatermarkIntensityPreset.allCases {
            let resolved = WatermarkIntensityPreset.interpolated(at: preset.sliderPosition)
            XCTAssertEqual(resolved.sizeFraction, preset.sizeFraction, accuracy: 0.0001)
            XCTAssertEqual(resolved.opacity, preset.opacity, accuracy: 0.0001)
            XCTAssertEqual(resolved.nearestLabel, preset.label)
        }
    }

    func testInterpolationBetweenStepsIsMonotonicAndClamped() {
        let midway = WatermarkIntensityPreset.interpolated(at: 0.5) // between Discrete and Subtle
        XCTAssertGreaterThan(midway.sizeFraction, WatermarkIntensityPreset.discrete.sizeFraction)
        XCTAssertLessThan(midway.sizeFraction, WatermarkIntensityPreset.subtle.sizeFraction)

        let belowRange = WatermarkIntensityPreset.interpolated(at: -3)
        XCTAssertEqual(belowRange.sizeFraction, WatermarkIntensityPreset.discrete.sizeFraction, accuracy: 0.0001)

        let aboveRange = WatermarkIntensityPreset.interpolated(at: 99)
        XCTAssertEqual(aboveRange.sizeFraction, WatermarkIntensityPreset.protective.sizeFraction, accuracy: 0.0001)
    }

    func testDefaultIsSubtleTheResearchedProfessionalRange() {
        // 10-15% of canvas width is the professional-branding sweet spot;
        // Subtle (13%) is meant to be the app's default starting point.
        XCTAssertEqual(WatermarkIntensityPreset.subtle.sizeFraction, 0.13, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(WatermarkIntensityPreset.subtle.sizeFraction, 0.10)
        XCTAssertLessThanOrEqual(WatermarkIntensityPreset.subtle.sizeFraction, 0.15)
    }

    func testBundledAutomalityWatermarkResourceExists() {
        XCTAssertNotNil(AppState.demoWatermarkURL, "automality-watermark.png must be bundled as a plain resource for the demo preview to work")
    }
}
