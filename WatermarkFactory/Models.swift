import Foundation
import SwiftUI

extension CGRect {
    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
}

enum WatermarkSizePreset: String, CaseIterable, Identifiable, Codable {
    case tiny, small, medium, large, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: String(localized: "Tiny (10%)")
        case .small: String(localized: "Small (20%)")
        case .medium: String(localized: "Medium (35%)")
        case .large: String(localized: "Large (50%)")
        case .full: String(localized: "Full (75%)")
        }
    }
    /// Compact clothing-size-style abbreviation for the chip itself — the
    /// full name+percentage still shows in the section's value readout and
    /// as a tooltip, so the chip row can stay a single aligned line.
    var shortLabel: String {
        switch self {
        case .tiny: "XS"
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .full: "XL"
        }
    }
    var value: Double {
        switch self {
        case .tiny: 0.10
        case .small: 0.20
        case .medium: 0.35
        case .large: 0.50
        case .full: 0.75
        }
    }
}

/// The four ways a watermark can actually sit on a photo, ordered by
/// coverage/aggressiveness -- the vertical axis of the intensity matrix
/// below. Single vs tiled is WatermarkSettings.layoutMode; rotated vs not
/// is settings.rotationPattern (.diagonal vs .none) -- this just names the
/// four meaningful combinations of those two existing settings as one
/// discrete axis, rather than introducing new state.
enum WatermarkLayoutStyle: Int, CaseIterable, Identifiable {
    case single, singleRotated, tiled, tiledRotated
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .single: String(localized: "Single")
        case .singleRotated: String(localized: "Single, rotated")
        case .tiled: String(localized: "Tiled")
        case .tiledRotated: String(localized: "Tiled, rotated")
        }
    }

    var layoutMode: LayoutMode {
        (self == .tiled || self == .tiledRotated) ? .tiled : .single
    }

    var rotationPattern: RotationPattern {
        (self == .singleRotated || self == .tiledRotated) ? .diagonal : .none
    }

    static func closest(to layoutMode: LayoutMode, rotationPattern: RotationPattern) -> WatermarkLayoutStyle {
        let rotated = rotationPattern != .none
        switch (layoutMode, rotated) {
        case (.single, false): return .single
        case (.single, true): return .singleRotated
        case (.tiled, false): return .tiled
        case (.tiled, true): return .tiledRotated
        }
    }
}

/// A single named point on the intensity matrix: size + layout style
/// (position on the 2D pad) plus its own opacity, which rides along
/// visibly as the drag handle's own transparency but is independently
/// adjustable -- not locked to position, unlike the size/layout axes.
/// Distinct from WatermarkSizePreset/OpacityPreset, which stay as
/// independent fine-tuning sliders for anyone who wants an exact custom
/// combination; this is the "just tell me how loud" single control most
/// people actually want. Sizing grounded in real market data (10-15% of
/// canvas width is the professional-branding sweet spot, larger coverage
/// is the anti-theft use case) -- see SPEC.md's watermark-intensity
/// section for sources.
enum WatermarkIntensityPreset: String, CaseIterable, Identifiable, Codable {
    case discrete, subtle, balanced, confident, bold, protective
    var id: String { rawValue }

    var label: String {
        switch self {
        case .discrete: String(localized: "Discrete")
        case .subtle: String(localized: "Subtle")
        case .balanced: String(localized: "Balanced")
        case .confident: String(localized: "Confident")
        case .bold: String(localized: "Bold")
        case .protective: String(localized: "Protective")
        }
    }

    /// One line explaining what each step is actually for, shown under the
    /// matrix -- "intrusiveness" alone doesn't tell you when you'd want
    /// which end.
    var purpose: String {
        switch self {
        case .discrete: String(localized: "Barely there — for polished work you're proud to have made, not worried about.")
        case .subtle: String(localized: "The professional default — visible on inspection, invisible at a glance.")
        case .balanced: String(localized: "Noticeable without dominating the photo.")
        case .confident: String(localized: "Clearly branded — good for social posts and previews.")
        case .bold: String(localized: "Hard to ignore — makes ownership unmistakable.")
        case .protective: String(localized: "Large, solid, tiled — resists cropping or cloning out. For proofs and preview-only shares.")
        }
    }

    var sizeFraction: Double {
        switch self {
        case .discrete: 0.08
        case .subtle: 0.13
        case .balanced: 0.20
        case .confident: 0.30
        case .bold: 0.45
        case .protective: 0.60
        }
    }

    var layoutStyle: WatermarkLayoutStyle {
        switch self {
        case .discrete, .subtle, .balanced: .single
        case .confident: .singleRotated
        case .bold: .tiled
        case .protective: .tiledRotated
        }
    }

    var opacity: Double {
        switch self {
        case .discrete: 0.12   // lowered from an earlier 0.20 -- meant to be barely there
        case .subtle: 0.40
        case .balanced: 0.55
        case .confident: 0.70
        case .bold: 0.85
        case .protective: 1.00 // raised from an earlier 0.95 -- the whole point is resisting removal
        }
    }

    var layoutMode: LayoutMode { layoutStyle.layoutMode }
    var rotationPattern: RotationPattern { layoutStyle.rotationPattern }

    /// Size axis bounds for the matrix pad -- matches the useful range the
    /// six named points actually cover; anyone wanting more than Protective's
    /// 60% still has the fine-grained Size & Opacity slider below.
    static let sizeRange: ClosedRange<Double> = 0.05...0.60

    static func nearest(sizeFraction: Double, layoutStyle: WatermarkLayoutStyle) -> WatermarkIntensityPreset {
        allCases.min { a, b in
            let da = abs(a.sizeFraction - sizeFraction) + (a.layoutStyle == layoutStyle ? 0 : 0.15)
            let db = abs(b.sizeFraction - sizeFraction) + (b.layoutStyle == layoutStyle ? 0 : 0.15)
            return da < db
        } ?? .subtle
    }
}

enum OpacityPreset: String, CaseIterable, Identifiable, Codable {
    case ghost, subtle, balanced, bold, solid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ghost: String(localized: "Ghost (10%)")
        case .subtle: String(localized: "Subtle (25%)")
        case .balanced: String(localized: "Balanced (50%)")
        case .bold: String(localized: "Bold (75%)")
        case .solid: String(localized: "Solid (100%)")
        }
    }
    /// Compact percentage label for the chip itself — same "short, aligned,
    /// in order" treatment as the size chips.
    var shortLabel: String {
        switch self {
        case .ghost: "10%"
        case .subtle: "25%"
        case .balanced: "50%"
        case .bold: "75%"
        case .solid: "100%"
        }
    }
    var value: Double {
        switch self {
        case .ghost: 0.10
        case .subtle: 0.25
        case .balanced: 0.50
        case .bold: 0.75
        case .solid: 1.00
        }
    }
}

enum Anchor: String, CaseIterable, Identifiable, Codable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .top: "arrow.up"
        case .topRight: "arrow.up.right"
        case .left: "arrow.left"
        case .center: "dot.scope"
        case .right: "arrow.right"
        case .bottomLeft: "arrow.down.left"
        case .bottom: "arrow.down"
        case .bottomRight: "arrow.down.right"
        }
    }
    var displayName: String {
        switch self {
        case .topLeft: String(localized: "top-left")
        case .top: String(localized: "top")
        case .topRight: String(localized: "top-right")
        case .left: String(localized: "left")
        case .center: String(localized: "center")
        case .right: String(localized: "right")
        case .bottomLeft: String(localized: "bottom-left")
        case .bottom: String(localized: "bottom")
        case .bottomRight: String(localized: "bottom-right")
        }
    }
}

enum LayoutMode: String, CaseIterable, Identifiable, Codable {
    case single = "Single"
    case tiled = "Tiled"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

enum FlowMode: String, CaseIterable, Identifiable, Codable {
    case guided = "Guided"
    case compact = "Compact"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

enum RotationPattern: String, CaseIterable, Identifiable, Codable {
    case none = "None (0deg)"
    case diagonal = "Diagonal (45deg)"
    case alternating = "Alternating rows (0deg/45deg)"
    case custom = "Custom angle"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

enum WatermarkTint: String, CaseIterable, Identifiable, Codable {
    case original = "Original"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case keepOriginal = "Keep Original"
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"
    case gif = "GIF"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
    var hint: String {
        switch self {
        case .keepOriginal: String(localized: "Preserves the source type where possible; HEIC falls back to PNG. Use this when you are matching an existing delivery workflow.")
        case .jpeg: String(localized: "Best for photos going to listing sites: small files, fast uploads, no transparency needed.")
        case .png: String(localized: "Use only if you need transparency or plan to edit further. Files are much larger, and most listing portals do not need this.")
        case .tiff: String(localized: "Archival or print-quality only. Files are very large and not intended for web upload.")
        case .gif: String(localized: "Single-frame GIF: simple and widely supported, but limited color and no smooth transparency.")
        }
    }
    var fileExtension: String? {
        switch self {
        case .keepOriginal: nil
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .gif: "gif"
        }
    }
}

struct ImageItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var filename: String { url.lastPathComponent }
}

/// Governs what happens to the source image's GPS location on export.
/// Everything else in scrubbedMetadata's original/hidden metadata (camera
/// make/model, maker notes, AI-provenance descriptions, embedded
/// thumbnails, author fields, etc.) is already unconditionally removed by
/// construction -- the output is a freshly composited CGImage with a
/// synthesized properties dict, never a copy of the source's metadata --
/// verified directly against a real exiftool dump of a real app output
/// (Author "Aubz" and a full AI-generation-prompt Description on the
/// source were both fully gone in the output). GPS is the one field this
/// code deliberately carries over today, unconditionally, at full
/// precision -- this type is what makes that a real choice instead.
enum MetadataPrivacyLevel: String, CaseIterable, Identifiable, Codable {
    case removeLocation
    case reducedPrecision
    case keepOriginalPrecision
    var id: String { rawValue }

    var label: String {
        switch self {
        case .removeLocation: String(localized: "Remove location")
        case .reducedPrecision: String(localized: "Reduce precision (~1km)")
        case .keepOriginalPrecision: String(localized: "Keep exact location")
        }
    }
}

struct WatermarkSettings: Codable {
    var sizeFraction: Double
    var opacity: Double
    var anchor: Anchor
    var additionalAnchors: [Anchor]
    var offsetX: Double
    var offsetY: Double
    var layoutMode: LayoutMode
    var padding: Double
    var spacing: Double
    var rotationPattern: RotationPattern
    var customAngle: Double
    var exportFormat: ExportFormat
    var jpegQuality: Double
    var optimizeForWeb: Bool
    var outputWidth: Int
    var outputHeight: Int
    var outputPrefix: String
    var outputSuffix: String
    var maxFileSizeKB: Int
    var watermarkTint: WatermarkTint
    var metadataPrivacy: MetadataPrivacyLevel
    /// Strips a solid/near-solid background from the watermark image itself
    /// before compositing -- for watermarks that weren't prepared as a
    /// proper transparent PNG. Off by default: an intentionally-opaque
    /// watermark (a solid badge, a colored banner) shouldn't have its
    /// background silently stripped just because this exists.
    var removeWatermarkBackground: Bool

    init(sizeFraction: Double, opacity: Double, anchor: Anchor, additionalAnchors: [Anchor] = [], offsetX: Double, offsetY: Double, layoutMode: LayoutMode, padding: Double, spacing: Double, rotationPattern: RotationPattern, customAngle: Double, exportFormat: ExportFormat, jpegQuality: Double, optimizeForWeb: Bool = false, outputWidth: Int = 0, outputHeight: Int = 0, outputPrefix: String, outputSuffix: String, maxFileSizeKB: Int = 0, watermarkTint: WatermarkTint = .original, metadataPrivacy: MetadataPrivacyLevel = .keepOriginalPrecision, removeWatermarkBackground: Bool = false) {
        self.sizeFraction = sizeFraction
        self.opacity = opacity
        self.anchor = anchor
        self.additionalAnchors = additionalAnchors
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.layoutMode = layoutMode
        self.padding = padding
        self.spacing = spacing
        self.rotationPattern = rotationPattern
        self.customAngle = customAngle
        self.exportFormat = exportFormat
        self.jpegQuality = jpegQuality
        self.optimizeForWeb = optimizeForWeb
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.outputPrefix = outputPrefix
        self.outputSuffix = outputSuffix
        self.maxFileSizeKB = maxFileSizeKB
        self.watermarkTint = watermarkTint
        self.metadataPrivacy = metadataPrivacy
        self.removeWatermarkBackground = removeWatermarkBackground
    }

    private enum CodingKeys: String, CodingKey {
        case sizeFraction, opacity, anchor, additionalAnchors, offsetX, offsetY, layoutMode, padding, spacing, rotationPattern, customAngle, exportFormat, jpegQuality, optimizeForWeb, outputWidth, outputHeight, outputPrefix, outputSuffix, maxFileSizeKB, watermarkTint, metadataPrivacy, removeWatermarkBackground
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sizeFraction = try container.decode(Double.self, forKey: .sizeFraction)
        opacity = try container.decode(Double.self, forKey: .opacity)
        anchor = try container.decode(Anchor.self, forKey: .anchor)
        additionalAnchors = try container.decodeIfPresent([Anchor].self, forKey: .additionalAnchors) ?? []
        offsetX = try container.decode(Double.self, forKey: .offsetX)
        offsetY = try container.decode(Double.self, forKey: .offsetY)
        layoutMode = try container.decode(LayoutMode.self, forKey: .layoutMode)
        padding = try container.decode(Double.self, forKey: .padding)
        spacing = try container.decode(Double.self, forKey: .spacing)
        rotationPattern = try container.decode(RotationPattern.self, forKey: .rotationPattern)
        customAngle = try container.decode(Double.self, forKey: .customAngle)
        exportFormat = try container.decode(ExportFormat.self, forKey: .exportFormat)
        jpegQuality = try container.decode(Double.self, forKey: .jpegQuality)
        optimizeForWeb = try container.decodeIfPresent(Bool.self, forKey: .optimizeForWeb) ?? false
        outputWidth = try container.decodeIfPresent(Int.self, forKey: .outputWidth) ?? 0
        outputHeight = try container.decodeIfPresent(Int.self, forKey: .outputHeight) ?? 0
        outputPrefix = try container.decode(String.self, forKey: .outputPrefix)
        outputSuffix = try container.decode(String.self, forKey: .outputSuffix)
        maxFileSizeKB = try container.decodeIfPresent(Int.self, forKey: .maxFileSizeKB) ?? 0
        watermarkTint = try container.decodeIfPresent(WatermarkTint.self, forKey: .watermarkTint) ?? .original
        // Default preserves the pre-existing, unconditional behavior for
        // any settings saved before this option existed -- keepOriginalPrecision,
        // not removeLocation, so nobody's saved presets silently start
        // stripping GPS they were previously relying on.
        metadataPrivacy = try container.decodeIfPresent(MetadataPrivacyLevel.self, forKey: .metadataPrivacy) ?? .keepOriginalPrecision
        removeWatermarkBackground = try container.decodeIfPresent(Bool.self, forKey: .removeWatermarkBackground) ?? false
    }
}

struct SmartPlacementProposal {
    var anchor: Anchor
    var padding: Double
    var offsetX: Double
    var offsetY: Double
    var tint: WatermarkTint
    var note: String
    var saliencyUnavailable: Bool
}

struct WatermarkPreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var watermarkBookmark: Data
    var settings: WatermarkSettings
}

/// A folder chosen before, kept as a security-scoped bookmark so it can be
/// re-selected in one click instead of re-opening the panel and navigating
/// back to it. path is kept alongside the bookmark purely for cheap
/// dedup/display without resolving+starting security scope just to check
/// "have we seen this one" -- the bookmark itself is still what's used to
/// actually gain access when picked.
struct RecentFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data
    var lastUsed: Date
}

/// One completed batch export -- the source folder, watermark, and settings
/// that produced it. Recorded once per `exportAll()` run (batch-level, not
/// per file), since "redo this" and "swap the logo" are batch-level asks in
/// practice: a whole shoot exported with the wrong logo or the wrong
/// settings, not one photo at a time. Bookmarks so this stays resolvable
/// across launches, same pattern as RecentFolder/WatermarkPreset. Being able
/// to reload a past batch and re-export from its own untouched original
/// means "redo it" or "swap the watermark" never has to touch
/// already-watermarked pixels, or need a separate watermark-removal step at
/// all when the original is still there.
struct ExportHistoryEntry: Identifiable, Codable {
    var id = UUID()
    var folderName: String
    var folderBookmark: Data
    var watermarkName: String
    var watermarkBookmark: Data
    var settings: WatermarkSettings
    var imageCount: Int
    var succeededCount: Int
    var date: Date
}

struct PlatformExportPreset: Identifiable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let jpegQuality: Double
    let note: String

    var sizeLabel: String { String(format: String(localized: "%d×%d JPEG"), width, height) }

    static let all: [PlatformExportPreset] = [
        PlatformExportPreset(
            id: "instagram",
            name: "Instagram",
            width: 1080,
            height: 1080,
            jpegQuality: 0.85,
            note: String(localized: "Instagram square export: 1080x1080 JPEG.")
        ),
        PlatformExportPreset(
            id: "fincaraiz",
            name: "FincaRaiz",
            width: 860,
            height: 482,
            jpegQuality: 0.85,
            note: String(localized: "FincaRaiz: 860x482px landscape, max 4.9MB - per fincaraiz.com.co guidance. Quality is an estimate; actual size depends on image content.")
        ),
        PlatformExportPreset(
            id: "metrocuadrado",
            name: "Metrocuadrado",
            width: 1600,
            height: 1200,
            jpegQuality: 0.85,
            note: String(localized: "Metrocuadrado: inferred 1600x1200px safe default; no exact official pixel spec published. Quality is an estimate; actual size depends on image content.")
        ),
        PlatformExportPreset(
            id: "ciencuadras",
            name: "100Cuadras",
            width: 1200,
            height: 1200,
            jpegQuality: 0.85,
            note: String(localized: "100Cuadras: 1200x1200px square, max 2MB - per Ciencuadras guidance. Quality is an estimate; actual size depends on image content.")
        )
    ]
}

struct ExportSummary {
    var success: Int
    var failed: [String]
    var bytes: Int
    var usedHEICFallback: Bool
    var unmetSizeTarget: [String] = []
}
