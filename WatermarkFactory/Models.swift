import Foundation
import SwiftUI

enum WatermarkSizePreset: String, CaseIterable, Identifiable {
    case tiny, small, medium, large, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: "Tiny (10%)"
        case .small: "Small (20%)"
        case .medium: "Medium (35%)"
        case .large: "Large (50%)"
        case .full: "Full (75%)"
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

enum OpacityPreset: String, CaseIterable, Identifiable {
    case ghost, subtle, balanced, bold, solid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ghost: "Ghost (10%)"
        case .subtle: "Subtle (25%)"
        case .balanced: "Balanced (50%)"
        case .bold: "Bold (75%)"
        case .solid: "Solid (100%)"
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

enum Anchor: String, CaseIterable, Identifiable {
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
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case single = "Single"
    case tiled = "Tiled"
    var id: String { rawValue }
}

enum RotationPattern: String, CaseIterable, Identifiable {
    case none = "None (0deg)"
    case diagonal = "Diagonal (45deg)"
    case alternating = "Alternating rows (0deg/45deg)"
    case custom = "Custom angle"
    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case keepOriginal = "Keep Original"
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"
    var id: String { rawValue }
    var hint: String {
        switch self {
        case .keepOriginal: "Preserves source type where possible; HEIC falls back to PNG."
        case .jpeg: "Smaller file, no transparency."
        case .png: "Lossless, supports transparency."
        case .tiff: "Largest file, lossless, editing-grade."
        }
    }
    var fileExtension: String? {
        switch self {
        case .keepOriginal: nil
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        }
    }
}

struct ImageItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var filename: String { url.lastPathComponent }
}

struct WatermarkSettings {
    var sizeFraction: Double
    var opacity: Double
    var anchor: Anchor
    var offsetX: Double
    var offsetY: Double
    var layoutMode: LayoutMode
    var padding: Double
    var spacing: Double
    var rotationPattern: RotationPattern
    var customAngle: Double
    var exportFormat: ExportFormat
    var jpegQuality: Double
    var outputPrefix: String
    var outputSuffix: String
}

struct ExportSummary {
    var success: Int
    var failed: [String]
    var bytes: Int
    var usedHEICFallback: Bool
}
