import AppKit
import AutomalityUI
import DesignSystemKit
import SwiftUI
import UniformTypeIdentifiers

// AcknowledgementsView.swift (untouched, outside this PRD's scope) still
// relies on this token.
extension AutomalityColor {
    static let inkMuted = ink.opacity(0.68)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var folderURL: URL?
    @Published var watermarkURL: URL?
    // Compact mode's "Watermark not uploaded yet" prompt (Upload Watermark /
    // Compress Only), shown when Watermark All Images is tapped with no
    // watermark chosen -- see watermarkAllTapped() below.
    @Published var showWatermarkMissingPrompt = false
    // Set right before showWatermarkMissingPrompt so the alert's "Compress
    // Only" fallback (see ContentView's .alert) compresses the same scope
    // (all images vs. just the selected one) the user actually asked for.
    var missingWatermarkPromptOnlySelected = false
    @Published var images: [ImageItem] = []
    @Published var selected: ImageItem?
    @Published var sizePreset: WatermarkSizePreset? = .medium
    @Published var opacityPreset: OpacityPreset? = .balanced
    // The intensity matrix binds directly to sizeFraction (X, below) and
    // this computed layoutStyle (Y) rather than shadow state -- layoutStyle
    // just names one of the 4 meaningful combinations of the two real
    // settings (layoutMode, rotationPattern) that already exist; writing to
    // it writes straight through to them, no separate state to keep in
    // sync. Opacity is NOT part of the matrix: it rides along visibly as
    // the drag handle's own transparency but stays the existing
    // independent `opacity` property, adjustable on its own.
    var intensityLayoutStyle: WatermarkLayoutStyle {
        get { WatermarkLayoutStyle.closest(to: layoutMode, rotationPattern: rotationPattern) }
        set {
            layoutMode = newValue.layoutMode
            rotationPattern = newValue.rotationPattern
        }
    }
    @Published var sizeFraction = 0.35 { didSet { saveSettings(); updateEstimate() } }
    @Published var opacity = 0.5 { didSet { saveSettings(); updateEstimate() } }
    @Published var anchor: Anchor = .bottomRight { didSet { saveSettings(); updateEstimate() } }
    @Published var additionalAnchors: [Anchor] = [] { didSet { saveSettings(); updateEstimate() } }
    @Published var offsetX = 24.0 { didSet { saveSettings(); if !suppressOffsetPreview { updateEstimate() } } }
    @Published var offsetY = 24.0 { didSet { saveSettings(); if !suppressOffsetPreview { updateEstimate() } } }
    @Published var layoutMode: LayoutMode = .single {
        didSet {
            // "Alternating rows" only means something when tiled -- switching
            // to Single with it selected would leave the Rotation picker
            // showing a choice that isn't even offered there.
            if layoutMode == .single, rotationPattern == .alternating {
                rotationPattern = .none
            }
            // Same reasoning for "Alternating rows" appearance -- also
            // tiling-only, nothing to alternate between with one mark.
            if layoutMode == .single, watermarkTint == .alternating {
                watermarkTint = .original
            }
            saveSettings()
            updateEstimate()
        }
    }
    @Published var padding = 16.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var spacing = 80.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var rotationPattern: RotationPattern = .none { didSet { saveSettings(); updateEstimate() } }
    @Published var customAngle = 30.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var exportFormat: ExportFormat = .keepOriginal {
        didSet {
            if optimizeForWeb && exportFormat == .jpeg && jpegQuality > 0.8 { jpegQuality = 0.8 }
            saveSettings()
            updateEstimate()
        }
    }
    @Published var jpegQuality = 0.9 { didSet { saveSettings(); updateEstimate() } }
    @Published var optimizeForWeb = false { didSet { saveSettings(); updateEstimate() } }
    @Published var outputWidth = 0 { didSet { saveSettings(); updateEstimate() } }
    @Published var outputHeight = 0 { didSet { saveSettings(); updateEstimate() } }
    @Published var outputPrefix = "" { didSet { saveSettings(); updateEstimate() } }
    @Published var outputSuffix = "" { didSet { saveSettings(); updateEstimate() } }
    @Published var maxFileSizeKB = 0 { didSet { saveSettings(); updateEstimate() } }
    @Published var watermarkTint: WatermarkTint = .original { didSet { saveSettings(); updateEstimate() } }
    @Published var metadataPrivacy: MetadataPrivacyLevel = .removeLocation { didSet { saveSettings(); updateEstimate() } }
    @Published var removeWatermarkBackground = false { didSet { saveSettings(); updateEstimate() } }
    // 0 = no change, matches Opacity/Size's own 0...1 slider convention.
    @Published var watermarkContrast: Double = 0 { didSet { saveSettings(); updateEstimate() } }
    @Published var textWatermarkFontSize: Double = 200 {
        didSet {
            saveSettings()
            // Editable anytime, not just at creation -- re-render in place
            // so the slider actually does something after the fact.
            if isTextWatermark { refreshTextWatermark() }
        }
    }
    // Remembers what was typed so the font-size slider can re-render the
    // same label later -- only the rendered PNG persists otherwise.
    @Published var textWatermarkContent: String = "" { didSet { saveSettings() } }
    @Published var isTextWatermark: Bool = false
    @Published var cropScope: CropScope = .allImages
    @Published var cropEnabled = false { didSet { updateEstimate() } }
    @Published var sharedCropRect: CGRect = .fullFrame { didSet { updateEstimate() } }
    @Published var perImageCropRects: [URL: CGRect] = [:] { didSet { updateEstimate() } }
    @Published var previewImage: NSImage?
    @Published var isDemoPreview = false
    @Published var sourceImageSize: CGSize?
    @Published var watermarkImageSize: CGSize?
    @Published var estimatedSize = ""
    @Published var estimatedFilename = ""
    @Published var status = String(localized: "Choose a folder and watermark to begin.")
    @Published var progress = 0.0
    @Published var isExporting = false
    @Published var exportETAText = ""
    @Published var showExportCelebration = false
    @Published var showQuickActionPrompt = false
    @Published var isSuggestingPlacement = false
    @Published var roomLabels: [URL: String] = [:]
    @Published var isClassifyingRooms = false
    @Published var smartPlacementProposal: SmartPlacementProposal?
    @Published var presets: [WatermarkPreset] = []
    @Published var recentFolders: [RecentFolder] = []
    @Published var savedWatermarks: [SavedWatermark] = []
    @Published var exportHistory: [ExportHistoryEntry] = []
    @Published var orderedImageURLs: [URL] = [] { didSet { saveImageOrder() } }

    enum OpenedURLInput: Equatable {
        case folder(URL)
        case images([URL])
    }

    private var previewTask: Task<Void, Never>?
    private var sourceSizeURL: URL?
    private var watermarkSizeURL: URL?
    private var suppressOffsetPreview = false
    private var exportStartedAt: Date?
    private let sourceAccess = SecurityScopedAccessTracker()
    private let watermarkAccess = SecurityScopedAccessTracker()
    private let defaults = UserDefaults.standard

    init() {
        restore()
    }

    deinit {
        sourceAccess.stopAll()
        watermarkAccess.stopAll()
    }

    /// A max-file-size target only makes sense with lossy JPEG output. PNG/TIFF are
    /// explicit lossless choices that can't be quality-adjusted down, so block export
    /// rather than silently ignoring the size target or silently switching format.
    var maxFileSizeBlocksExport: Bool {
        maxFileSizeKB > 0 && (exportFormat == .png || exportFormat == .tiff)
    }
    var canExport: Bool { watermarkURL != nil && !images.isEmpty && !isExporting && !maxFileSizeBlocksExport }
    // Compact mode's always-visible Watermark All Images button stays
    // enabled even without a watermark chosen yet -- tapping it without one
    // opens the "Watermark not uploaded yet" prompt (Upload Watermark /
    // Compress Only) instead of just sitting there disabled and unexplained.
    var canTapWatermarkAll: Bool { !images.isEmpty && !isExporting && !maxFileSizeBlocksExport }
    var canTapWatermarkSelected: Bool { selected != nil && !isExporting && !maxFileSizeBlocksExport }

    func watermarkAllTapped() {
        guard canTapWatermarkAll else { return }
        if watermarkURL != nil {
            exportAll()
        } else {
            missingWatermarkPromptOnlySelected = false
            showWatermarkMissingPrompt = true
        }
    }

    func watermarkSelectedTapped() {
        guard canTapWatermarkSelected else { return }
        if watermarkURL != nil {
            exportAll(onlySelected: true)
        } else {
            missingWatermarkPromptOnlySelected = true
            showWatermarkMissingPrompt = true
        }
    }
    var orderedItems: [ImageItem] {
        let numbered = orderedImageURLs.compactMap { url in images.first { $0.url == url } }
        let numberedURLs = Set(orderedImageURLs)
        return numbered + images.filter { !numberedURLs.contains($0.url) }
    }
    var numberedCount: Int { orderedImageURLs.filter { url in images.contains { $0.url == url } }.count }
    var orderSummary: String { String(format: String(localized: "%d of %d images numbered"), numberedCount, images.count) }
    var exportHint: String? {
        if images.isEmpty { return String(localized: "Choose a folder or images before export.") }
        if watermarkURL == nil { return String(localized: "Choose a watermark image before export.") }
        if maxFileSizeBlocksExport { return String(localized: "Max file size requires JPEG — switch format or clear this limit.") }
        return nil
    }
    var settings: WatermarkSettings {
        WatermarkSettings(sizeFraction: sizeFraction, opacity: opacity, anchor: anchor, additionalAnchors: additionalAnchors, offsetX: offsetX, offsetY: offsetY, layoutMode: layoutMode, padding: padding, spacing: spacing, rotationPattern: rotationPattern, customAngle: customAngle, exportFormat: exportFormat, jpegQuality: jpegQuality, optimizeForWeb: optimizeForWeb, outputWidth: outputWidth, outputHeight: outputHeight, outputPrefix: outputPrefix, outputSuffix: outputSuffix, maxFileSizeKB: maxFileSizeKB, watermarkTint: watermarkTint, metadataPrivacy: metadataPrivacy, removeWatermarkBackground: removeWatermarkBackground, watermarkContrast: watermarkContrast)
    }
    var canSavePreset: Bool { watermarkURL != nil }
    var canSuggestPlacement: Bool { selected != nil && watermarkURL != nil && !isSuggestingPlacement }
    func effectiveCropRect(for url: URL) -> CGRect { perImageCropRects[url] ?? sharedCropRect }
    func activeCropRect(for url: URL) -> CGRect { cropEnabled ? effectiveCropRect(for: url) : .fullFrame }

    func hasWatermarkedOutput(for item: ImageItem) -> Bool {
        let watermarkedDir = item.url.deletingLastPathComponent().appendingPathComponent("Watermarked", isDirectory: true)
        let stem = item.url.deletingPathExtension().lastPathComponent
        guard let contents = try? FileManager.default.contentsOfDirectory(at: watermarkedDir, includingPropertiesForKeys: nil) else { return false }
        return contents.contains { $0.deletingPathExtension().lastPathComponent.contains(stem) }
    }

    /// Single picker for both a folder and individual images -- there's no
    /// real reason to force a person to know in advance which of those two
    /// things they have before they're even allowed to open the panel.
    /// Dispatches through the same openedURLInput/open(_:) path the Finder
    /// Quick Action and drag-and-drop use, so all three entry points agree
    /// on "if anything selected is a folder, treat the whole selection as
    /// that one folder" (matches the existing Quick Action semantics rather
    /// than introducing a second, different merge rule).
    func chooseFolderOrImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        if panel.runModal() == .OK, let input = Self.openedURLInput(from: panel.urls) {
            open(input)
        }
    }

    /// Drag-and-drop entry point (see imageList's dropDestination)
    /// -- same dispatch as chooseFolderOrImages/openFromFinder.
    func addDroppedURLs(_ urls: [URL]) {
        guard let input = Self.openedURLInput(from: urls) else { return }
        open(input)
    }

    func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        if panel.runModal() == .OK, let url = panel.url {
            isTextWatermark = false
            setWatermark(url)
            recordSavedWatermark(url)
        }
    }

    /// Renders `text` to a PNG and uses it as the watermark, same as
    /// picking an image file -- see ImageProcessor.renderTextWatermark.
    func createTextWatermark(_ text: String) {
        guard let url = ImageProcessor.renderTextWatermark(text, fontSize: textWatermarkFontSize) else { return }
        textWatermarkContent = text
        isTextWatermark = true
        setWatermark(url)
    }

    /// Re-renders the current text watermark at its (possibly just
    /// changed) font size -- same file path, so the existing watermarkURL
    /// stays valid; only the pixels change.
    private func refreshTextWatermark() {
        guard !textWatermarkContent.isEmpty,
              ImageProcessor.renderTextWatermark(textWatermarkContent, fontSize: textWatermarkFontSize) != nil else { return }
        updateEstimate()
    }

    func select(_ item: ImageItem) {
        selected = item
        smartPlacementProposal = nil
        updateEstimate()
    }

    func orderNumber(for item: ImageItem) -> Int? {
        orderedImageURLs.firstIndex(of: item.url).map { $0 + 1 }
    }

    func toggleOrder(for item: ImageItem) {
        if let index = orderedImageURLs.firstIndex(of: item.url) {
            orderedImageURLs.remove(at: index)
        } else {
            orderedImageURLs.append(item.url)
        }
        updateEstimate(delay: 0)
    }

    func clearOrder() {
        orderedImageURLs = []
        updateEstimate(delay: 0)
    }

    func numberInCurrentOrder(_ items: [ImageItem]? = nil) {
        orderedImageURLs = (items ?? images).map(\.url)
        updateEstimate(delay: 0)
    }

    func moveOrder(from source: ImageItem, to destination: ImageItem) {
        var items = orderedItems
        guard let from = items.firstIndex(of: source),
              let to = items.firstIndex(of: destination),
              from != to else { return }
        let moved = items.remove(at: from)
        items.insert(moved, at: to)
        orderedImageURLs = items.map(\.url)
        updateEstimate(delay: 0)
    }

    func updateEstimate(delay: UInt64 = 100_000_000) {
        previewTask?.cancel()
        let settings = settings
        if selected?.url != sourceSizeURL {
            sourceSizeURL = selected?.url
            sourceImageSize = selected.flatMap { ImageProcessor.imageSize(for: $0.url) }
        }
        if watermarkURL != watermarkSizeURL {
            watermarkSizeURL = watermarkURL
            watermarkImageSize = watermarkURL.flatMap(ImageProcessor.imageSize)
        }
        guard let source = selected?.url else {
            previewImage = nil
            estimatedSize = ""
            estimatedFilename = ""
            return
        }
        let roomLabel = roomLabels[source]
        // No watermark chosen yet: preview with Automality's own bundled
        // mark instead of nothing, so the intensity slider/presets are
        // actually visible and meaningful before the user has anything of
        // their own to try them on. Purely a demo -- isDemoPreview tells
        // the UI to badge this clearly, and it never substitutes for a
        // real watermark in export (canExport still requires watermarkURL).
        isDemoPreview = watermarkURL == nil
        guard let watermark = watermarkURL ?? Self.demoWatermarkURL else {
            previewImage = ImageProcessor.thumbnail(for: source, maxPixelSize: 900)
            estimatedSize = ""
            estimatedFilename = ImageProcessor.outputFilename(for: source, settings: settings, order: orderNumber(for: selected!), numberedCount: numberedCount, roomLabel: roomLabel)
            return
        }
        let realWatermark = watermarkURL != nil
        let filename = realWatermark ? ImageProcessor.outputFilename(for: source, settings: settings, order: selected.flatMap(orderNumber), numberedCount: numberedCount, roomLabel: roomLabel) : ""
        let cropRect = activeCropRect(for: source)
        previewTask = Task.detached {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled { return }
            let image = try? ImageProcessor.watermarkedImage(sourceURL: source, watermarkURL: watermark, settings: settings, cropRect: cropRect)
            let data = realWatermark ? try? ImageProcessor.encodedWatermarkData(sourceURL: source, watermarkURL: watermark, settings: settings, cropRect: cropRect) : nil
            await MainActor.run {
                if !Task.isCancelled {
                    self.previewImage = image.map { NSImage(cgImage: $0, size: .zero) }
                    self.estimatedSize = realWatermark ? (data.map { "~" + Self.formatBytes($0.count) } ?? "") : ""
                    self.estimatedFilename = filename
                }
            }
        }
    }

    static let demoWatermarkURL: URL? = Bundle.main.url(forResource: "automality-watermark", withExtension: "png")

    func dragWatermark(startX: Double, startY: Double, delta: CGSize, displayScale: CGFloat) {
        guard let sourceImageSize, let watermarkImageSize, displayScale > 0 else { return }
        let cropRect = selected.map { activeCropRect(for: $0.url) } ?? .fullFrame
        let canvasSize = CGSize(width: sourceImageSize.width * cropRect.width, height: sourceImageSize.height * cropRect.height)
        let clamped = ImageProcessor.clampedWatermarkOffsets(
            sourceSize: canvasSize,
            watermarkSize: watermarkImageSize,
            settings: settings,
            offsetX: startX + Double(delta.width / displayScale),
            offsetY: startY + Double(delta.height / displayScale)
        )
        suppressOffsetPreview = true
        offsetX = clamped.x
        offsetY = clamped.y
        suppressOffsetPreview = false
        updateEstimate(delay: 0)
    }

    func updateCrop(_ rect: CGRect, for url: URL) {
        let clamped = Self.clampedCropRect(rect)
        switch cropScope {
        case .allImages:
            sharedCropRect = clamped
            perImageCropRects = [:]
        case .thisImageOnly:
            perImageCropRects[url] = clamped
        }
    }

    func openFromFinder(_ urls: [URL], autoQuitWhenDone: Bool) {
        guard let input = Self.openedURLInput(from: urls) else { return }
        open(input)
        if canExport {
            exportAll { success in
                guard success, autoQuitWhenDone else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func open(_ input: OpenedURLInput) {
        switch input {
        case .folder(let url):
            setFolder(url)
        case .images(let urls):
            setImages(urls)
        }
    }

    /// `compressOnly: true` skips watermark compositing entirely (resize/
    /// format/quality/max-size and metadata stripping still apply) -- the
    /// path behind compact mode's "Compress Only" choice when someone taps
    /// Watermark All Images before picking a watermark, so they aren't
    /// blocked from exporting at all. Without it, a nil watermarkURL still
    /// refuses to run, same as before.
    func exportAll(compressOnly: Bool = false, onlySelected: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let watermark = watermarkURL
        guard compressOnly || watermark != nil else {
            completion?(false)
            return
        }
        let items = onlySelected ? selected.map { [$0] } ?? [] : orderedItems
        guard !items.isEmpty else {
            completion?(false)
            return
        }
        isExporting = true
        exportStartedAt = Date()
        exportETAText = ""
        progress = 0
        status = String(format: String(localized: "Exporting 0 of %d..."), items.count)
        let settings = settings
        let sourceFolder = folderURL
        let cropEnabled = cropEnabled
        let sharedCropRect = sharedCropRect
        let perImageCropRects = perImageCropRects
        let numberedOrder = Dictionary(uniqueKeysWithValues: orderedImageURLs.enumerated().map { ($0.element, $0.offset + 1) })
        let numberedCount = numberedCount
        let roomLabels = roomLabels
        Task.detached {
            var summary = ExportSummary(success: 0, failed: [], bytes: 0, usedHEICFallback: false)
            var usedOutputURLs = Set<URL>()
            let watermarkAccess = watermark?.startAccessingSecurityScopedResource() ?? false
            var revealURL: URL?
            var permissionFailedItems: [ImageItem] = []
            defer {
                if watermarkAccess { watermark?.stopAccessingSecurityScopedResource() }
            }
            for (index, item) in items.enumerated() {
                let access = item.url.startAccessingSecurityScopedResource()
                defer { if access { item.url.stopAccessingSecurityScopedResource() } }
                do {
                    let output = item.url.deletingLastPathComponent().appendingPathComponent("Watermarked", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let outputURL = ImageProcessor.uniqueOutputURL(for: item.url, outputFolder: output, settings: settings, order: numberedOrder[item.url], numberedCount: numberedCount, roomLabel: roomLabels[item.url], usedURLs: &usedOutputURLs)
                    let cropRect = cropEnabled ? (perImageCropRects[item.url] ?? sharedCropRect) : .fullFrame
                    let result: (url: URL, bytes: Int, usedHEICFallback: Bool, metSizeTarget: Bool)
                    if compressOnly || watermark == nil {
                        result = try ImageProcessor.compressOnly(sourceURL: item.url, outputURL: outputURL, settings: settings, cropRect: cropRect)
                    } else {
                        result = try ImageProcessor.export(sourceURL: item.url, watermarkURL: watermark!, outputURL: outputURL, settings: settings, cropRect: cropRect)
                    }
                    revealURL = revealURL ?? output
                    summary.success += 1
                    summary.bytes += result.bytes
                    summary.usedHEICFallback = summary.usedHEICFallback || result.usedHEICFallback
                    if !result.metSizeTarget { summary.unmetSizeTarget.append(item.filename) }
                } catch {
                    // Was silently swallowing the real reason -- "Failed:
                    // IMG_1234.jpg" with no cause told nobody anything
                    // (including me) about what actually went wrong.
                    if Self.isPermissionError(error) {
                        // Held back rather than added straight to
                        // summary.failed -- these get one retry to a
                        // customer-chosen folder below, once the whole
                        // pass has finished.
                        permissionFailedItems.append(item)
                    } else {
                        summary.failed.append("\(item.filename) (\(error.localizedDescription))")
                    }
                }
                await MainActor.run {
                    let progress = Double(index + 1) / Double(items.count)
                    self.progress = progress
                    if let exportStartedAt = self.exportStartedAt {
                        self.exportETAText = Self.formatExportETA(elapsed: Date().timeIntervalSince(exportStartedAt), progress: progress)
                    }
                    self.status = String(format: String(localized: "Exporting %d of %d..."), index + 1, items.count)
                }
            }

            // Permission-failure recovery: the folder next to the source
            // images refused the write. Rather than just reporting that,
            // offer a folder picker so the customer can pick/re-authorize a
            // destination, then retry those files there once.
            if !permissionFailedItems.isEmpty {
                let retryFolder = await MainActor.run { self.presentPermissionRecoveryPanel() }
                if let retryFolder {
                    var retryOutputURLs = Set<URL>()
                    for item in permissionFailedItems {
                        let access = item.url.startAccessingSecurityScopedResource()
                        defer { if access { item.url.stopAccessingSecurityScopedResource() } }
                        do {
                            let outputURL = ImageProcessor.uniqueOutputURL(for: item.url, outputFolder: retryFolder, settings: settings, order: numberedOrder[item.url], numberedCount: numberedCount, roomLabel: roomLabels[item.url], usedURLs: &retryOutputURLs)
                            let cropRect = cropEnabled ? (perImageCropRects[item.url] ?? sharedCropRect) : .fullFrame
                            let result: (url: URL, bytes: Int, usedHEICFallback: Bool, metSizeTarget: Bool)
                            if compressOnly || watermark == nil {
                                result = try ImageProcessor.compressOnly(sourceURL: item.url, outputURL: outputURL, settings: settings, cropRect: cropRect)
                            } else {
                                result = try ImageProcessor.export(sourceURL: item.url, watermarkURL: watermark!, outputURL: outputURL, settings: settings, cropRect: cropRect)
                            }
                            revealURL = retryFolder
                            summary.success += 1
                            summary.bytes += result.bytes
                            summary.usedHEICFallback = summary.usedHEICFallback || result.usedHEICFallback
                            if !result.metSizeTarget { summary.unmetSizeTarget.append(item.filename) }
                        } catch {
                            summary.failed.append("\(item.filename) (\(error.localizedDescription))")
                        }
                    }
                } else {
                    // Declined the recovery folder picker -- report those as
                    // ordinary failures rather than dropping them silently.
                    summary.failed += permissionFailedItems.map { "\($0.filename) (no permission to save there)" }
                }
            }

            await MainActor.run {
                if let revealURL {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
                self.isExporting = false
                self.exportStartedAt = nil
                self.exportETAText = ""
                let verb = (compressOnly || watermark == nil) ? String(localized: "compressed") : String(localized: "watermarked")
                var text = String(format: String(localized: "%d of %d images %@, total output size ~%@."), summary.success, items.count, verb, Self.formatBytes(summary.bytes))
                if summary.usedHEICFallback { text += " " + String(localized: "HEIC was exported as PNG.") }
                if !summary.unmetSizeTarget.isEmpty { text += " " + String(format: String(localized: "%d couldn't reach the max file size target and were shipped at their closest achievable size."), summary.unmetSizeTarget.count) }
                if !summary.failed.isEmpty { text += " " + String(format: String(localized: "Failed: %@."), summary.failed.joined(separator: ", ")) }
                self.status = text
                // History is watermark+settings reuse ("redo from history"),
                // so a compress-only run with no watermark has nothing
                // meaningful to record.
                if let watermark {
                    self.recordExportHistory(folder: sourceFolder, watermark: watermark, settings: settings, imageCount: items.count, succeededCount: summary.success)
                }
                let succeeded = summary.success == items.count && summary.failed.isEmpty
                if succeeded {
                    self.showExportCelebration = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        self.showExportCelebration = false
                    }
                }
                // Quick Action prompt is disabled for this release -- pulled
                // per request. The underlying QuickActionPromptView and
                // showQuickActionPrompt plumbing are left intact for a
                // future version; this just removes the trigger, same
                // pattern as Smart Placement earlier.
                completion?(succeeded)
            }
        }
    }

    /// Blocking AppKit alert + folder picker, run synchronously on the main
    /// actor from inside exportAll's MainActor.run hop -- same pattern as
    /// chooseFolderOrImages()/chooseWatermark() using NSOpenPanel.runModal()
    /// directly from a plain action. Returns the chosen folder, tracked via
    /// the existing SecurityScopedAccessTracker (sourceAccess) and bookmarked
    /// the same way every other folder pick in this app is, or nil if the
    /// customer declined.
    private func presentPermissionRecoveryPanel() -> URL? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Can't save to that folder")
        alert.informativeText = String(localized: "WatermarkFactory doesn't have permission to save files there. Choose a folder to save to instead.")
        alert.addButton(withTitle: String(localized: "Choose Folder..."))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        sourceAccess.start(url)
        saveBookmark(url, key: "lastPermissionRecoveryFolderBookmark")
        return url
    }

    /// Matches NSFileWriteNoPermissionError and its POSIX EACCES/EPERM
    /// equivalents, including when wrapped as an NSUnderlyingErrorKey inside
    /// another NSError (how CGImageDestination/FileManager failures often
    /// surface a permission problem).
    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) || nsError.code == Int(EPERM) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    func setOptimizeForWeb(_ value: Bool) {
        optimizeForWeb = value
        if value && exportFormat == .jpeg && jpegQuality > 0.8 {
            jpegQuality = 0.8
        }
    }

    func presetNamed(_ name: String) -> WatermarkPreset? {
        presets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func savePreset(named rawName: String, overwrite: Bool = false) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let watermarkURL,
              let bookmark = bookmarkData(for: watermarkURL) else { return }
        let preset = WatermarkPreset(name: name, watermarkBookmark: bookmark, settings: settings)
        if let index = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            guard overwrite else { return }
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        savePresets()
    }

    func applyPreset(_ preset: WatermarkPreset) {
        watermarkURL = resolveBookmark(preset.watermarkBookmark)
        if let watermarkURL {
            watermarkAccess.replace(with: [watermarkURL])
            saveBookmark(watermarkURL, key: "watermarkBookmark")
        } else {
            watermarkAccess.stopAll()
        }
        apply(preset.settings)
        status = String(format: String(localized: "Loaded preset \"%@\"."), preset.name)
    }

    func deletePreset(_ preset: WatermarkPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    func applyPlatformPreset(_ preset: PlatformExportPreset) {
        outputWidth = preset.width
        outputHeight = preset.height
        exportFormat = .jpeg
        jpegQuality = preset.jpegQuality
        status = String(format: String(localized: "Applied %@ export preset."), preset.name)
    }

    func suggestPlacement() {
        guard let source = selected?.url, let watermark = watermarkURL else { return }
        isSuggestingPlacement = true
        let settings = settings
        let cropRect = activeCropRect(for: source)
        Task.detached {
            let proposal = ImageProcessor.smartPlacementProposal(sourceURL: source, watermarkURL: watermark, settings: settings, cropRect: cropRect)
            await MainActor.run {
                self.smartPlacementProposal = proposal
                self.isSuggestingPlacement = false
                if proposal == nil { self.status = String(localized: "Could not analyze this image for placement.") }
            }
        }
    }

    func classifyRoomsForAllImages() {
        guard !images.isEmpty, !isClassifyingRooms else { return }
        isClassifyingRooms = true
        status = String(localized: "Detecting rooms...")
        let items = images
        Task.detached {
            var labels: [URL: String] = [:]
            for item in items {
                let access = item.url.startAccessingSecurityScopedResource()
                if let label = ImageProcessor.classifyRoom(sourceURL: item.url) {
                    labels[item.url] = label
                }
                if access { item.url.stopAccessingSecurityScopedResource() }
            }
            await MainActor.run {
                let currentURLs = Set(self.images.map(\.url))
                self.roomLabels = labels.filter { currentURLs.contains($0.key) }
                self.isClassifyingRooms = false
                self.status = labels.isEmpty
                    ? String(localized: "No confident room labels found.")
                    : String(format: String(localized: "Detected rooms for %d of %d images."), self.roomLabels.count, self.images.count)
                self.updateEstimate(delay: 0)
            }
        }
    }

    func applySmartPlacement() {
        guard let proposal = smartPlacementProposal else { return }
        anchor = proposal.anchor
        padding = proposal.padding
        offsetX = proposal.offsetX
        offsetY = proposal.offsetY
        watermarkTint = proposal.tint
        smartPlacementProposal = nil
        status = String(localized: "Applied suggested placement.")
    }

    func dismissSmartPlacement() {
        smartPlacementProposal = nil
    }

    private func setFolder(_ url: URL) {
        sourceAccess.replace(with: [url])
        folderURL = url
        saveBookmark(url, key: "folderBookmark")
        recordRecentFolder(url)
        reloadImages()
    }

    /// Selecting a folder from the Recent list -- same path as any other
    /// folder pick, plus a fresh security-scoped resolve from its stored
    /// bookmark (the original picker-granted access doesn't carry over
    /// between launches, only the bookmark does).
    func selectRecentFolder(_ recent: RecentFolder) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            // Bookmark no longer resolves (folder moved/deleted/permission
            // revoked) -- drop it from the list rather than leave a dead
            // entry a person would just hit the same failure on again.
            recentFolders.removeAll { $0.id == recent.id }
            saveRecentFolders()
            return
        }
        setFolder(url)
    }

    private func recordRecentFolder(_ url: URL) {
        guard let bookmark = bookmarkData(for: url) else { return }
        let path = url.path
        recentFolders.removeAll { $0.path == path }
        recentFolders.insert(RecentFolder(name: url.lastPathComponent, path: path, bookmark: bookmark, lastUsed: Date()), at: 0)
        recentFolders = Array(recentFolders.prefix(6))
        saveRecentFolders()
    }

    private func saveRecentFolders() {
        if let data = try? JSONEncoder().encode(recentFolders) {
            defaults.set(data, forKey: "recentFolders")
        }
    }

    /// Same resolve-or-drop pattern as selectRecentFolder above.
    func selectSavedWatermark(_ saved: SavedWatermark) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: saved.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            savedWatermarks.removeAll { $0.id == saved.id }
            saveSavedWatermarks()
            return
        }
        isTextWatermark = false
        setWatermark(url)
    }

    /// Only one favorite at a time -- it's what loads automatically on
    /// next launch (see restore(), below), so more than one would be
    /// ambiguous about which "always launches with this" actually wins.
    func toggleFavoriteWatermark(_ saved: SavedWatermark) {
        let makingFavorite = !saved.isFavorite
        for index in savedWatermarks.indices {
            savedWatermarks[index].isFavorite = makingFavorite && savedWatermarks[index].id == saved.id
        }
        saveSavedWatermarks()
    }

    func removeSavedWatermark(_ saved: SavedWatermark) {
        savedWatermarks.removeAll { $0.id == saved.id }
        saveSavedWatermarks()
    }

    private func recordSavedWatermark(_ url: URL) {
        guard let bookmark = bookmarkData(for: url) else { return }
        let path = url.path
        let wasFavorite = savedWatermarks.first { $0.path == path }?.isFavorite ?? false
        savedWatermarks.removeAll { $0.path == path }
        savedWatermarks.insert(SavedWatermark(name: url.lastPathComponent, path: path, bookmark: bookmark, isFavorite: wasFavorite), at: 0)
        savedWatermarks = Array(savedWatermarks.prefix(12))
        saveSavedWatermarks()
    }

    private func saveSavedWatermarks() {
        if let data = try? JSONEncoder().encode(savedWatermarks) {
            defaults.set(data, forKey: "savedWatermarks")
        }
    }

    private func restoreSavedWatermarks() {
        guard let data = defaults.data(forKey: "savedWatermarks"),
              let decoded = try? JSONDecoder().decode([SavedWatermark].self, from: data) else { return }
        savedWatermarks = decoded
    }

    private func restoreRecentFolders() {
        guard let data = defaults.data(forKey: "recentFolders"),
              let decoded = try? JSONDecoder().decode([RecentFolder].self, from: data) else { return }
        recentFolders = decoded
    }

    /// Records one completed batch, so it can be redone later from its own
    /// untouched original -- "redo with different settings" or "swap in the
    /// new logo" without ever needing to know where the source folder was,
    /// or reprocess an already-watermarked file. Individual-file selections
    /// (no common folder) aren't recorded: there's no single folder to
    /// reload from, and re-picking a handful of loose files by hand isn't
    /// meaningfully harder than re-adding them here.
    private func recordExportHistory(folder: URL?, watermark: URL, settings: WatermarkSettings, imageCount: Int, succeededCount: Int) {
        guard let folder,
              let folderBookmark = bookmarkData(for: folder),
              let watermarkBookmark = bookmarkData(for: watermark) else { return }
        let entry = ExportHistoryEntry(
            folderName: folder.lastPathComponent,
            folderBookmark: folderBookmark,
            watermarkName: watermark.lastPathComponent,
            watermarkBookmark: watermarkBookmark,
            settings: settings,
            imageCount: imageCount,
            succeededCount: succeededCount,
            date: Date()
        )
        exportHistory.insert(entry, at: 0)
        exportHistory = Array(exportHistory.prefix(20))
        saveExportHistory()
    }

    /// Reloads a past batch's source folder, watermark, and settings exactly
    /// as they were -- the normal flow (adjust settings, or pick a different
    /// watermark via Choose Watermark..., then Export) picks up from there,
    /// starting from the untouched original rather than an already-
    /// watermarked file.
    func redoFromHistory(_ entry: ExportHistoryEntry) {
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: entry.folderBookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            status = String(localized: "That folder is no longer available (moved, deleted, or permission revoked).")
            exportHistory.removeAll { $0.id == entry.id }
            saveExportHistory()
            return
        }
        guard let watermark = try? URL(resolvingBookmarkData: entry.watermarkBookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            status = String(localized: "That watermark file is no longer available (moved, deleted, or permission revoked).")
            return
        }
        setFolder(folder)
        setWatermark(watermark)
        apply(entry.settings)
        status = String(format: String(localized: "Reloaded \"%@\" with the settings from that batch. Adjust anything you need, then Watermark All Images."), entry.folderName)
    }

    private func saveExportHistory() {
        if let data = try? JSONEncoder().encode(exportHistory) {
            defaults.set(data, forKey: "exportHistory")
        }
    }

    private func restoreExportHistory() {
        guard let data = defaults.data(forKey: "exportHistory"),
              let decoded = try? JSONDecoder().decode([ExportHistoryEntry].self, from: data) else { return }
        exportHistory = decoded
    }

    private func setImages(_ urls: [URL]) {
        folderURL = nil
        defaults.set(true, forKey: "usedIndividualImages")
        let filtered = urls
            .filter { ImageProcessor.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        sourceAccess.replace(with: filtered)
        images = filtered.map(ImageItem.init)
        roomLabels = roomLabels.filter { filtered.contains($0.key) }
        selected = images.first
        status = images.isEmpty ? String(localized: "No supported images selected.") : String(format: String(localized: "%d images selected."), images.count)
        pruneImageOrder()
        saveImageBookmarks()
        updateEstimate()
    }

    private func setWatermark(_ url: URL) {
        watermarkAccess.replace(with: [url])
        watermarkURL = url
        saveBookmark(url, key: "watermarkBookmark")
        updateEstimate()
    }

    private func apply(_ settings: WatermarkSettings) {
        sizeFraction = settings.sizeFraction
        opacity = settings.opacity
        anchor = settings.anchor
        additionalAnchors = settings.additionalAnchors
        offsetX = settings.offsetX
        offsetY = settings.offsetY
        layoutMode = settings.layoutMode
        padding = settings.padding
        spacing = settings.spacing
        rotationPattern = settings.rotationPattern
        customAngle = settings.customAngle
        exportFormat = settings.exportFormat
        jpegQuality = settings.jpegQuality
        optimizeForWeb = settings.optimizeForWeb
        outputWidth = settings.outputWidth
        outputHeight = settings.outputHeight
        outputPrefix = Self.sanitizedFilenameAffix(settings.outputPrefix)
        outputSuffix = Self.sanitizedFilenameAffix(settings.outputSuffix)
        maxFileSizeKB = settings.maxFileSizeKB
        watermarkTint = settings.watermarkTint
        metadataPrivacy = settings.metadataPrivacy
        removeWatermarkBackground = settings.removeWatermarkBackground
        syncPresetSelections()
        updateEstimate(delay: 0)
    }

    private func reloadImages() {
        guard let folderURL else { return }
        sourceAccess.start(folderURL)
        do {
            defaults.set(false, forKey: "usedIndividualImages")
            let found = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
                .filter { ImageProcessor.supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            sourceAccess.replace(with: [folderURL] + found)
            images = found.map(ImageItem.init)
            roomLabels = roomLabels.filter { found.contains($0.key) }
            selected = images.first
            status = images.isEmpty ? String(localized: "No supported images found in this folder.") : String(format: String(localized: "%d images found."), images.count)
            pruneImageOrder()
            saveImageBookmarks()
            updateEstimate()
        } catch {
            sourceAccess.stopAll()
            images = []
            selected = nil
            pruneImageOrder()
            status = String(localized: "Couldn't access the selected folder. Please re-choose it.")
        }
    }

    private func saveSettings() {
        defaults.set(sizeFraction, forKey: "sizeFraction")
        defaults.set(opacity, forKey: "opacity")
        defaults.set(anchor.rawValue, forKey: "anchor")
        defaults.set(additionalAnchors.map(\.rawValue), forKey: "additionalAnchors")
        defaults.set(offsetX, forKey: "offsetX")
        defaults.set(offsetY, forKey: "offsetY")
        defaults.set(layoutMode.rawValue, forKey: "layoutMode")
        defaults.set(padding, forKey: "padding")
        defaults.set(spacing, forKey: "spacing")
        defaults.set(rotationPattern.rawValue, forKey: "rotationPattern")
        defaults.set(customAngle, forKey: "customAngle")
        defaults.set(exportFormat.rawValue, forKey: "exportFormat")
        defaults.set(jpegQuality, forKey: "jpegQuality")
        defaults.set(optimizeForWeb, forKey: "optimizeForWeb")
        defaults.set(outputWidth, forKey: "outputWidth")
        defaults.set(outputHeight, forKey: "outputHeight")
        defaults.set(outputPrefix, forKey: "outputPrefix")
        defaults.set(outputSuffix, forKey: "outputSuffix")
        defaults.set(maxFileSizeKB, forKey: "maxFileSizeKB")
        defaults.set(watermarkTint.rawValue, forKey: "watermarkTint")
        defaults.set(metadataPrivacy.rawValue, forKey: "metadataPrivacy")
        defaults.set(removeWatermarkBackground, forKey: "removeWatermarkBackground")
        defaults.set(watermarkContrast, forKey: "watermarkContrast")
        defaults.set(textWatermarkFontSize, forKey: "textWatermarkFontSize")
        defaults.set(textWatermarkContent, forKey: "textWatermarkContent")
    }

    private func restore() {
        restorePresets()
        restoreRecentFolders()
        restoreSavedWatermarks()
        restoreExportHistory()
        if defaults.object(forKey: "sizeFraction") != nil { sizeFraction = defaults.double(forKey: "sizeFraction") }
        if defaults.object(forKey: "opacity") != nil { opacity = defaults.double(forKey: "opacity") }
        anchor = Anchor(rawValue: defaults.string(forKey: "anchor") ?? "") ?? .bottomRight
        additionalAnchors = (defaults.array(forKey: "additionalAnchors") as? [String] ?? []).compactMap(Anchor.init(rawValue:))
        offsetX = defaults.object(forKey: "offsetX") == nil ? 24 : defaults.double(forKey: "offsetX")
        offsetY = defaults.object(forKey: "offsetY") == nil ? 24 : defaults.double(forKey: "offsetY")
        layoutMode = LayoutMode(rawValue: defaults.string(forKey: "layoutMode") ?? "") ?? .single
        padding = defaults.object(forKey: "padding") == nil ? 16 : defaults.double(forKey: "padding")
        spacing = defaults.object(forKey: "spacing") == nil ? 80 : defaults.double(forKey: "spacing")
        rotationPattern = RotationPattern(rawValue: defaults.string(forKey: "rotationPattern") ?? "") ?? .none
        customAngle = defaults.object(forKey: "customAngle") == nil ? 30 : defaults.double(forKey: "customAngle")
        exportFormat = ExportFormat(rawValue: defaults.string(forKey: "exportFormat") ?? "") ?? .keepOriginal
        jpegQuality = defaults.object(forKey: "jpegQuality") == nil ? 0.9 : defaults.double(forKey: "jpegQuality")
        optimizeForWeb = defaults.bool(forKey: "optimizeForWeb")
        outputWidth = defaults.object(forKey: "outputWidth") == nil ? 0 : defaults.integer(forKey: "outputWidth")
        outputHeight = defaults.object(forKey: "outputHeight") == nil ? 0 : defaults.integer(forKey: "outputHeight")
        outputPrefix = Self.sanitizedFilenameAffix(defaults.string(forKey: "outputPrefix") ?? "")
        outputSuffix = Self.sanitizedFilenameAffix(defaults.string(forKey: "outputSuffix") ?? "")
        maxFileSizeKB = defaults.object(forKey: "maxFileSizeKB") == nil ? 0 : defaults.integer(forKey: "maxFileSizeKB")
        watermarkTint = WatermarkTint(rawValue: defaults.string(forKey: "watermarkTint") ?? "") ?? .original
        metadataPrivacy = MetadataPrivacyLevel(rawValue: defaults.string(forKey: "metadataPrivacy") ?? "") ?? .removeLocation
        removeWatermarkBackground = defaults.bool(forKey: "removeWatermarkBackground")
        watermarkContrast = defaults.object(forKey: "watermarkContrast") == nil ? 0 : defaults.double(forKey: "watermarkContrast")
        textWatermarkFontSize = defaults.object(forKey: "textWatermarkFontSize") == nil ? 200 : defaults.double(forKey: "textWatermarkFontSize")
        textWatermarkContent = defaults.string(forKey: "textWatermarkContent") ?? ""
        // isTextWatermark isn't persisted directly -- it's true only if the
        // restored watermark is in fact the rendered text-watermark file.
        syncPresetSelections()
        folderURL = restoreBookmark("folderBookmark")
        watermarkURL = restoreBookmark("watermarkBookmark")
        // A favorite watermark always wins over whatever was last used --
        // that's the whole point of marking one as favorite/default.
        if let favorite = savedWatermarks.first(where: \.isFavorite) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: favorite.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                watermarkURL = resolved
            }
        }
        isTextWatermark = watermarkURL == ImageProcessor.textWatermarkURL
        if let watermarkURL {
            watermarkAccess.replace(with: [watermarkURL])
        } else {
            watermarkAccess.stopAll()
        }
        restoreImageOrder()
        let restoredImages = restoreImageBookmarks()
        if restoredImages.isEmpty {
            reloadImages()
        } else {
            if defaults.bool(forKey: "usedIndividualImages") { folderURL = nil }
            sourceAccess.replace(with: (folderURL.map { [$0] } ?? []) + restoredImages)
            images = restoredImages.map(ImageItem.init)
            selected = images.first
            pruneImageOrder()
            status = String(format: String(localized: "%d images restored."), images.count)
            updateEstimate()
        }
    }

    private func saveBookmark(_ url: URL, key: String) {
        if let data = bookmarkData(for: url) {
            defaults.set(data, forKey: key)
        }
    }

    private func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func restoreBookmark(_ key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return resolveBookmark(data)
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: "watermarkPresets")
        }
    }

    private func restorePresets() {
        guard let data = defaults.data(forKey: "watermarkPresets"),
              let decoded = try? JSONDecoder().decode([WatermarkPreset].self, from: data) else { return }
        presets = decoded
    }

    private func saveImageBookmarks() {
        let bookmarks = images.compactMap {
            try? $0.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: "imageBookmarks")
    }

    private func restoreImageBookmarks() -> [URL] {
        guard let bookmarks = defaults.array(forKey: "imageBookmarks") as? [Data] else { return [] }
        return bookmarks.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    private func saveImageOrder() {
        defaults.set(orderedImageURLs.map(\.path), forKey: "orderedImagePaths")
    }

    private func restoreImageOrder() {
        orderedImageURLs = (defaults.array(forKey: "orderedImagePaths") as? [String] ?? []).map(URL.init(fileURLWithPath:))
    }

    private func pruneImageOrder() {
        let urls = Set(images.map(\.url))
        orderedImageURLs = orderedImageURLs.filter { urls.contains($0) }
    }

    static func formatBytes(_ count: Int) -> String {
        let value = Double(count)
        return value >= 1_048_576 ? String(format: "%.1f MB", value / 1_048_576) : String(format: "%.0f KB", value / 1024)
    }

    static func formatExportETA(elapsed: TimeInterval, progress: Double) -> String {
        guard progress > 0, progress < 1 else { return "" }
        let remaining = elapsed * (1 / progress - 1)
        guard remaining >= 1 else { return "" }
        if remaining < 60 {
            let seconds = max(5, Int((remaining / 5).rounded()) * 5)
            return String(format: String(localized: "~%ds left"), seconds)
        }
        let minutes = max(1, Int((remaining / 60).rounded()))
        return String(format: String(localized: "~%dm left"), minutes)
    }

    static func sanitizedFilenameAffix(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "\0", with: "")
    }

    static func clampedCropRect(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 0.1
        let width = min(max(rect.width, minSize), 1)
        let height = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func openedURLInput(from urls: [URL], isDirectory: (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }) -> OpenedURLInput? {
        if let folder = urls.first(where: isDirectory) { return .folder(folder) }
        return urls.isEmpty ? nil : .images(urls)
    }

    private func syncPresetSelections() {
        sizePreset = WatermarkSizePreset.allCases.first { abs($0.value - sizeFraction) < 0.0001 }
        opacityPreset = OpacityPreset.allCases.first { abs($0.value - opacity) < 0.0001 }
    }
}

struct ContentView: View {
    @Environment(\.brandTheme) private var theme

    @ObservedObject private var state: AppState
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var duplicatePresetName = ""
    @State private var showingOverwriteConfirm = false
    @State private var draggingItem: ImageItem?
    @State private var isFileDropTargeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let controlsWidth: CGFloat = 380
    private let imageListWidth: CGFloat = 300
    private let previewMinWidth: CGFloat = 560
    private let spacing: CGFloat = AutomalitySpacing.sm
    private let panePadding: CGFloat = AutomalitySpacing.sm

    // Settings panel is one flat tab, not a stack of collapsible boxes --
    // three tabs, each just the sections that belong together. Crop is
    // dropped for now (not wired into any tab); its underlying state/logic
    // stays untouched, there's just no UI path to turn it on.
    // Export settings moved into the confirmation sheet the Watermark
    // button opens (see exportOptionsSheet) -- only Position/Watermark
    // stay as always-visible tabs.
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case position = "Position"
        case watermark = "Watermark"
        var id: String { rawValue }
    }
    @State private var settingsTab: SettingsTab = .watermark
    @State private var showExportSheet = false
    @State private var showTextWatermarkSheet = false
    @State private var textWatermarkInput = ""
    @State private var showSavedWatermarksSheet = false

    init(state: AppState = .shared) {
        self.state = state
    }

    var body: some View {
        content
        // Must be >= the sum of the three NavigationSplitView columns' own
        // minimums (220 + previewMinWidth(560) + controlsWidth(380) = 1160)
        // -- otherwise the window can open smaller than the panel actually
        // needs, and the settings column gets squeezed past its stated
        // minimum with no clipping, which read as content "overflowing"
        // when it was really the window itself too narrow.
        .frame(minWidth: 1260, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            primaryActionToolbarItem
            globalActionsToolbarItem
        }
        .alert("Watermark not uploaded yet", isPresented: $state.showWatermarkMissingPrompt) {
            Button("Upload Watermark") { state.chooseWatermark() }
            Button("Compress Only") { state.exportAll(compressOnly: true, onlySelected: state.missingWatermarkPromptOnlySelected) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a watermark image to apply, or export the images compressed only, with no watermark.")
        }
        .sheet(isPresented: $isNamingPreset) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Preset").font(.headline)
                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.automality)
                    .onSubmit { submitPresetName() }
                HStack {
                    Spacer()
                    Button("Cancel") { isNamingPreset = false }
                    Button("Save") { submitPresetName() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(width: 320)
        }
        .alert("Overwrite preset?", isPresented: $showingOverwriteConfirm) {
            Button("Overwrite", role: .destructive) {
                state.savePreset(named: duplicatePresetName, overwrite: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "A preset named \"%@\" already exists."), duplicatePresetName))
        }
        .sheet(isPresented: $state.showQuickActionPrompt) {
            QuickActionPromptView(isPresented: $state.showQuickActionPrompt)
        }
        .sheet(isPresented: $showExportSheet) {
            exportOptionsSheet
        }
        .sheet(isPresented: $showTextWatermarkSheet) {
            textWatermarkSheet
        }
        .sheet(isPresented: $showSavedWatermarksSheet) {
            savedWatermarksSheet
        }
    }

    private var savedWatermarksSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Previous Watermarks").font(.headline)
            Text("Pick one to use now, or mark your default with the star -- the default loads automatically every time you open the app.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(state.savedWatermarks) { saved in
                        HStack(spacing: 10) {
                            Thumb(url: URL(fileURLWithPath: saved.path), size: 40)
                            Text(saved.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                state.toggleFavoriteWatermark(saved)
                            } label: {
                                Image(systemName: saved.isFavorite ? "star.fill" : "star")
                                    .foregroundStyle(saved.isFavorite ? Color.orange : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Default watermark -- loads automatically on launch")
                            Button {
                                state.removeSavedWatermark(saved)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectSavedWatermark(saved)
                            showSavedWatermarksSheet = false
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Done") { showSavedWatermarksSheet = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var textWatermarkSheet: some View {
        let looksLikePhone = ImageProcessor.looksLikePhoneNumber(textWatermarkInput)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Create My Watermark").font(.headline)
            Text("Type a name or label to use as your watermark instead of an image.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            TextField("e.g. Jane Smith Realty", text: $textWatermarkInput)
                .textFieldStyle(.roundedBorder)
            if looksLikePhone {
                Label("This looks like it includes a phone number. Many real estate portals prohibit contact info embedded in watermarks — check your portal's rules before using it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            HStack {
                Button("Cancel", role: .cancel) { showTextWatermarkSheet = false }
                Spacer()
                Button(looksLikePhone ? "Use Anyway" : "Use This Watermark") {
                    state.createTextWatermark(textWatermarkInput)
                    showTextWatermarkSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(textWatermarkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var exportOptionsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Options").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    exportSectionBody
                    Divider()
                    groupHeader("Order & Rename")
                    orderRenameSectionBody
                }
            }
            .frame(maxHeight: 380)
            HStack {
                Button("Cancel", role: .cancel) { showExportSheet = false }
                Spacer()
                Button("Watermark 1") {
                    showExportSheet = false
                    state.watermarkSelectedTapped()
                }
                .buttonStyle(.bordered)
                .disabled(!state.canTapWatermarkSelected)
                Button("Watermark All (\(state.images.count))") {
                    showExportSheet = false
                    state.watermarkAllTapped()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canTapWatermarkAll)
            }
        }
        .padding()
        .frame(width: 460)
    }

    // No modes, no wizard: images loaded -> the always-visible three-column
    // layout (thumbnails / preview / settings). No images yet -> a single
    // drag-and-drop / click-to-browse empty state fills the window.
    @ViewBuilder
    private var content: some View {
        if state.images.isEmpty {
            emptyStateView
        } else {
            mainContent
        }
    }

    private var primaryActionToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if state.isExporting {
                    GlowingProgressBar(progress: state.progress)
                        .frame(width: 120)
                    if !state.exportETAText.isEmpty {
                        Text(state.exportETAText)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                // The scope choice (this one vs. all) and the export
                // settings both live in the confirmation sheet now -- this
                // button just opens it.
                Button("Watermark...") { showExportSheet = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canTapWatermarkAll)
            }
        }
    }

    private var globalActionsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                if !state.recentFolders.isEmpty {
                    Section("Recent Folders") {
                        ForEach(state.recentFolders) { recent in
                            Button(recent.name) { state.selectRecentFolder(recent) }
                        }
                    }
                }
                if !state.exportHistory.isEmpty {
                    Section("Past Batches") {
                        ForEach(state.exportHistory) { entry in
                            Button("\(entry.folderName) \u{2190} \(entry.watermarkName)") { state.redoFromHistory(entry) }
                        }
                    }
                }
                if !state.presets.isEmpty {
                    Section("Presets") {
                        ForEach(state.presets) { preset in
                            Button(preset.name) { state.applyPreset(preset) }
                        }
                    }
                }
                Divider()
                Button("Save Current as Preset...") {
                    presetName = ""
                    isNamingPreset = true
                }
                .disabled(!state.canSavePreset)
                Divider()
                Button("Preferences...") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Recent, Presets, and Preferences")
        }
    }

    @ViewBuilder
    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.secondary)
    }

    // Icon + label + trailing control, one row -- the settings-list layout
    // pattern (System Settings, Accessibility Inspector) rather than a
    // header-above-control stack. Used for Appearance/Text Size/Contrast.
    @ViewBuilder
    private func settingsRow<Trailing: View>(icon: String, label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.secondary)
                .frame(width: 20)
            Text(label)
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func tabBody(_ tab: SettingsTab) -> some View {
        switch tab {
        case .position:
            groupHeader("Layout Mode")
            layoutModeSectionBody
            Divider()
            groupHeader("Position & Padding")
            positionPaddingSectionBody
        case .watermark:
            groupHeader("Watermark Source")
            watermarkSourceSectionBody
            Divider()
            groupHeader("Size & Opacity")
            sizeOpacitySectionBody
        }
    }

    // Apple's own three-column layout primitive (same pattern as Mail/Photos/
    // Xcode: sidebar/content/detail) rather than a hand-rolled HStack of
    // fixed-width panes with manual Dividers -- resizable/collapsible panes
    // come for free instead of being built here.
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            imageList
                .navigationSplitViewColumnWidth(min: 220, ideal: imageListWidth, max: 340)
        } content: {
            previewPane
                .navigationSplitViewColumnWidth(min: previewMinWidth, ideal: previewMinWidth + 140)
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $settingsTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(panePadding)
                Divider()
                // Plain ScrollView, not BrandScrollBar -- this panel is short
                // now that it's trimmed down, and BrandScrollBar's NSScrollView
                // bridge doesn't report an intrinsic height to SwiftUI, which
                // let it collapse and paint over the tab picker above it.
                ScrollView {
                    VStack(alignment: .leading, spacing: spacing) {
                        tabBody(settingsTab)
                    }
                    .padding(.horizontal, panePadding)
                    .padding(.top, panePadding)
                    .padding(.bottom, panePadding)
                    // Plain ScrollView doesn't pin its content's width the way
                    // BrandScrollBar's NSLayoutConstraint did -- without this,
                    // a wide child (e.g. a long trailing label) can push the
                    // whole row past the column edge instead of wrapping/
                    // clipping inside it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Wider floor than before (content was overflowing at 360) and no
            // tight ceiling -- the divider drags freely so long text/labels
            // always have somewhere to go instead of clipping.
            .navigationSplitViewColumnWidth(min: controlsWidth, ideal: controlsWidth, max: 640)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            FlowLayout {
                Button("Choose Folder or Images...") { state.chooseFolderOrImages() }
                    .buttonStyle(.bordered)
            }
            Text("...or drag a folder or images in")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same dispatch as the Choose Folder or Images button and the
        // Finder Quick Action (AppState.addDroppedURLs -> openedURLInput ->
        // open(_:)) -- one rule everywhere for "what does dropping a mix of
        // folders/files actually mean", not three different ones.
        .dropDestination(for: URL.self) { urls, _ in
            state.addDroppedURLs(urls)
            return true
        } isTargeted: { targeted in
            isFileDropTargeted = targeted
        }
        .background(isFileDropTargeted ? theme.primary.opacity(0.12) : Color.clear)
        .animation(.easeOut(duration: 0.15), value: isFileDropTargeted)
    }

    private var imageList: some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 8) {
                ForEach(state.images) { item in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Thumb(url: item.url, size: 88)
                            if state.hasWatermarkedOutput(for: item) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.primary)
                                    .background(Circle().fill(.white))
                                    .offset(x: 4, y: -4)
                            }
                        }
                        Text(item.filename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(Color.primary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(state.selected == item ? theme.primary.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { state.select(item) }
                }
            }
            .padding(panePadding)
        }
        // Same dispatch as the Choose Folder or Images button and the
        // Finder Quick Action (AppState.addDroppedURLs -> openedURLInput ->
        // open(_:)) -- one rule everywhere for "what does dropping a mix of
        // folders/files actually mean", not three different ones.
        .dropDestination(for: URL.self) { urls, _ in
            state.addDroppedURLs(urls)
            return true
        } isTargeted: { targeted in
            isFileDropTargeted = targeted
        }
        .background(isFileDropTargeted ? theme.primary.opacity(0.12) : Color.clear)
        .animation(.easeOut(duration: 0.15), value: isFileDropTargeted)
    }

    private var previewPane: some View {
        VStack(spacing: spacing) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image = state.previewImage {
                    WatermarkPreview(image: image, state: state)
                } else {
                    Text("Select an image to preview.")
                        .font(.title3)
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().stroke(Color.primary.opacity(0.2)))
            .overlay(alignment: .top) {
                if state.isDemoPreview {
                    Text("Previewing with Automality's mark — choose your own watermark to replace it")
                        .font(.caption)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, AutomalitySpacing.sm)
                        .padding(.vertical, 6)
                        .background(theme.primaryDeep.opacity(0.85))
                }
            }
            .overlay {
                if state.showExportCelebration {
                    ConfettiView()
                }
            }
            .clipped()
            // Thumbnail selection lives in the sidebar (imageList) -- this
            // pane doesn't need its own duplicate strip.
            // Status bar removed (2026-09-08, Felipe) -- export
            // failures/permission issues already surface via the
            // permission-retry alert; progress already shows in the
            // toolbar's GlowingProgressBar during export.
        }
        .frame(minWidth: previewMinWidth)
    }

    @ViewBuilder
    private var watermarkSourceSectionBody: some View {
        HStack(spacing: 12) {
            // Prominent until a watermark is picked -- it's the one thing
            // blocking a real export -- then reverts to a plain bordered
            // button once set. (SwiftUI's bordered/borderedProminent are
            // different concrete types, so the style itself still needs an
            // if/else -- but the button's label/action is written once.)
            let chooseWatermarkButton = Button("Choose Watermark...") { state.chooseWatermark() }
            if state.watermarkURL == nil {
                chooseWatermarkButton.buttonStyle(.borderedProminent)
            } else {
                chooseWatermarkButton.buttonStyle(.bordered)
            }
            Button("Create My Watermark...") {
                textWatermarkInput = ""
                showTextWatermarkSheet = true
            }
            .buttonStyle(.bordered)
            Button("Previous...") { showSavedWatermarksSheet = true }
                .buttonStyle(.bordered)
                .disabled(state.savedWatermarks.isEmpty)
            Spacer()
            if let url = state.watermarkURL { Thumb(url: url, size: 56) }
        }
        // Alternating rows is tiling-only -- same reasoning as Rotation's
        // own mode-filtered picker (see rotationControls).
        let availableTints = state.layoutMode == .single
            ? WatermarkTint.allCases.filter { $0 != .alternating }
            : WatermarkTint.allCases
        settingsRow(icon: state.watermarkTint.icon, label: "Appearance") {
            Picker("Appearance", selection: $state.watermarkTint) {
                ForEach(availableTints) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        // For watermarks that weren't prepared as a proper transparent
        // PNG (a flat-color-filled square exported straight from a
        // design tool, say) -- strips a solid/near-solid background at
        // export time instead of forcing the user to fix the source
        // file by hand. Off by default: an intentionally-opaque
        // watermark (a solid badge, a colored banner) shouldn't lose
        // its background just because this exists.
        Toggle("Remove watermark background", isOn: $state.removeWatermarkBackground)
            .toggleStyle(.automality)
        if state.isTextWatermark {
            settingsRow(icon: "textformat.size", label: "Text Size") {
                Slider(value: $state.textWatermarkFontSize, in: 50...400)
                    .frame(width: 120)
            }
        }
        settingsRow(icon: "circle.righthalf.filled", label: "Contrast") {
            Slider(value: $state.watermarkContrast, in: 0...1)
                .frame(width: 120)
        }
        // Smart Placement ("Suggest Placement") is disabled for this
        // release — the suggestions weren't reliable enough yet. The
        // underlying logic (AppState.suggestPlacement, SmartPlacementProposal)
        // is left intact for a future version; this just removes the UI
        // entry point.
    }

    // Crop UI removed for now (2026-09-08, Felipe) -- no tab surfaces it.
    // Underlying state (cropEnabled/cropScope/crop rects) and CropOverlay
    // stay in place, just unreachable, in case it comes back later.

    @ViewBuilder
    private var sizeOpacitySectionBody: some View {
        presetSection("Size", presets: WatermarkSizePreset.allCases, selected: state.sizePreset?.id, valueText: state.sizePreset?.label ?? "Custom") { preset in
            state.sizePreset = preset
            state.sizeFraction = preset.value
        }
        AutomalitySlider(value: Binding(get: { state.sizeFraction }, set: { state.sizePreset = nil; state.sizeFraction = $0 }), in: 0.05...1.0)
        Text("\(Int(state.sizeFraction * 100))%").font(.caption).foregroundStyle(Color.secondary)
        Divider()
        presetSection("Opacity", presets: OpacityPreset.allCases, selected: state.opacityPreset?.id, valueText: state.opacityPreset?.label ?? "Custom") { preset in
            state.opacityPreset = preset
            state.opacity = preset.value
        }
        AutomalitySlider(value: Binding(get: { state.opacity }, set: { state.opacityPreset = nil; state.opacity = $0 }), in: 0...1)
        Text("\(Int(state.opacity * 100))%").font(.caption).foregroundStyle(Color.secondary)
    }

    @ViewBuilder
    private var layoutModeSectionBody: some View {
        Picker("Layout mode", selection: $state.layoutMode) {
            ForEach(LayoutMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // Every field stays on screen and in the same order regardless of
    // Single vs. Tiled -- only which ones are enabled changes. Switching
    // modes used to swap in a completely different set of controls
    // (anchor grid vs. spacing/rotation), which reflowed the whole panel
    // every time; disabling instead of hiding keeps the layout stable.
    @ViewBuilder
    private var positionPaddingSectionBody: some View {
        groupHeader("Anchor")
        singleControls
            .disabled(state.layoutMode != .single)
            .opacity(state.layoutMode == .single ? 1 : 0.4)
        groupHeader("Padding")
        AutomalitySlider(value: $state.padding, in: 0...100)
        Text("\(Int(state.padding)) px").font(.caption).foregroundStyle(Color.secondary)
        Divider()
        groupHeader("Rotation")
        rotationControls
        Divider()
        groupHeader("Spacing")
        tiledControls
            .disabled(state.layoutMode != .tiled)
            .opacity(state.layoutMode == .tiled ? 1 : 0.4)
    }

    @ViewBuilder
    private var exportSectionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optimize").automalityLabelText().foregroundStyle(Color.primary)
            Picker("Export format", selection: $state.exportFormat) {
                ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if state.exportFormat == .jpeg {
                AutomalitySlider(value: $state.jpegQuality, in: 0...1)
                Text(String(format: String(localized: "JPEG quality %d%%"), Int(state.jpegQuality * 100))).font(.caption).foregroundStyle(Color.secondary)
            }
            Toggle("Optimize for Web", isOn: Binding(get: { state.optimizeForWeb }, set: { state.setOptimizeForWeb($0) }))
                .toggleStyle(.automality)
            Text(state.exportFormat.hint).font(.caption).foregroundStyle(Color.secondary)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            // Original/hidden metadata (camera make, maker notes, AI-
            // provenance descriptions, embedded thumbnails, author fields)
            // is already always removed. GPS is the one field that's a
            // genuine choice, so keep this control prominent.
            Text("Location metadata")
                .font(.headline)
                .foregroundStyle(Color.primary)
            Picker("Location metadata", selection: $state.metadataPrivacy) {
                ForEach(MetadataPrivacyLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(state.metadataPrivacy == .removeLocation ? "Removed from exported images" : "Kept in exported images")
                .font(.caption)
                .foregroundStyle(state.metadataPrivacy == .removeLocation ? Color.secondary : Color.orange)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Save & Rename").automalityLabelText().foregroundStyle(Color.primary)
            HStack(spacing: 8) {
                TextField("Prefix", text: Binding(get: { state.outputPrefix }, set: { state.outputPrefix = AppState.sanitizedFilenameAffix($0) }))
                    .textFieldStyle(.automality)
                TextField("Suffix", text: Binding(get: { state.outputSuffix }, set: { state.outputSuffix = AppState.sanitizedFilenameAffix($0) }))
                    .textFieldStyle(.automality)
            }
            if !state.estimatedFilename.isEmpty {
                Text(String(format: String(localized: "-> %@"), state.estimatedFilename)).font(.caption).foregroundStyle(Color.secondary)
            }
        }
        CollapsibleControlSection("Advanced", startExpanded: false) {
            HStack(spacing: 8) {
                TextField("Width", value: $state.outputWidth, format: .number)
                    .textFieldStyle(.automalityData)
                TextField("Height", value: $state.outputHeight, format: .number)
                    .textFieldStyle(.automalityData)
            }
            Text(state.outputWidth > 0 && state.outputHeight > 0 ? String(format: String(localized: "Output size %d×%d px"), state.outputWidth, state.outputHeight) : String(localized: "Output size original")).font(.caption).foregroundStyle(Color.secondary)
            HStack(spacing: 8) {
                Text("Max file size")
                TextField("Off", value: $state.maxFileSizeKB, format: .number)
                    .textFieldStyle(.automalityData)
                    .frame(width: 70)
                Text("KB").foregroundStyle(Color.secondary)
            }
            if state.maxFileSizeBlocksExport {
                Text("Max file size requires JPEG — switch format or clear this limit.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            } else if state.maxFileSizeKB > 0 {
                Text(String(format: String(localized: "Quality (and, if needed, dimensions) will be reduced to fit ~%d KB per image."), state.maxFileSizeKB))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        if !state.estimatedSize.isEmpty {
            Text(String(format: String(localized: "Estimated output size %@"), state.estimatedSize)).font(.caption)
        }
        // The action itself moved to the top-right header (always
        // visible, orange when ready) -- this hint/progress stays here,
        // next to the settings it's actually explaining.
        if let hint = state.exportHint { Text(hint).font(.caption).foregroundStyle(Color.secondary) }
        if state.isExporting {
            GlowingProgressBar(progress: state.progress)
            if !state.exportETAText.isEmpty {
                Text(state.exportETAText)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var orderRenameSectionBody: some View {
        VStack(alignment: .leading, spacing: AutomalitySpacing.sm) {
            orderRenameHeader
            orderGrid(minimumTileWidth: 96)
                .frame(minHeight: 180, maxHeight: 320)
        }
    }

    private var orderRenameHeader: some View {
        VStack(alignment: .leading, spacing: AutomalitySpacing.sm) {
            Text(state.orderSummary)
                .font(.headline)
                .foregroundStyle(Color.primary)
            FlowLayout {
                Button("Clear order") { state.clearOrder() }
                    .buttonStyle(.bordered)
                    .disabled(state.numberedCount == 0)
                Button("Number in current order") { state.numberInCurrentOrder(state.orderedItems) }
                    .buttonStyle(.bordered)
                    .disabled(state.images.isEmpty)
                Button(state.isClassifyingRooms ? "Detecting Rooms..." : "Auto-name by Room") { state.classifyRoomsForAllImages() }
                    .buttonStyle(.plain)
                    .disabled(state.images.isEmpty || state.isClassifyingRooms)
            }
        }
    }

    private func orderGrid(minimumTileWidth: CGFloat) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: AutomalitySpacing.sm)], spacing: AutomalitySpacing.sm) {
                ForEach(state.orderedItems) { item in
                    orderTile(item)
                }
            }
            .padding(.trailing, AutomalitySpacing.hardShadow)
            .padding(.bottom, AutomalitySpacing.hardShadow)
        }
    }

    private func orderTile(_ item: ImageItem) -> some View {
        let number = state.orderNumber(for: item)
        let roomLabel = state.roomLabels[item.url]
        let outputName = ImageProcessor.outputFilename(for: item.url, settings: state.settings, order: number, numberedCount: state.numberedCount, roomLabel: roomLabel)
        return VStack(alignment: .leading, spacing: AutomalitySpacing.xs) {
            ZStack(alignment: .topLeading) {
                Thumb(url: item.url, size: 128)
                    .opacity(number == nil ? 0.45 : 1)
                if let number {
                    Text("\(number)")
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, AutomalitySpacing.xs)
                        .padding(.vertical, 4)
                        .background(theme.primary)
                        .overlay(Rectangle().stroke(Color.primary, lineWidth: 2))
                        .padding(AutomalitySpacing.xs)
                    }
            }
            if let roomLabel {
                Text(roomLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
            }
            Text(item.filename)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .frame(width: 128, alignment: .leading)
            if roomLabel != nil {
                Text(outputName)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .frame(width: 128, alignment: .leading)
            }
        }
        .padding(AutomalitySpacing.xs)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().stroke(number == nil ? Color.secondary.opacity(0.35) : Color.primary, lineWidth: 2))
        .onTapGesture { state.toggleOrder(for: item) }
        .onDrag {
            draggingItem = item
            return NSItemProvider(object: item.url.path as NSString)
        }
        .onDrop(of: [UTType.text], delegate: ImageOrderDropDelegate(item: item, draggingItem: $draggingItem, state: state))
    }

    private func submitPresetName() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isNamingPreset = false
        if state.presetNamed(name) != nil {
            duplicatePresetName = name
            showingOverwriteConfirm = true
        } else {
            state.savePreset(named: name)
        }
    }

    private static let nudgeStep: Double = 8
    private static let nudgeStepLarge: Double = 32

    private func nudgeButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.caption).frame(width: 22, height: 20)
        }
        .buttonStyle(.automalityChip(isSelected: false))
    }

    // Four buttons, not eight -- Shift-click for the larger step is the
    // standard macOS nudge convention (same as arrow keys in Photoshop/
    // Figma/Sketch: normal = 1 unit, Shift = a bigger jump), so "single
    // step vs. further" doesn't need a second row of icons to discover.
    private func nudgeDirectionButton(_ systemName: String, small: @escaping () -> Void, large: @escaping () -> Void) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.shift) { large() } else { small() }
        } label: {
            Image(systemName: systemName).font(.caption).frame(width: 22, height: 20)
        }
        .buttonStyle(.automalityChip(isSelected: false))
    }

    private var singleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 3), spacing: 4) {
                ForEach(Anchor.allCases) { anchor in
                    Button { state.anchor = anchor } label: {
                        Image(systemName: anchor.symbol).font(.caption).frame(width: 22, height: 20)
                    }
                    .buttonStyle(.automalityChip(isSelected: state.anchor == anchor))
                }
            }
            // Answers "where is the anchor" directly, in words, instead of
            // making you decode the arrow icon in the grid above.
            Text("Anchor: \(state.anchor.displayName.capitalized)")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text("Precise Position").font(.caption).foregroundStyle(Color.secondary)
            // Arrow buttons, not X/Y number fields -- each one nudges in
            // the literal screen direction it points, so there's no sign
            // to interpret (the old fields meant opposite things depending
            // on which corner was anchored: negative X nudged "inward" from
            // the right edge but "outward" from the left edge).
            // offsetY's sign is inverted relative to what "up"/"down" read
            // as on screen (confirmed live, not just from the rect() math)
            // -- the up button subtracts, the down button adds.
            VStack(spacing: 4) {
                nudgeDirectionButton("chevron.up",
                    small: { state.offsetY -= Self.nudgeStep },
                    large: { state.offsetY -= Self.nudgeStepLarge })
                HStack(spacing: 4) {
                    nudgeDirectionButton("chevron.left",
                        small: { state.offsetX -= Self.nudgeStep },
                        large: { state.offsetX -= Self.nudgeStepLarge })
                    nudgeButton("arrow.counterclockwise") { state.offsetX = 0; state.offsetY = 0 }
                        .help("Reset nudge")
                    nudgeDirectionButton("chevron.right",
                        small: { state.offsetX += Self.nudgeStep },
                        large: { state.offsetX += Self.nudgeStepLarge })
                }
                nudgeDirectionButton("chevron.down",
                    small: { state.offsetY += Self.nudgeStep },
                    large: { state.offsetY += Self.nudgeStepLarge })
            }
            Text("Hold Shift to move further").font(.caption2).foregroundStyle(Color.secondary)
        }
    }

    // Spacing (gap between tiles) only means something when tiled.
    private var tiledControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutomalitySlider(value: $state.spacing, in: 0...400)
            Text("\(Int(state.spacing)) px").font(.caption).foregroundStyle(Color.secondary)
        }
    }

    // Rotation applies to a single watermark exactly as much as a tiled
    // one -- ImageProcessor.drawSingleWatermark reads the same
    // rotationPattern/customAngle as drawTiles does. Unlike Spacing, this
    // stays enabled in both Single and Tiled -- but the choices differ:
    // "Alternating rows" is a tiling-only concept (nothing to alternate
    // between with one mark), so Single only offers angle presets + Custom.
    private var rotationControls: some View {
        let availablePatterns = state.layoutMode == .single
            ? RotationPattern.allCases.filter { $0 != .alternating }
            : RotationPattern.allCases
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Rotation", selection: $state.rotationPattern) {
                ForEach(availablePatterns) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            if state.rotationPattern == .custom {
                TextField("Degrees", value: $state.customAngle, format: .number)
                    .textFieldStyle(.automalityData)
                    .frame(width: 90)
            }
        }
    }

    private func presetSection<P: Identifiable>(_ title: String, presets: [P], selected: P.ID?, valueText: String, action: @escaping (P) -> Void) -> some View where P.ID == String {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                // `.frame(maxWidth: .infinity)` (tried earlier) sets an
                // upper bound of infinite -- it caps nothing. An actual
                // numeric width is what forces this to truncate instead of
                // pushing the row wider than its container.
                Text(valueText).font(.caption).foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            // A single aligned row, ordered smallest-to-largest / least-to-most,
            // each chip a short label with a small icon swatch that previews
            // what that tier actually looks like (scaled size, or scaled
            // opacity) — not just decoration.
            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    Button {
                        action(preset)
                    } label: {
                        VStack(spacing: 3) {
                            swatch(for: preset)
                            Text(shortLabel(for: preset))
                        }
                    }
                    .buttonStyle(.automalityChip(isSelected: selected == preset.id))
                    .help(label(for: preset))
                }
            }
        }
    }

    private func label<P>(for preset: P) -> String {
        if let preset = preset as? WatermarkSizePreset { return preset.label }
        if let preset = preset as? OpacityPreset { return preset.label }
        return ""
    }

    private func shortLabel<P>(for preset: P) -> String {
        if let preset = preset as? WatermarkSizePreset { return preset.shortLabel }
        if let preset = preset as? OpacityPreset { return preset.shortLabel }
        return ""
    }

    @ViewBuilder
    private func swatch<P>(for preset: P) -> some View {
        if let preset = preset as? WatermarkSizePreset {
            // Size: the swatch itself scales from small to large across tiers.
            let side: CGFloat = 6 + CGFloat(WatermarkSizePreset.allCases.firstIndex(of: preset) ?? 0) * 2.5
            Rectangle()
                .fill(Color.primary)
                .frame(width: side, height: side)
                .frame(width: 16, height: 16)
        } else if let preset = preset as? OpacityPreset {
            // Opacity: a fixed-size swatch whose fill opacity previews the tier.
            Rectangle()
                .fill(Color.primary.opacity(preset.value))
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: 16, height: 16)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

struct GlowingProgressBar: View {
    @Environment(\.brandTheme) private var theme

    let progress: Double
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AutomalityColor.gray100)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(4, geo.size.width * min(max(progress, 0), 1)))
                    .shadow(color: theme.accent.opacity(pulse ? 0.85 : 0.35), radius: pulse ? 8 : 3)
            }
        }
        .frame(height: 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct ConfettiView: View {
    @Environment(\.brandTheme) private var theme

    private struct Piece: Identifiable {
        let id = UUID()
        let paletteIndex: Int
        let startX: CGFloat
        let delay: Double
        let duration: Double
        let rotation: Double
        let size: CGFloat
    }

    private let pieces: [Piece] = (0..<36).map { _ in
        Piece(
            paletteIndex: Int.random(in: 0..<4),
            startX: .random(in: 0...1),
            delay: .random(in: 0...0.3),
            duration: .random(in: 1.1...1.8),
            rotation: .random(in: 0...360),
            size: .random(in: 5...9)
        )
    }
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    Rectangle()
                        .fill(color(for: piece.paletteIndex))
                        .frame(width: piece.size, height: piece.size * 0.4)
                        .rotationEffect(.degrees(animate ? piece.rotation + 180 : piece.rotation))
                        .position(x: piece.startX * geo.size.width, y: animate ? geo.size.height + 20 : -20)
                        .opacity(animate ? 0 : 1)
                        .animation(.easeIn(duration: piece.duration).delay(piece.delay), value: animate)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    private func color(for index: Int) -> Color {
        [theme.accent, theme.accent.opacity(0.75), theme.primary, theme.primary.opacity(0.75)][index]
    }
}

struct CollapsibleControlSection<Content: View>: View {
    @Environment(\.brandTheme) private var theme

    let title: String
    @State private var isExpanded: Bool
    @ViewBuilder var content: Content

    init(_ title: String, startExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = String(localized: String.LocalizationValue(title))
        self._isExpanded = State(initialValue: startExpanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.primary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    if !isExpanded {
                        Text(String(localized: "Expand"))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if isExpanded {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
    }
}

struct ImageOrderDropDelegate: DropDelegate {
    let item: ImageItem
    @Binding var draggingItem: ImageItem?
    let state: AppState

    func dropEntered(info: DropInfo) {
        guard let draggingItem else { return }
        state.moveOrder(from: draggingItem, to: item)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        return true
    }
}

struct WatermarkPreview: View {
    @Environment(\.brandTheme) private var theme

    let image: NSImage
    @ObservedObject var state: AppState
    @State private var dragStart: CGPoint?
    private let padding: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(padding)
                if state.cropEnabled, let source = state.selected?.url, let sourceSize = state.sourceImageSize {
                    CropOverlay(
                        cropRect: state.effectiveCropRect(for: source),
                        sourceSize: sourceSize,
                        containerSize: proxy.size,
                        padding: padding
                    ) { rect in
                        state.updateCrop(rect, for: source)
                    }
                }
                if let rect = displayedWatermarkRect(in: proxy.size) {
                    Rectangle()
                        .fill(.clear)
                        .overlay(
                            Rectangle()
                                .stroke(theme.primary.opacity(dragStart == nil ? 0.25 : 0.8), lineWidth: dragStart == nil ? 1 : 2)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .onHover { hovering in (hovering ? NSCursor.openHand : NSCursor.arrow).set() }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = dragStart ?? CGPoint(x: state.offsetX, y: state.offsetY)
                                    dragStart = start
                                    NSCursor.closedHand.set()
                                    state.dragWatermark(startX: Double(start.x), startY: Double(start.y), delta: value.translation, displayScale: displayScale(in: proxy.size))
                                }
                                .onEnded { _ in
                                    dragStart = nil
                                    NSCursor.openHand.set()
                                }
                        )
                }
                if let rect = displayedProposalRect(in: proxy.size) {
                    Rectangle()
                        .fill(theme.primary.opacity(0.08))
                        .overlay(
                            Rectangle()
                                .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private func displayedWatermarkRect(in size: CGSize) -> CGRect? {
        displayedWatermarkRect(in: size, settings: state.settings)
    }

    private func displayedProposalRect(in size: CGSize) -> CGRect? {
        guard let proposal = state.smartPlacementProposal else { return nil }
        var settings = state.settings
        settings.anchor = proposal.anchor
        settings.padding = proposal.padding
        settings.offsetX = proposal.offsetX
        settings.offsetY = proposal.offsetY
        return displayedWatermarkRect(in: size, settings: settings)
    }

    private func displayedWatermarkRect(in size: CGSize, settings: WatermarkSettings) -> CGRect? {
        guard state.layoutMode == .single,
              let sourceSize = state.sourceImageSize,
              let watermarkSize = state.watermarkImageSize else { return nil }
        let cropRect = state.selected.map { state.activeCropRect(for: $0.url) } ?? .fullFrame
        let canvasSize = CGSize(width: sourceSize.width * cropRect.width, height: sourceSize.height * cropRect.height)
        let scale = displayScale(in: size)
        guard scale > 0 else { return nil }
        let imageSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        let origin = CGPoint(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2)
        let frame = ImageProcessor.watermarkFrame(sourceSize: canvasSize, watermarkSize: watermarkSize, settings: settings)
        return CGRect(
            x: origin.x + frame.minX * scale,
            y: origin.y + (canvasSize.height - frame.maxY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func displayScale(in size: CGSize) -> CGFloat {
        guard let sourceSize = state.sourceImageSize, sourceSize.width > 0, sourceSize.height > 0 else { return 0 }
        let cropRect = state.selected.map { state.activeCropRect(for: $0.url) } ?? .fullFrame
        let canvasSize = CGSize(width: sourceSize.width * cropRect.width, height: sourceSize.height * cropRect.height)
        let available = CGSize(width: max(0, size.width - padding * 2), height: max(0, size.height - padding * 2))
        return min(available.width / canvasSize.width, available.height / canvasSize.height)
    }
}

struct CropOverlay: View {
    @Environment(\.brandTheme) private var theme

    let cropRect: CGRect
    let sourceSize: CGSize
    let containerSize: CGSize
    let padding: CGFloat
    let onCommit: (CGRect) -> Void
    @State private var draftRect: CGRect?
    @State private var dragStart: CGRect?

    enum Hit: Hashable {
        case move, topLeft, topRight, bottomLeft, bottomRight
    }

    private let handleSize: CGFloat = 44
    private let bracketLength: CGFloat = 30
    private let bracketWidth: CGFloat = 6

    var body: some View {
        let current = draftRect ?? cropRect
        let imageRect = imageRect()
        let displayRect = displayRect(for: current, in: imageRect)
        ZStack(alignment: .topLeading) {
            CropScrim(cropRect: displayRect, imageRect: imageRect)
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            if draftRect != nil {
                CropGuideLines(cropDisplayRect: displayRect, imageRect: imageRect)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
            Rectangle()
                .fill(.clear)
                .frame(width: displayRect.width, height: displayRect.height)
                .position(x: displayRect.midX, y: displayRect.midY)
                .contentShape(Rectangle())
                .gesture(dragGesture(hit: .move, imageRect: imageRect))
            ForEach(hits, id: \.0) { hit, point in
                CornerBracket(hit: hit, length: bracketLength, width: bracketWidth)
                    .foregroundStyle(theme.accent)
                    .frame(width: handleSize, height: handleSize)
                    .position(point)
                    .contentShape(Rectangle())
                    .highPriorityGesture(dragGesture(hit: hit, imageRect: imageRect))
            }
        }
        .onChange(of: cropRect) { draftRect = $0 }
    }

    private var hits: [(Hit, CGPoint)] {
        let rect = displayRect(for: draftRect ?? cropRect, in: imageRect())
        return [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
    }

    private func dragGesture(hit: Hit, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? (draftRect ?? cropRect)
                dragStart = start
                let next = updated(start, hit: hit, translation: value.translation, imageRect: imageRect)
                draftRect = next
                onCommit(next)
            }
            .onEnded { _ in
                let final = draftRect ?? cropRect
                dragStart = nil
                onCommit(final)
            }
    }

    private func imageRect() -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let available = CGSize(width: max(0, containerSize.width - padding * 2), height: max(0, containerSize.height - padding * 2))
        let scale = min(available.width / sourceSize.width, available.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func displayRect(for rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private func updated(_ start: CGRect, hit: Hit, translation: CGSize, imageRect: CGRect) -> CGRect {
        let dx = translation.width / imageRect.width
        let dy = translation.height / imageRect.height
        var rect = start
        switch hit {
        case .move:
            rect.origin.x += dx
            rect.origin.y += dy
        case .topLeft:
            rect.origin.x += dx
            rect.origin.y += dy
            rect.size.width -= dx
            rect.size.height -= dy
        case .topRight:
            rect.origin.y += dy
            rect.size.width += dx
            rect.size.height -= dy
        case .bottomLeft:
            rect.origin.x += dx
            rect.size.width -= dx
            rect.size.height += dy
        case .bottomRight:
            rect.size.width += dx
            rect.size.height += dy
        }
        return AppState.clampedCropRect(rect)
    }
}

struct CropGuideLines: Shape {
    let cropDisplayRect: CGRect
    let imageRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in [cropDisplayRect.minX, cropDisplayRect.maxX] {
            path.move(to: CGPoint(x: x, y: imageRect.minY))
            path.addLine(to: CGPoint(x: x, y: imageRect.maxY))
        }
        for y in [cropDisplayRect.minY, cropDisplayRect.maxY] {
            path.move(to: CGPoint(x: imageRect.minX, y: y))
            path.addLine(to: CGPoint(x: imageRect.maxX, y: y))
        }
        return path
    }
}

struct CropScrim: Shape {
    let cropRect: CGRect
    let imageRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(imageRect)
        path.addRect(cropRect)
        return path
    }
}

struct CornerBracket: View {
    let hit: CropOverlay.Hit
    let length: CGFloat
    let width: CGFloat

    var body: some View {
        Path { path in
            let inset = (44 - length) / 2
            let min = inset
            let max = 44 - inset
            switch hit {
            case .topLeft:
                path.move(to: CGPoint(x: min, y: max)); path.addLine(to: CGPoint(x: min, y: min)); path.addLine(to: CGPoint(x: max, y: min))
            case .topRight:
                path.move(to: CGPoint(x: min, y: min)); path.addLine(to: CGPoint(x: max, y: min)); path.addLine(to: CGPoint(x: max, y: max))
            case .bottomLeft:
                path.move(to: CGPoint(x: min, y: min)); path.addLine(to: CGPoint(x: min, y: max)); path.addLine(to: CGPoint(x: max, y: max))
            case .bottomRight:
                path.move(to: CGPoint(x: min, y: max)); path.addLine(to: CGPoint(x: max, y: max)); path.addLine(to: CGPoint(x: max, y: min))
            case .move:
                break
            }
        }
        .stroke(style: StrokeStyle(lineWidth: width, lineCap: .square, lineJoin: .miter))
    }
}

struct Thumb: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) { image = ImageProcessor.thumbnail(for: url, maxPixelSize: size * 2) }
    }
}

/// A real wrapping layout: lays children left-to-right, wrapping whole
/// children (never breaking text mid-word) onto a new row once the current
/// row runs out of horizontal room.
struct FlowLayout: Layout {
    var spacing: CGFloat = AutomalitySpacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
