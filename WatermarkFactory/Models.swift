import Foundation
import SwiftUI

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
    case chat = "Chat"
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

enum ChatRole: String, Codable {
    case assistant, user
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: ChatRole
    var text: String
    var chips: [String]?
}

struct ChatQuestion: Identifiable {
    let id: String
    let text: String
    let chips: [String]
}

struct IntentSlots: Codable, Equatable {
    var anchor: String?
    var additionalAnchors: [String]?
    var sizeFraction: Double?
    var opacity: Double?
    var tint: String?
    var exportPlatform: String?
    var contentType: String?
    var renamePrefix: String?
    var reorder: String?
    var maxFileSizeKB: Double?
    var needsClarification: [String]
    var assistantReply: String

    init(anchor: String? = nil, additionalAnchors: [String]? = nil, sizeFraction: Double? = nil, opacity: Double? = nil, tint: String? = nil, exportPlatform: String? = nil, contentType: String? = nil, renamePrefix: String? = nil, reorder: String? = nil, maxFileSizeKB: Double? = nil, needsClarification: [String] = [], assistantReply: String = "") {
        self.anchor = anchor
        self.additionalAnchors = additionalAnchors
        self.sizeFraction = sizeFraction
        self.opacity = opacity
        self.tint = tint
        self.exportPlatform = exportPlatform
        self.contentType = contentType
        self.renamePrefix = renamePrefix
        self.reorder = reorder
        self.maxFileSizeKB = maxFileSizeKB
        self.needsClarification = needsClarification
        self.assistantReply = assistantReply
    }
}

enum IntentPreset: String, CaseIterable {
    case cornerSubtle, centeredBold, tiledBrand

    static func inferred(from message: String, slots: IntentSlots) -> IntentPreset {
        let text = message.lowercased()
        if slots.anchor == "tiled" || text.contains("tile") || text.contains("repeat") { return .tiledBrand }
        if slots.anchor == Anchor.center.rawValue || text.contains("center") || text.contains("bold") { return .centeredBold }
        return .cornerSubtle
    }

    static func settings(from slots: IntentSlots, message: String, current: WatermarkSettings = .chatDefault) -> WatermarkSettings {
        var settings = WatermarkSettings.chatDefault
        settings.outputSuffix = current.outputSuffix
        apply(inferred(from: message, slots: slots), to: &settings)

        if let anchor = slots.anchor {
            if anchor == "tiled" {
                settings.layoutMode = .tiled
            } else if let parsed = Anchor(rawValue: anchor) {
                settings.layoutMode = .single
                settings.anchor = parsed
            }
        }
        settings.additionalAnchors = (slots.additionalAnchors ?? []).compactMap(Anchor.init(rawValue:))
        if let size = slots.sizeFraction { settings.sizeFraction = min(max(size, 0.05), 0.6) }
        if let opacity = slots.opacity { settings.opacity = min(max(opacity, 0), 1) }
        if let tint = slots.tint, let parsed = WatermarkTint(rawValue: tint) { settings.watermarkTint = parsed }
        applyPlatform(slots.exportPlatform ?? "original", to: &settings)
        applyContentType(slots.contentType, to: &settings)
        if let maxFileSizeKB = slots.maxFileSizeKB {
            settings.maxFileSizeKB = max(0, Int(maxFileSizeKB.rounded()))
        }
        settings.outputPrefix = (slots.renamePrefix ?? "").replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "\0", with: "")
        return settings
    }

    static func apply(_ preset: IntentPreset, to settings: inout WatermarkSettings) {
        switch preset {
        case .cornerSubtle:
            settings.layoutMode = .single
            settings.anchor = .bottomRight
            settings.sizeFraction = 0.18
            settings.opacity = 0.5
            settings.watermarkTint = .original
        case .centeredBold:
            settings.layoutMode = .single
            settings.anchor = .center
            settings.sizeFraction = 0.35
            settings.opacity = 0.85
        case .tiledBrand:
            settings.layoutMode = .tiled
            settings.rotationPattern = .diagonal
            settings.spacing = 80
        }
    }

    private static func applyPlatform(_ platform: String, to settings: inout WatermarkSettings) {
        switch platform.lowercased() {
        case "instagram":
            if let preset = PlatformExportPreset.all.first(where: { $0.id == "instagram" }) {
                settings.outputWidth = preset.width
                settings.outputHeight = preset.height
                settings.exportFormat = .jpeg
                settings.jpegQuality = preset.jpegQuality
            }
        case "web":
            settings.optimizeForWeb = true
            settings.exportFormat = .jpeg
            settings.jpegQuality = min(settings.jpegQuality, 0.8)
        case "print":
            settings.exportFormat = .tiff
            settings.outputWidth = 0
            settings.outputHeight = 0
            settings.maxFileSizeKB = 0
        case "original":
            settings.exportFormat = .keepOriginal
        default:
            break
        }
    }

    private static func applyContentType(_ contentType: String?, to settings: inout WatermarkSettings) {
        switch contentType?.lowercased() {
        case "camera": settings.exportFormat = .jpeg
        case "graphic": settings.exportFormat = .png
        case "geodata": settings.exportFormat = .tiff
        case "gif": settings.exportFormat = .gif
        case "other": settings.exportFormat = .keepOriginal
        default: break
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

    init(sizeFraction: Double, opacity: Double, anchor: Anchor, additionalAnchors: [Anchor] = [], offsetX: Double, offsetY: Double, layoutMode: LayoutMode, padding: Double, spacing: Double, rotationPattern: RotationPattern, customAngle: Double, exportFormat: ExportFormat, jpegQuality: Double, optimizeForWeb: Bool = false, outputWidth: Int = 0, outputHeight: Int = 0, outputPrefix: String, outputSuffix: String, maxFileSizeKB: Int = 0, watermarkTint: WatermarkTint = .original) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case sizeFraction, opacity, anchor, additionalAnchors, offsetX, offsetY, layoutMode, padding, spacing, rotationPattern, customAngle, exportFormat, jpegQuality, optimizeForWeb, outputWidth, outputHeight, outputPrefix, outputSuffix, maxFileSizeKB, watermarkTint
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
    }
}

extension WatermarkSettings {
    static let chatDefault = WatermarkSettings(sizeFraction: 0.18, opacity: 0.5, anchor: .bottomRight, offsetX: 24, offsetY: 24, layoutMode: .single, padding: 16, spacing: 80, rotationPattern: .diagonal, customAngle: 30, exportFormat: .keepOriginal, jpegQuality: 0.9, outputPrefix: "", outputSuffix: "", watermarkTint: .original)
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
