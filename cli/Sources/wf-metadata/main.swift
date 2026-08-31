import Foundation

// wf-metadata: headless CLI for WatermarkFactory's export pipeline --
// watermarking, resizing, and metadata privacy, using the exact same
// ImageProcessor code the GUI app runs (symlinked source, not a
// reimplementation). Built specifically so these controls (metadata
// privacy in particular) are reachable without opening the app, and so
// they can be scripted/tested against a real folder of images directly.

func printUsage() {
    print("""
    wf-metadata -- batch watermark + metadata privacy, headless

    USAGE:
      wf-metadata --source <folder> --watermark <file> [options]

    OPTIONS:
      --source <folder>           Folder of images to process (required)
      --watermark <file>          Watermark image (required)
      --output <folder>           Output folder (default: <source>/Watermarked)
      --size <0-1>                Watermark size as a fraction of canvas (default: 0.13)
      --opacity <0-1>             Watermark opacity (default: 0.4)
      --anchor <name>             topLeft|top|topRight|left|center|right|bottomLeft|bottom|bottomRight (default: bottomRight)
      --format <name>             keepOriginal|jpeg|png|tiff|gif (default: keepOriginal)
      --optimize-for-web          Cap longest edge at 2048px
      --max-file-size-kb <n>      Target max output size per image (JPEG only)
      --metadata-privacy <level>  remove|reduced|keep (default: keep)
                                     remove  = drop GPS location entirely
                                     reduced = round GPS to ~1km precision
                                     keep    = preserve exact GPS if present
                                   Original/hidden metadata (camera info, maker
                                   notes, AI-provenance descriptions, embedded
                                   thumbnails) is always removed regardless of
                                   this setting -- this flag only controls GPS.
      --dry-run                   List what would be processed, write nothing

    EXAMPLES:
      wf-metadata --source ~/Photos --watermark ~/logo.png --metadata-privacy remove
      wf-metadata --source ~/Photos --watermark ~/logo.png --optimize-for-web --max-file-size-kb 500
    """)
}

func parseAnchor(_ value: String) -> Anchor? {
    Anchor.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }
}

func parseFormat(_ value: String) -> ExportFormat? {
    switch value.lowercased() {
    case "keeporiginal", "keep-original", "original": return .keepOriginal
    case "jpeg", "jpg": return .jpeg
    case "png": return .png
    case "tiff", "tif": return .tiff
    case "gif": return .gif
    default: return nil
    }
}

func parseMetadataPrivacy(_ value: String) -> MetadataPrivacyLevel? {
    switch value.lowercased() {
    case "remove", "removelocation", "none": return .removeLocation
    case "reduced", "reducedprecision": return .reducedPrecision
    case "keep", "keeporiginalprecision", "full": return .keepOriginalPrecision
    default: return nil
    }
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    printUsage()
    exit(args.isEmpty ? 1 : 0)
}

func flagValue(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
func hasFlag(_ name: String) -> Bool { args.contains(name) }

guard let sourcePath = flagValue("--source") else {
    FileHandle.standardError.write("error: --source is required\n".data(using: .utf8)!)
    exit(1)
}
guard let watermarkPath = flagValue("--watermark") else {
    FileHandle.standardError.write("error: --watermark is required\n".data(using: .utf8)!)
    exit(1)
}
let sourceFolder = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath)
let watermarkURL = URL(fileURLWithPath: (watermarkPath as NSString).expandingTildeInPath)
let outputFolder = flagValue("--output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? sourceFolder.appendingPathComponent("Watermarked", isDirectory: true)

var sizeFraction = 0.13
if let raw = flagValue("--size"), let parsed = Double(raw) { sizeFraction = parsed }
var opacity = 0.4
if let raw = flagValue("--opacity"), let parsed = Double(raw) { opacity = parsed }
var anchor: Anchor = .bottomRight
if let raw = flagValue("--anchor") {
    guard let parsed = parseAnchor(raw) else {
        FileHandle.standardError.write("error: unknown --anchor '\(raw)'\n".data(using: .utf8)!)
        exit(1)
    }
    anchor = parsed
}
var exportFormat: ExportFormat = .keepOriginal
if let raw = flagValue("--format") {
    guard let parsed = parseFormat(raw) else {
        FileHandle.standardError.write("error: unknown --format '\(raw)'\n".data(using: .utf8)!)
        exit(1)
    }
    exportFormat = parsed
}
var metadataPrivacy: MetadataPrivacyLevel = .keepOriginalPrecision
if let raw = flagValue("--metadata-privacy") {
    guard let parsed = parseMetadataPrivacy(raw) else {
        FileHandle.standardError.write("error: unknown --metadata-privacy '\(raw)' (use remove|reduced|keep)\n".data(using: .utf8)!)
        exit(1)
    }
    metadataPrivacy = parsed
}
var maxFileSizeKB = 0
if let raw = flagValue("--max-file-size-kb"), let parsed = Int(raw) { maxFileSizeKB = parsed }
let optimizeForWeb = hasFlag("--optimize-for-web")
let dryRun = hasFlag("--dry-run")

guard FileManager.default.fileExists(atPath: sourceFolder.path) else {
    FileHandle.standardError.write("error: source folder does not exist: \(sourceFolder.path)\n".data(using: .utf8)!)
    exit(1)
}
guard FileManager.default.fileExists(atPath: watermarkURL.path) else {
    FileHandle.standardError.write("error: watermark file does not exist: \(watermarkURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let images = (try? FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil))?
    .filter { ImageProcessor.supportedExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []

guard !images.isEmpty else {
    FileHandle.standardError.write("error: no supported images found in \(sourceFolder.path)\n".data(using: .utf8)!)
    exit(1)
}

print("Found \(images.count) image(s) in \(sourceFolder.path)")
print("Watermark: \(watermarkURL.lastPathComponent)  size: \(Int(sizeFraction * 100))%  opacity: \(Int(opacity * 100))%  anchor: \(anchor.rawValue)")
print("Format: \(exportFormat.rawValue)  optimizeForWeb: \(optimizeForWeb)  maxFileSizeKB: \(maxFileSizeKB == 0 ? "off" : "\(maxFileSizeKB)")")
print("Metadata privacy (GPS): \(metadataPrivacy.rawValue)")
print("Output: \(outputFolder.path)")

if dryRun {
    for image in images { print("  would process: \(image.lastPathComponent)") }
    print("(dry run -- nothing written)")
    exit(0)
}

do {
    try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("error: could not create output folder: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

let settings = WatermarkSettings(
    sizeFraction: sizeFraction, opacity: opacity, anchor: anchor, offsetX: 24, offsetY: 24,
    layoutMode: .single, padding: 16, spacing: 80, rotationPattern: .none, customAngle: 30,
    exportFormat: exportFormat, jpegQuality: 0.9, optimizeForWeb: optimizeForWeb,
    outputPrefix: "", outputSuffix: "", maxFileSizeKB: maxFileSizeKB, metadataPrivacy: metadataPrivacy
)

var succeeded = 0
var failed: [String] = []
var usedURLs = Set<URL>()
for (index, image) in images.enumerated() {
    let outputURL = ImageProcessor.uniqueOutputURL(for: image, outputFolder: outputFolder, settings: settings, order: nil, numberedCount: 0, usedURLs: &usedURLs)
    do {
        let result = try ImageProcessor.export(sourceURL: image, watermarkURL: watermarkURL, outputURL: outputURL, settings: settings)
        succeeded += 1
        print("[\(index + 1)/\(images.count)] OK   \(image.lastPathComponent) -> \(outputURL.lastPathComponent) (\(result.bytes) bytes)")
    } catch {
        failed.append(image.lastPathComponent)
        print("[\(index + 1)/\(images.count)] FAIL \(image.lastPathComponent): \(error.localizedDescription)")
    }
}

print("\n\(succeeded) of \(images.count) succeeded.")
if !failed.isEmpty {
    print("Failed: \(failed.joined(separator: ", "))")
    exit(1)
}
