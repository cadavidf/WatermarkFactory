import Foundation
import SwiftUI

enum WatermarkSizePreset: String, CaseIterable, Identifiable, Codable {
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

enum OpacityPreset: String, CaseIterable, Identifiable, Codable {
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
}

enum LayoutMode: String, CaseIterable, Identifiable, Codable {
    case single = "Single"
    case tiled = "Tiled"
    var id: String { rawValue }
}

enum RotationPattern: String, CaseIterable, Identifiable, Codable {
    case none = "None (0deg)"
    case diagonal = "Diagonal (45deg)"
    case alternating = "Alternating rows (0deg/45deg)"
    case custom = "Custom angle"
    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
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

struct WatermarkSettings: Codable {
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
    var optimizeForWeb: Bool
    var outputWidth: Int
    var outputHeight: Int
    var outputPrefix: String
    var outputSuffix: String

    init(sizeFraction: Double, opacity: Double, anchor: Anchor, offsetX: Double, offsetY: Double, layoutMode: LayoutMode, padding: Double, spacing: Double, rotationPattern: RotationPattern, customAngle: Double, exportFormat: ExportFormat, jpegQuality: Double, optimizeForWeb: Bool = false, outputWidth: Int = 0, outputHeight: Int = 0, outputPrefix: String, outputSuffix: String) {
        self.sizeFraction = sizeFraction
        self.opacity = opacity
        self.anchor = anchor
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
    }

    private enum CodingKeys: String, CodingKey {
        case sizeFraction, opacity, anchor, offsetX, offsetY, layoutMode, padding, spacing, rotationPattern, customAngle, exportFormat, jpegQuality, optimizeForWeb, outputWidth, outputHeight, outputPrefix, outputSuffix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sizeFraction = try container.decode(Double.self, forKey: .sizeFraction)
        opacity = try container.decode(Double.self, forKey: .opacity)
        anchor = try container.decode(Anchor.self, forKey: .anchor)
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
    }
}

struct WatermarkPreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var watermarkBookmark: Data
    var settings: WatermarkSettings
}

struct PlatformExportPreset: Identifiable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let jpegQuality: Double
    let note: String

    var sizeLabel: String { "\(width)x\(height) JPEG" }

    static let all: [PlatformExportPreset] = [
        PlatformExportPreset(
            id: "fincaraiz",
            name: "FincaRaiz",
            width: 860,
            height: 482,
            jpegQuality: 0.85,
            note: "FincaRaiz: 860x482px landscape, max 4.9MB - per fincaraiz.com.co guidance. Quality is an estimate; actual size depends on image content."
        ),
        PlatformExportPreset(
            id: "metrocuadrado",
            name: "Metrocuadrado",
            width: 1600,
            height: 1200,
            jpegQuality: 0.85,
            note: "Metrocuadrado: inferred 1600x1200px safe default; no exact official pixel spec published. Quality is an estimate; actual size depends on image content."
        ),
        PlatformExportPreset(
            id: "ciencuadras",
            name: "100Cuadras",
            width: 1200,
            height: 1200,
            jpegQuality: 0.85,
            note: "100Cuadras: 1200x1200px square, max 2MB - per Ciencuadras guidance. Quality is an estimate; actual size depends on image content."
        )
    ]
}

struct ExportSummary {
    var success: Int
    var failed: [String]
    var bytes: Int
    var usedHEICFallback: Bool
}
