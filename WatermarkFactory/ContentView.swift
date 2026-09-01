import AppKit
import AutomalityUI
import SwiftUI
import UniformTypeIdentifiers

extension AutomalityColor {
    static let inkMuted = ink.opacity(0.68)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Stage: Int, CaseIterable {
        case selectImages, watermark, position, orderRename, export

        var title: String {
            switch self {
            case .selectImages: String(localized: "Select Images")
            case .watermark: String(localized: "Watermark")
            case .position: String(localized: "Position")
            case .orderRename: String(localized: "Order & Rename (optional)")
            case .export: String(localized: "Export")
            }
        }
    }

    @Published var flowMode: FlowMode = .guided { didSet { defaults.set(flowMode.rawValue, forKey: "flowMode") } }
    @Published var folderURL: URL?
    @Published var watermarkURL: URL?
    // Compact mode's "Watermark not uploaded yet" prompt (Upload Watermark /
    // Compress Only), shown when Watermark All Images is tapped with no
    // watermark chosen -- see watermarkAllTapped() below.
    @Published var showWatermarkMissingPrompt = false
    @Published var showCropScopePrompt = false
    @Published var images: [ImageItem] = []
    @Published var selected: ImageItem?
    @Published var stage: Stage = .selectImages
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
    @Published var layoutMode: LayoutMode = .single { didSet { saveSettings(); updateEstimate() } }
    @Published var padding = 16.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var spacing = 80.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var rotationPattern: RotationPattern = .diagonal { didSet { saveSettings(); updateEstimate() } }
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
    @Published var metadataPrivacy: MetadataPrivacyLevel = .keepOriginalPrecision { didSet { saveSettings(); updateEstimate() } }
    @Published var removeWatermarkBackground = false { didSet { saveSettings(); updateEstimate() } }
    @Published var cropEnabled = false { didSet { updateEstimate() } }
    @Published var sharedCropRect: CGRect = .fullFrame { didSet { updateEstimate() } }
    @Published var perImageCropRects: [URL: CGRect] = [:] { didSet { updateEstimate() } }
    @Published var cropEditVersion = 0
    @Published var previewImage: NSImage?
    @Published var isDemoPreview = false
    @Published var sourceImageSize: CGSize?
    @Published var watermarkImageSize: CGSize?
    @Published var estimatedSize = ""
    @Published var estimatedFilename = ""
    @Published var status = String(localized: "Choose a folder and watermark to begin.")
    @Published var progress = 0.0
    @Published var isExporting = false
    @Published var showQuickActionPrompt = false
    @Published var isSuggestingPlacement = false
    @Published var smartPlacementProposal: SmartPlacementProposal?
    @Published var presets: [WatermarkPreset] = []
    @Published var recentFolders: [RecentFolder] = []
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
    private var pendingCropURL: URL?
    private var pendingCropRect: CGRect?
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

    func watermarkAllTapped() {
        guard canTapWatermarkAll else { return }
        if watermarkURL != nil {
            exportAll()
        } else {
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
    // Governs how far advance(to:) lets navigation jump ahead -- images are
    // a hard requirement (nothing else makes sense without them), but a
    // watermark is not: the Watermark stage's Skip action is a deliberate,
    // supported way to move on without one, so gating this on watermarkURL
    // would leave Skip inconsistent with the progress nav and every other
    // way of reaching a later stage (both would silently refuse the exact
    // jump Skip just performed). The actual export ACTION stays correctly
    // blocked without a watermark via canExport/exportHint below --
    // this only governs which stage VIEWS are reachable, not whether
    // export itself is allowed to run.
    var nextAvailableStage: Stage {
        images.isEmpty ? .selectImages : .export
    }
    var exportHint: String? {
        if images.isEmpty { return String(localized: "Choose a folder or images before export.") }
        if watermarkURL == nil { return String(localized: "Choose a watermark image before export.") }
        if maxFileSizeBlocksExport { return String(localized: "Max file size requires JPEG — switch format or clear this limit.") }
        return nil
    }
    var settings: WatermarkSettings {
        WatermarkSettings(sizeFraction: sizeFraction, opacity: opacity, anchor: anchor, additionalAnchors: additionalAnchors, offsetX: offsetX, offsetY: offsetY, layoutMode: layoutMode, padding: padding, spacing: spacing, rotationPattern: rotationPattern, customAngle: customAngle, exportFormat: exportFormat, jpegQuality: jpegQuality, optimizeForWeb: optimizeForWeb, outputWidth: outputWidth, outputHeight: outputHeight, outputPrefix: outputPrefix, outputSuffix: outputSuffix, maxFileSizeKB: maxFileSizeKB, watermarkTint: watermarkTint, metadataPrivacy: metadataPrivacy, removeWatermarkBackground: removeWatermarkBackground)
    }
    var canSavePreset: Bool { watermarkURL != nil }
    var canSuggestPlacement: Bool { selected != nil && watermarkURL != nil && !isSuggestingPlacement }
    func effectiveCropRect(for url: URL) -> CGRect { perImageCropRects[url] ?? sharedCropRect }
    func activeCropRect(for url: URL) -> CGRect { cropEnabled ? effectiveCropRect(for: url) : .fullFrame }

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

    /// Drag-and-drop entry point (see imagePickerSection's dropDestination)
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
            setWatermark(url)
        }
    }

    func select(_ item: ImageItem) {
        selected = item
        smartPlacementProposal = nil
        updateEstimate()
    }

    func advance(to stage: Stage) {
        guard stage.rawValue <= nextAvailableStage.rawValue else { return }
        self.stage = stage
    }

    func advanceIfReady() {
        if !images.isEmpty && stage == .selectImages { stage = .watermark }
        if watermarkURL != nil && stage == .watermark { stage = .position }
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
            estimatedFilename = ImageProcessor.outputFilename(for: source, settings: settings, order: orderNumber(for: selected!), numberedCount: numberedCount)
            return
        }
        let realWatermark = watermarkURL != nil
        let filename = realWatermark ? ImageProcessor.outputFilename(for: source, settings: settings, order: selected.flatMap(orderNumber), numberedCount: numberedCount) : ""
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

    func proposeCrop(_ rect: CGRect, for url: URL) {
        pendingCropURL = url
        pendingCropRect = Self.clampedCropRect(rect)
        showCropScopePrompt = true
    }

    func commitPendingCrop(appliedToAll: Bool) {
        guard let url = pendingCropURL, let rect = pendingCropRect else { return }
        if appliedToAll {
            sharedCropRect = rect
            perImageCropRects = [:]
        } else {
            perImageCropRects[url] = rect
        }
        clearPendingCrop()
    }

    func cancelPendingCrop() {
        clearPendingCrop()
    }

    private func clearPendingCrop() {
        pendingCropURL = nil
        pendingCropRect = nil
        cropEditVersion += 1
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
    func exportAll(compressOnly: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let watermark = watermarkURL
        guard compressOnly || watermark != nil else {
            completion?(false)
            return
        }
        isExporting = true
        progress = 0
        status = String(format: String(localized: "Exporting 0 of %d..."), images.count)
        let items = orderedItems
        let settings = settings
        let sourceFolder = folderURL
        let cropEnabled = cropEnabled
        let sharedCropRect = sharedCropRect
        let perImageCropRects = perImageCropRects
        let numberedOrder = Dictionary(uniqueKeysWithValues: orderedImageURLs.enumerated().map { ($0.element, $0.offset + 1) })
        let numberedCount = numberedCount
        Task.detached {
            var summary = ExportSummary(success: 0, failed: [], bytes: 0, usedHEICFallback: false)
            var usedOutputURLs = Set<URL>()
            let watermarkAccess = watermark?.startAccessingSecurityScopedResource() ?? false
            var revealURL: URL?
            defer {
                if watermarkAccess { watermark?.stopAccessingSecurityScopedResource() }
            }
            for (index, item) in items.enumerated() {
                let access = item.url.startAccessingSecurityScopedResource()
                defer { if access { item.url.stopAccessingSecurityScopedResource() } }
                do {
                    let output = item.url.deletingLastPathComponent().appendingPathComponent("Watermarked", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let outputURL = ImageProcessor.uniqueOutputURL(for: item.url, outputFolder: output, settings: settings, order: numberedOrder[item.url], numberedCount: numberedCount, usedURLs: &usedOutputURLs)
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
                    summary.failed.append("\(item.filename) (\(error.localizedDescription))")
                }
                await MainActor.run {
                    self.progress = Double(index + 1) / Double(items.count)
                    self.status = String(format: String(localized: "Exporting %d of %d..."), index + 1, items.count)
                }
            }
            await MainActor.run {
                if let revealURL {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
                self.isExporting = false
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
                // Quick Action prompt is disabled for this release -- pulled
                // per request. The underlying QuickActionPromptView and
                // showQuickActionPrompt plumbing are left intact for a
                // future version; this just removes the trigger, same
                // pattern as Smart Placement earlier.
                completion?(succeeded)
            }
        }
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
        selected = images.first
        status = images.isEmpty ? String(localized: "No supported images selected.") : String(format: String(localized: "%d images selected."), images.count)
        pruneImageOrder()
        saveImageBookmarks()
        advanceIfReady()
        updateEstimate()
    }

    private func setWatermark(_ url: URL) {
        watermarkAccess.replace(with: [url])
        watermarkURL = url
        saveBookmark(url, key: "watermarkBookmark")
        advanceIfReady()
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
            selected = images.first
            status = images.isEmpty ? String(localized: "No supported images found in this folder.") : String(format: String(localized: "%d images found."), images.count)
            pruneImageOrder()
            saveImageBookmarks()
            advanceIfReady()
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
    }

    private func restore() {
        restorePresets()
        restoreRecentFolders()
        restoreExportHistory()
        flowMode = FlowMode(rawValue: defaults.string(forKey: "flowMode") ?? "") ?? .guided
        if defaults.object(forKey: "sizeFraction") != nil { sizeFraction = defaults.double(forKey: "sizeFraction") }
        if defaults.object(forKey: "opacity") != nil { opacity = defaults.double(forKey: "opacity") }
        anchor = Anchor(rawValue: defaults.string(forKey: "anchor") ?? "") ?? .bottomRight
        additionalAnchors = (defaults.array(forKey: "additionalAnchors") as? [String] ?? []).compactMap(Anchor.init(rawValue:))
        offsetX = defaults.object(forKey: "offsetX") == nil ? 24 : defaults.double(forKey: "offsetX")
        offsetY = defaults.object(forKey: "offsetY") == nil ? 24 : defaults.double(forKey: "offsetY")
        layoutMode = LayoutMode(rawValue: defaults.string(forKey: "layoutMode") ?? "") ?? .single
        padding = defaults.object(forKey: "padding") == nil ? 16 : defaults.double(forKey: "padding")
        spacing = defaults.object(forKey: "spacing") == nil ? 80 : defaults.double(forKey: "spacing")
        rotationPattern = RotationPattern(rawValue: defaults.string(forKey: "rotationPattern") ?? "") ?? .diagonal
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
        metadataPrivacy = MetadataPrivacyLevel(rawValue: defaults.string(forKey: "metadataPrivacy") ?? "") ?? .keepOriginalPrecision
        removeWatermarkBackground = defaults.bool(forKey: "removeWatermarkBackground")
        syncPresetSelections()
        folderURL = restoreBookmark("folderBookmark")
        watermarkURL = restoreBookmark("watermarkBookmark")
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
        advanceIfReady()
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
    @ObservedObject private var state: AppState
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var duplicatePresetName = ""
    @State private var showingOverwriteConfirm = false
    @State private var draggingItem: ImageItem?
    @State private var isFileDropTargeted = false
    private let controlsWidth: CGFloat = 360
    private var compactControlsWidth: CGFloat { controlsWidth + BrandScrollBar<EmptyView>.railWidth }
    private let imageListWidth: CGFloat = 300
    private var compactImageListWidth: CGFloat { imageListWidth + BrandScrollBar<EmptyView>.railWidth }
    private let previewMinWidth: CGFloat = 560
    private let spacing: CGFloat = AutomalitySpacing.sm
    private let panePadding: CGFloat = AutomalitySpacing.sm

    init(state: AppState = .shared) {
        self.state = state
    }

    var body: some View {
        VStack(spacing: AutomalitySpacing.sm) {
            header
                .padding(.horizontal, panePadding)
                .padding(.top, panePadding)

            if state.flowMode == .guided {
                stageContent
            } else {
                compactContent
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(AutomalityColor.gray100)
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
                        .buttonStyle(.automalityPrimary)
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
        .alert(String(localized: "Apply this crop to:"), isPresented: $state.showCropScopePrompt) {
            Button(String(localized: "This Image Only")) { state.commitPendingCrop(appliedToAll: false) }
            Button(String(localized: "All Images in Batch")) { state.commitPendingCrop(appliedToAll: true) }
            Button(String(localized: "Cancel"), role: .cancel) { state.cancelPendingCrop() }
        }
        .sheet(isPresented: $state.showQuickActionPrompt) {
            QuickActionPromptView(isPresented: $state.showQuickActionPrompt)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AutomalitySpacing.sm) {
            AutomalitySegmentedControl(options: FlowMode.allCases, selection: $state.flowMode, label: \.label)
                .fixedSize()
            if state.flowMode == .guided {
                // Scrolls rather than clips/truncates if 5 steps plus
                // longer localized titles don't fit the window width --
                // Next stays outside the scroll area so it's never the
                // thing that goes offscreen.
                ScrollView(.horizontal, showsIndicators: false) {
                    AutomalityProgressNav(steps: AppState.Stage.allCases.map(\.title), currentStep: Binding(
                        get: { state.stage.rawValue },
                        set: { if let stage = AppState.Stage(rawValue: $0) { state.advance(to: stage) } }
                    ))
                }
                Spacer()
                nextButton
            } else {
                Spacer()
            }
        }
    }

    /// The single "continue to the next stage" action, always in the top
    /// header next to the step nav — not buried at the bottom of a scrolling
    /// controls pane. Accent-colored (orange) ONLY while it's actually the
    /// next actionable thing — the moment a stage still needs a choice made
    /// elsewhere on screen (e.g. Choose Watermark), that other control gets
    /// the accent instead and Next drops back to secondary. Exactly one
    /// orange element on screen at a time is the whole point: it has to
    /// always point at the one real next step, never two things competing.
    @ViewBuilder
    private var nextButton: some View {
        switch state.stage {
        case .selectImages:
            Button("Next") { state.advance(to: .watermark) }
                .buttonStyle(state.images.isEmpty ? .automalitySecondary : .automalityAccent)
                .disabled(state.images.isEmpty)
        case .watermark:
            // No watermark chosen yet: this becomes an explicit, always-
            // enabled "Skip" rather than a disabled "Next" -- watermarking
            // is the app's whole point but not force-required.
            // advance(to:) itself now allows this (nextAvailableStage no
            // longer gates on watermarkURL, see AppState) rather than this
            // button bypassing the guard directly -- a direct bypass here
            // left the progress nav and every other forward-navigation path
            // still silently blocked once on a later stage, since they all
            // go through advance(to:). One fix at the source, not another
            // one-off workaround. Primary (teal) rather than accent: it's a
            // real, deliberate choice, not the orange "do this next"
            // spotlight, which stays on Choose Watermark until one's
            // actually picked.
            if state.watermarkURL == nil {
                // Skips both Watermark AND Position -- there's nothing to
                // position without a watermark chosen, so Position isn't a
                // meaningful stop on the way past.
                Button("Skip") { state.advance(to: .orderRename) }
                    .buttonStyle(.automalityPrimary)
            } else {
                Button("Next") { state.advance(to: .position) }
                    .buttonStyle(.automalityAccent)
            }
        case .position:
            Button("Next") { state.advance(to: .orderRename) }
                .buttonStyle(.automalityAccent)
        case .orderRename:
            Button("Next") { state.advance(to: .export) }
                .buttonStyle(.automalityAccent)
        case .export:
            // The terminal action gets the same top-right, always-visible,
            // orange-when-actionable treatment as every other stage's
            // Next -- previously buried at the bottom of a scrolling
            // settings pane, easy to miss after scrolling through format/
            // size/prefix controls to get there.
            Button("Watermark All Images") { state.exportAll() }
                .buttonStyle(state.canExport ? .automalityAccent : .automalitySecondary)
                .disabled(!state.canExport)
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch state.stage {
        case .selectImages:
            selectImagesStage
        case .watermark:
            watermarkStage
        case .position:
            positionStage
        case .orderRename:
            orderRenameStage
        case .export:
            exportStage
        }
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            BrandScrollBar {
                VStack(alignment: .leading, spacing: spacing) {
                    imagePickerSection
                    imageList
                }
                .padding(panePadding)
            }
            .frame(width: compactImageListWidth)
            Divider()
            previewPane
            Divider()
            VStack(spacing: 0) {
                BrandScrollBar {
                    VStack(alignment: .leading, spacing: spacing) {
                        savedPresetLibrary
                        cropSection
                        watermarkSourceSection
                        sizeOpacitySection
                        layoutModeSection
                        positionPaddingSection
                        orderRenameSection
                        platformPresets
                        exportSection
                    }
                    .padding(panePadding)
                }
                Divider()
                compactWatermarkAllBar
            }
            .frame(width: compactControlsWidth)
        }
        .alert("Watermark not uploaded yet", isPresented: $state.showWatermarkMissingPrompt) {
            Button("Upload Watermark") { state.chooseWatermark() }
            Button("Compress Only") { state.exportAll(compressOnly: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a watermark image to apply, or export the images compressed only, with no watermark.")
        }
    }

    /// Compact mode's own persistent export action -- docked below the
    /// controls pane's scroll area (never inside it) so it's on screen
    /// without scrolling, same guarantee guided mode gets from its header
    /// Next button. Orange only once a watermark is actually chosen; tapping
    /// it before then doesn't just sit there disabled -- it opens the
    /// upload-or-compress-only prompt instead.
    private var compactWatermarkAllBar: some View {
        HStack {
            if state.isExporting { ProgressView(value: state.progress).frame(maxWidth: 120) }
            Spacer()
            Button("Watermark All Images") { state.watermarkAllTapped() }
                .buttonStyle(state.watermarkURL != nil ? .automalityAccent : .automalityPrimary)
                .disabled(!state.canTapWatermarkAll)
        }
        .padding(panePadding)
        .background(AutomalityColor.offWhite)
    }

    private var selectImagesStage: some View {
        VStack(alignment: .leading, spacing: spacing) {
            imagePickerSection
            imageList
        }
        .padding(panePadding)
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
        .background(isFileDropTargeted ? AutomalityColor.tealPale : Color.clear)
        .animation(.easeOut(duration: 0.15), value: isFileDropTargeted)
    }

    private var watermarkStage: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    cropSection
                    watermarkSourceSection
                }
                .padding(panePadding)
            }
            .frame(width: controlsWidth)
        }
    }

    /// Size/opacity/layout/position/padding/presets -- everything about
    /// where and how the watermark sits, kept as its own numbered step
    /// (not just a reveal inside the Watermark stage) so the progress nav
    /// actually reflects "choose the watermark" and "place it" as the two
    /// separate decisions they are.
    private var positionStage: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    intensitySection
                    savedPresetLibrary
                    sizeOpacitySection
                    layoutModeSection
                    positionPaddingSection
                }
                .padding(panePadding)
            }
            .frame(width: controlsWidth)
        }
    }

    private var orderRenameStage: some View {
        VStack(alignment: .leading, spacing: spacing) {
            orderRenameHeader
            orderGrid(minimumTileWidth: 140)
        }
        .padding(panePadding)
    }

    private var exportStage: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    ControlSection("Export summary") {
                        Text(state.orderSummary)
                            .foregroundStyle(AutomalityColor.ink)
                        ForEach(state.orderedItems.prefix(8)) { item in
                            HStack {
                                Text(state.orderNumber(for: item).map { "\($0)." } ?? "-")
                                    .frame(width: 32, alignment: .trailing)
                                    .foregroundStyle(AutomalityColor.inkMuted)
                                Text(item.filename)
                                    .lineLimit(1)
                                    .foregroundStyle(AutomalityColor.ink)
                            }
                        }
                        if state.images.count > 8 {
                            Text(String(format: String(localized: "+ %d more"), state.images.count - 8)).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
                        }
                    }
                    platformPresets
                    exportSection
                }
                .padding(panePadding)
            }
            .frame(width: controlsWidth)
            Divider()
            previewPane
        }
    }

    private var imagePickerSection: some View {
        ControlSection("Select Images") {
            FlowLayout {
                Button("Choose Folder or Images...") { state.chooseFolderOrImages() }
                    .buttonStyle(.automalityPrimary)
            }
            Text("...or drag a folder or images in")
                .font(.caption)
                .foregroundStyle(AutomalityColor.inkMuted)
            if !state.recentFolders.isEmpty {
                Text("Recent").automalityLabelText().foregroundStyle(AutomalityColor.ink)
                FlowLayout {
                    ForEach(state.recentFolders) { recent in
                        Button(recent.name) { state.selectRecentFolder(recent) }
                            .buttonStyle(.automalityChip(isSelected: state.folderURL?.path == recent.path))
                    }
                }
            }
            if let folder = state.folderURL {
                Text(folder.lastPathComponent).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            }
            // Reloads a past batch's folder, watermark, and settings exactly
            // as they were -- for redoing a mis-applied watermark or
            // swapping in a new logo without needing to know where the
            // original folder was, or touch an already-watermarked file.
            if !state.exportHistory.isEmpty {
                Text("Redo a past batch").automalityLabelText().foregroundStyle(AutomalityColor.ink)
                FlowLayout {
                    ForEach(state.exportHistory) { entry in
                        Button("\(entry.folderName) \u{2190} \(entry.watermarkName)") { state.redoFromHistory(entry) }
                            .buttonStyle(.automalityChip(isSelected: false))
                            .help(String(format: String(localized: "%d of %d images, %@"), entry.succeededCount, entry.imageCount, entry.date.formatted(date: .abbreviated, time: .shortened)))
                    }
                }
            }
        }
    }

    private var imageList: some View {
        ControlSection("Images") {
            if state.images.isEmpty {
                Text("Choose a folder or select individual images to get started.")
                    .font(.callout)
                    .foregroundStyle(AutomalityColor.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List(state.images, selection: Binding(get: { state.selected }, set: { if let item = $0 { state.select(item) } })) { item in
                    HStack(spacing: 8) {
                        Thumb(url: item.url, size: 42)
                        Text(item.filename).lineLimit(1)
                    }
                    .tag(item as ImageItem?)
                }
                .frame(minHeight: 420)
            }
        }
    }

    private var previewPane: some View {
        VStack(spacing: spacing) {
            ZStack {
                AutomalityColor.gray100
                if let image = state.previewImage {
                    WatermarkPreview(image: image, state: state)
                } else {
                    Text("Select an image to preview.")
                        .font(.title3)
                        .foregroundStyle(AutomalityColor.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().stroke(AutomalityColor.ink.opacity(0.2)))
            .overlay(alignment: .top) {
                if state.isDemoPreview {
                    Text("Previewing with Automality's mark — choose your own watermark to replace it")
                        .font(.caption)
                        .foregroundStyle(AutomalityColor.offWhite)
                        .padding(.horizontal, AutomalitySpacing.sm)
                        .padding(.vertical, 6)
                        .background(AutomalityColor.tealDeep.opacity(0.85))
                }
            }
            .clipped()
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(state.images) { item in
                        Thumb(url: item.url, size: 60)
                            .overlay(Rectangle().stroke(state.selected == item ? AutomalityColor.teal : AutomalityColor.gray300, lineWidth: state.selected == item ? 2 : 1))
                            .onTapGesture { state.select(item) }
                    }
                }
                .padding(.horizontal, panePadding)
            }
            .frame(height: 76)
            .background(AutomalityColor.offWhite)
            Text(state.status)
                .font(.caption)
                .foregroundStyle(AutomalityColor.inkMuted)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, panePadding)
                .padding(.bottom, 8)
        }
        .frame(minWidth: previewMinWidth)
    }

    private var watermarkSourceSection: some View {
        ControlSection("Watermark source") {
            HStack(spacing: 12) {
                // Accent (orange) until a watermark is picked -- it's the
                // one thing blocking progress on this stage, so it's the
                // single orange element on screen (the header's Next stays
                // secondary/disabled until this is done, see nextButton).
                // Reverts to primary once set, handing the "next step"
                // spotlight to Next.
                Button("Choose Watermark...") { state.chooseWatermark() }
                    .buttonStyle(state.watermarkURL == nil ? .automalityAccent : .automalityPrimary)
                Spacer()
                if let url = state.watermarkURL { Thumb(url: url, size: 56) }
            }
            Text("Tint").automalityLabelText().foregroundStyle(AutomalityColor.ink)
            AutomalitySegmentedControl(options: WatermarkTint.allCases, selection: $state.watermarkTint, label: \.label) { tint in
                AnyView(tintSwatch(tint))
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
            // Smart Placement ("Suggest Placement") is disabled for this
            // release — the suggestions weren't reliable enough yet. The
            // underlying logic (AppState.suggestPlacement, smartPlacementCard,
            // SmartPlacementProposal) is left intact for a future version;
            // this just removes the UI entry point.
        }
    }

    private var cropSection: some View {
        ControlSection("Crop") {
            Toggle(String(localized: "Enable Crop"), isOn: $state.cropEnabled)
                .toggleStyle(.automality)
            Text(String(localized: "Crops before the watermark is applied. Applies to this image or the whole batch - you'll be asked which."))
                .font(.caption)
                .foregroundStyle(AutomalityColor.inkMuted)
        }
    }

    /// A small swatch previewing what each tint option actually does, so the
    /// choice reads visually instead of relying on the word alone — "Light"
    /// looks light, "Dark" looks dark, "Original" shows a split (keeps
    /// whatever the source watermark already is).
    @ViewBuilder
    private func tintSwatch(_ tint: WatermarkTint) -> some View {
        ZStack {
            switch tint {
            case .original:
                GeometryReader { proxy in
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                        path.addLine(to: .zero)
                        path.closeSubpath()
                    }.fill(AutomalityColor.offWhite)
                    Path { path in
                        path.move(to: CGPoint(x: proxy.size.width, y: 0))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                        path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                        path.closeSubpath()
                    }.fill(AutomalityColor.ink)
                }
            case .light:
                AutomalityColor.offWhite
            case .dark:
                AutomalityColor.ink
            }
        }
        .frame(width: 16, height: 16)
        .overlay(Rectangle().stroke(AutomalityColor.gray300, lineWidth: 1))
    }

    /// "How loud should this be" as one control -- six named steps ordered
    /// low to high intrusiveness (Discrete...Protective), each setting
    /// size+opacity+layout together, plus a continuous slider that
    /// interpolates between them for fine adjustment. The granular Size &
    /// Opacity section below stays available for anyone who wants an exact
    /// custom combination this ladder doesn't cover.
    private var intensitySection: some View {
        ControlSection("Watermark Intensity") {
            WatermarkIntensityPad(
                sizeFraction: $state.sizeFraction,
                layoutStyle: Binding(get: { state.intensityLayoutStyle }, set: { state.intensityLayoutStyle = $0 }),
                opacity: state.opacity
            )
            FlowLayout {
                ForEach(WatermarkIntensityPreset.allCases) { preset in
                    Button(preset.label) {
                        state.sizeFraction = preset.sizeFraction
                        state.intensityLayoutStyle = preset.layoutStyle
                        state.opacity = preset.opacity
                    }
                    .buttonStyle(.automalityChip(isSelected: isCurrentIntensityPreset(preset)))
                }
            }
            Text("Opacity").automalityLabelText().foregroundStyle(AutomalityColor.ink)
            AutomalitySlider(value: $state.opacity, in: 0...1)
            Text("\(Int(state.opacity * 100))%").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            Text(currentIntensityPurpose)
                .font(.caption)
                .foregroundStyle(AutomalityColor.inkMuted)
        }
    }

    private func isCurrentIntensityPreset(_ preset: WatermarkIntensityPreset) -> Bool {
        abs(state.sizeFraction - preset.sizeFraction) < 0.005
            && state.intensityLayoutStyle == preset.layoutStyle
            && abs(state.opacity - preset.opacity) < 0.005
    }

    private var currentIntensityPurpose: String {
        WatermarkIntensityPreset.nearest(sizeFraction: state.sizeFraction, layoutStyle: state.intensityLayoutStyle).purpose
    }

    private var sizeOpacitySection: some View {
        ControlSection("Size & Opacity") {
            presetSection("Size", presets: WatermarkSizePreset.allCases, selected: state.sizePreset?.id, valueText: state.sizePreset?.label ?? "Custom") { preset in
                state.sizePreset = preset
                state.sizeFraction = preset.value
            }
            AutomalitySlider(value: Binding(get: { state.sizeFraction }, set: { state.sizePreset = nil; state.sizeFraction = $0 }), in: 0.05...1.0)
            Text("\(Int(state.sizeFraction * 100))%").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            Divider()
            presetSection("Opacity", presets: OpacityPreset.allCases, selected: state.opacityPreset?.id, valueText: state.opacityPreset?.label ?? "Custom") { preset in
                state.opacityPreset = preset
                state.opacity = preset.value
            }
            AutomalitySlider(value: Binding(get: { state.opacity }, set: { state.opacityPreset = nil; state.opacity = $0 }), in: 0...1)
            Text("\(Int(state.opacity * 100))%").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
        }
    }

    private var layoutModeSection: some View {
        ControlSection("Layout mode") {
            AutomalitySegmentedControl(options: LayoutMode.allCases, selection: $state.layoutMode, label: \.label)
        }
    }

    // Everything about *where* the watermark sits and how much room it
    // gets lives in one section, in the order you'd actually set it up:
    // pick a corner → set its margin from the edge → optionally nudge it →
    // (tiled only) set the gap between repeats and their rotation. This
    // used to be split across two sections (Position & Padding, and a
    // Spacing slider buried in Layout mode) — consolidated per feedback
    // that having padding-like controls in multiple places was confusing.
    private var positionPaddingSection: some View {
        ControlSection("Position & Padding") {
            if state.layoutMode == .single {
                Text("Anchor").automalityLabelText().foregroundStyle(AutomalityColor.ink)
                singleControls
            }
            Text(state.layoutMode == .single ? "Padding — distance from that edge" : "Padding — margin around each mark")
                .automalityLabelText()
                .foregroundStyle(AutomalityColor.ink)
            AutomalitySlider(value: $state.padding, in: 0...100)
            Text("\(Int(state.padding)) px").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            if state.layoutMode == .tiled {
                Divider()
                tiledControls
            }
        }
    }

    private var exportSection: some View {
        ControlSection("Export") {
            Text("Export format").automalityLabelText().foregroundStyle(AutomalityColor.ink)
            AutomalitySegmentedControl(options: ExportFormat.allCases, selection: $state.exportFormat, label: \.label)
            Toggle("Optimize for Web", isOn: Binding(get: { state.optimizeForWeb }, set: { state.setOptimizeForWeb($0) }))
                .toggleStyle(.automality)
            // Original/hidden metadata (camera make, maker notes, AI-
            // provenance descriptions, embedded thumbnails, author fields)
            // is already always removed -- verified directly against a
            // real exported file's exiftool dump, not assumed. GPS is the
            // one field that's a genuine choice, not an oversight.
            Text("Location metadata").automalityLabelText().foregroundStyle(AutomalityColor.ink)
            AutomalitySegmentedControl(options: MetadataPrivacyLevel.allCases, selection: $state.metadataPrivacy, label: \.label)
            HStack(spacing: 8) {
                TextField("Width", value: $state.outputWidth, format: .number)
                    .textFieldStyle(.automalityData)
                TextField("Height", value: $state.outputHeight, format: .number)
                    .textFieldStyle(.automalityData)
            }
            Text(state.outputWidth > 0 && state.outputHeight > 0 ? String(format: String(localized: "Output size %d×%d px"), state.outputWidth, state.outputHeight) : String(localized: "Output size original")).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            HStack(spacing: 8) {
                TextField("Prefix", text: Binding(get: { state.outputPrefix }, set: { state.outputPrefix = AppState.sanitizedFilenameAffix($0) }))
                    .textFieldStyle(.automality)
                TextField("Suffix", text: Binding(get: { state.outputSuffix }, set: { state.outputSuffix = AppState.sanitizedFilenameAffix($0) }))
                    .textFieldStyle(.automality)
            }
            if state.exportFormat == .jpeg {
                AutomalitySlider(value: $state.jpegQuality, in: 0...1)
                Text(String(format: String(localized: "JPEG quality %d%%"), Int(state.jpegQuality * 100))).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            }
            Text(state.exportFormat.hint).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            HStack(spacing: 8) {
                Text("Max file size")
                TextField("Off", value: $state.maxFileSizeKB, format: .number)
                    .textFieldStyle(.automalityData)
                    .frame(width: 70)
                Text("KB").foregroundStyle(AutomalityColor.inkMuted)
            }
            if state.maxFileSizeBlocksExport {
                Text("Max file size requires JPEG — switch format or clear this limit.")
                    .font(.caption)
                    .foregroundStyle(AutomalityColor.orangeDeep)
            } else if state.maxFileSizeKB > 0 {
                Text(String(format: String(localized: "Quality (and, if needed, dimensions) will be reduced to fit ~%d KB per image."), state.maxFileSizeKB))
                    .font(.caption)
                    .foregroundStyle(AutomalityColor.inkMuted)
            }
            if !state.estimatedSize.isEmpty {
                Text(String(format: String(localized: "Estimated output size %@"), state.estimatedSize)).font(.caption)
            }
            if !state.estimatedFilename.isEmpty {
                Text(String(format: String(localized: "-> %@"), state.estimatedFilename)).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            }
            // The action itself moved to the top-right header (always
            // visible, orange when ready) -- this hint/progress stays here,
            // next to the settings it's actually explaining.
            if let hint = state.exportHint { Text(hint).font(.caption).foregroundStyle(AutomalityColor.inkMuted) }
            if state.isExporting { ProgressView(value: state.progress) }
        }
    }

    private var savedPresetLibrary: some View {
        ControlSection("Presets") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Save current as preset...") {
                    presetName = ""
                    isNamingPreset = true
                }
                .buttonStyle(.automalityPrimary)
                .disabled(!state.canSavePreset)
                if state.presets.isEmpty {
                    Text("No saved presets.").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(state.presets) { preset in
                                HStack {
                                    Button(preset.name) { state.applyPreset(preset) }
                                        .buttonStyle(.plain)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button(role: .destructive) { state.deletePreset(preset) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete preset")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    private var platformPresets: some View {
        ControlSection("Platform presets") {
            ForEach(PlatformExportPreset.all) { preset in
                Button {
                    state.applyPlatformPreset(preset)
                } label: {
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Text(preset.sizeLabel).foregroundStyle(AutomalityColor.inkMuted)
                    }
                }
                .buttonStyle(.automalitySecondary)
                .help(preset.note)
            }
        }
    }

    @ViewBuilder
    private var smartPlacementCard: some View {
        if let proposal = state.smartPlacementProposal {
            ControlSection("Suggested Placement") {
                Text(proposal.note)
                    .font(.caption)
                    .foregroundStyle(AutomalityColor.inkMuted)
                if proposal.saliencyUnavailable {
                    Text("Saliency was unavailable for this image.")
                        .font(.caption)
                        .foregroundStyle(AutomalityColor.orangeDeep)
                }
                FlowLayout {
                    Button("Dismiss") { state.dismissSmartPlacement() }
                        .buttonStyle(.automalitySecondary)
                    Button("Apply") { state.applySmartPlacement() }
                        .buttonStyle(.automalityPrimary)
                }
            }
        }
    }

    private var orderRenameSection: some View {
        ControlSection("Order & Rename") {
            orderRenameHeader
            orderGrid(minimumTileWidth: 96)
                .frame(minHeight: 180, maxHeight: 320)
        }
    }

    private var orderRenameHeader: some View {
        VStack(alignment: .leading, spacing: AutomalitySpacing.sm) {
            Text(state.orderSummary)
                .font(.headline)
                .foregroundStyle(AutomalityColor.ink)
            FlowLayout {
                Button("Clear order") { state.clearOrder() }
                    .buttonStyle(.automalitySecondary)
                    .disabled(state.numberedCount == 0)
                Button("Number in current order") { state.numberInCurrentOrder(state.orderedItems) }
                    .buttonStyle(.automalityPrimary)
                    .disabled(state.images.isEmpty)
                // Only images are required to view the Export stage --
                // watermarkURL is intentionally not part of this gate (see
                // AppState.nextAvailableStage): the actual export action
                // stays correctly blocked without one via canExport/
                // exportHint on that stage, this only governs navigation.
                Button("Skip") { state.advance(to: .export) }
                    .buttonStyle(.automalitySecondary)
                    .disabled(state.images.isEmpty)
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
        return VStack(alignment: .leading, spacing: AutomalitySpacing.xs) {
            ZStack(alignment: .topLeading) {
                Thumb(url: item.url, size: 128)
                    .opacity(number == nil ? 0.45 : 1)
                if let number {
                    Text("\(number)")
                        .font(.headline)
                        .foregroundStyle(AutomalityColor.offWhite)
                        .padding(.horizontal, AutomalitySpacing.xs)
                        .padding(.vertical, 4)
                        .background(AutomalityColor.teal)
                        .overlay(Rectangle().stroke(AutomalityColor.ink, lineWidth: 2))
                        .padding(AutomalitySpacing.xs)
                }
            }
            Text(item.filename)
                .font(.caption)
                .foregroundStyle(AutomalityColor.inkMuted)
                .lineLimit(2)
                .frame(width: 128, alignment: .leading)
        }
        .padding(AutomalitySpacing.xs)
        .background(AutomalityColor.offWhite)
        .overlay(Rectangle().stroke(number == nil ? AutomalityColor.gray300 : AutomalityColor.ink, lineWidth: 2))
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

    private var singleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 3), spacing: 8) {
                ForEach(Anchor.allCases) { anchor in
                    Button { state.anchor = anchor } label: {
                        Image(systemName: anchor.symbol).frame(width: 32, height: 30)
                    }
                    .buttonStyle(.automalityChip(isSelected: state.anchor == anchor))
                }
            }
            Text("Nudge from anchor (optional)").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            HStack(spacing: 8) {
                TextField("X", value: $state.offsetX, format: .number)
                    .textFieldStyle(.automalityData)
                    .frame(width: 70)
                TextField("Y", value: $state.offsetY, format: .number)
                    .textFieldStyle(.automalityData)
                    .frame(width: 70)
            }
        }
    }

    private var tiledControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spacing — gap between tiles").automalityLabelText().foregroundStyle(AutomalityColor.ink)
            AutomalitySlider(value: $state.spacing, in: 0...400)
            Text("\(Int(state.spacing)) px").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            Picker("Rotation", selection: $state.rotationPattern) {
                ForEach(RotationPattern.allCases) { Text($0.label).tag($0) }
            }
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
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(AutomalityColor.ink)
                Spacer()
                Text(valueText).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
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
                .fill(AutomalityColor.ink)
                .frame(width: side, height: side)
                .frame(width: 16, height: 16)
        } else if let preset = preset as? OpacityPreset {
            // Opacity: a fixed-size swatch whose fill opacity previews the tier.
            Rectangle()
                .fill(AutomalityColor.ink.opacity(preset.value))
                .overlay(Rectangle().stroke(AutomalityColor.gray300, lineWidth: 1))
                .frame(width: 16, height: 16)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

/// Drag anywhere to set size (X) and layout style (Y) together in one
/// gesture. Opacity isn't a third spatial axis -- forcing four independent
/// dimensions into one control is exactly what makes a control hard to
/// use, not powerful. It rides along as the handle's own transparency
/// instead, live, while staying a real independently-adjustable value via
/// the slider underneath.
struct WatermarkIntensityPad: View {
    @Binding var sizeFraction: Double
    @Binding var layoutStyle: WatermarkLayoutStyle
    let opacity: Double

    private let padHeight: CGFloat = 168

    var body: some View {
        GeometryReader { geo in
            let rowHeight = geo.size.height / CGFloat(WatermarkLayoutStyle.allCases.count)
            ZStack(alignment: .topLeading) {
                AutomalityColor.gray100
                // Row bands + labels
                ForEach(WatermarkLayoutStyle.allCases) { style in
                    let y = CGFloat(style.rawValue) * rowHeight
                    Rectangle()
                        .stroke(AutomalityColor.gray300, lineWidth: 1)
                        .frame(width: geo.size.width, height: rowHeight)
                        .position(x: geo.size.width / 2, y: y + rowHeight / 2)
                    Text(style.label)
                        .font(.caption2)
                        .foregroundStyle(AutomalityColor.inkMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(AutomalityColor.offWhite.opacity(0.85))
                        .position(x: 44, y: y + 10)
                }
                // Reference dots for the six named presets, so the grid
                // isn't just an empty field -- it shows where the named
                // steps actually sit.
                ForEach(WatermarkIntensityPreset.allCases) { preset in
                    let px = xPosition(for: preset.sizeFraction, width: geo.size.width)
                    let py = CGFloat(preset.layoutStyle.rawValue) * rowHeight + rowHeight / 2
                    Circle()
                        .fill(AutomalityColor.gray300)
                        .frame(width: 6, height: 6)
                        .position(x: px, y: py)
                }
                // The draggable handle itself
                let hx = xPosition(for: sizeFraction, width: geo.size.width)
                let hy = CGFloat(layoutStyle.rawValue) * rowHeight + rowHeight / 2
                Circle()
                    .fill(AutomalityColor.orange.opacity(max(opacity, 0.15)))
                    .overlay(Circle().stroke(AutomalityColor.ink, lineWidth: 2))
                    .frame(width: 22, height: 22)
                    .position(x: hx, y: hy)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clampedX = min(max(value.location.x, 0), geo.size.width)
                        sizeFraction = fraction(forX: clampedX, width: geo.size.width)
                        let row = min(max(Int(value.location.y / rowHeight), 0), WatermarkLayoutStyle.allCases.count - 1)
                        if let style = WatermarkLayoutStyle(rawValue: row) { layoutStyle = style }
                    }
            )
        }
        .frame(height: padHeight)
        .overlay(Rectangle().stroke(AutomalityColor.ink.opacity(0.3), lineWidth: 1))
    }

    private func xPosition(for size: Double, width: CGFloat) -> CGFloat {
        let range = WatermarkIntensityPreset.sizeRange
        let t = (size - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(min(max(t, 0), 1)) * width
    }

    private func fraction(forX x: CGFloat, width: CGFloat) -> Double {
        let range = WatermarkIntensityPreset.sizeRange
        guard width > 0 else { return range.lowerBound }
        let t = Double(x / width)
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }
}

struct ControlSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = String(localized: String.LocalizationValue(title))
        self.content = content()
    }

    var body: some View {
        AutomalitySectionBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                        padding: padding,
                        resetToken: state.cropEditVersion
                    ) { rect in
                        state.proposeCrop(rect, for: source)
                    }
                }
                if let rect = displayedWatermarkRect(in: proxy.size) {
                    Rectangle()
                        .fill(.clear)
                        .overlay(
                            Rectangle()
                                .stroke(AutomalityColor.teal.opacity(dragStart == nil ? 0.25 : 0.8), lineWidth: dragStart == nil ? 1 : 2)
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
                        .fill(AutomalityColor.teal.opacity(0.08))
                        .overlay(
                            Rectangle()
                                .stroke(AutomalityColor.orangeDeep, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
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
    let cropRect: CGRect
    let sourceSize: CGSize
    let containerSize: CGSize
    let padding: CGFloat
    let resetToken: Int
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
            Rectangle()
                .fill(.clear)
                .frame(width: displayRect.width, height: displayRect.height)
                .position(x: displayRect.midX, y: displayRect.midY)
                .contentShape(Rectangle())
                .gesture(dragGesture(hit: .move, imageRect: imageRect))
            ForEach(hits, id: \.0) { hit, point in
                CornerBracket(hit: hit, length: bracketLength, width: bracketWidth)
                    .foregroundStyle(AutomalityColor.orange)
                    .frame(width: handleSize, height: handleSize)
                    .position(point)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(hit: hit, imageRect: imageRect))
            }
        }
        .onChange(of: cropRect) { draftRect = $0 }
        .onChange(of: resetToken) { _ in draftRect = cropRect }
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
                draftRect = updated(start, hit: hit, translation: value.translation, imageRect: imageRect)
            }
            .onEnded { _ in
                let final = draftRect ?? cropRect
                dragStart = nil
                if final != cropRect {
                    onCommit(final)
                }
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
            AutomalityColor.gray100
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
