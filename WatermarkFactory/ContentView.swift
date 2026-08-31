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
        case selectImages, watermark, orderRename, export

        var title: String {
            switch self {
            case .selectImages: "Select Images"
            case .watermark: "Watermark"
            case .orderRename: "Order & Rename (optional)"
            case .export: "Export"
            }
        }
    }

    @Published var flowMode: FlowMode = .guided { didSet { defaults.set(flowMode.rawValue, forKey: "flowMode") } }
    @Published var folderURL: URL?
    @Published var watermarkURL: URL?
    @Published var images: [ImageItem] = []
    @Published var selected: ImageItem?
    @Published var stage: Stage = .selectImages
    @Published var sizePreset: WatermarkSizePreset? = .medium
    @Published var opacityPreset: OpacityPreset? = .balanced
    @Published var sizeFraction = 0.35 { didSet { saveSettings(); updateEstimate() } }
    @Published var opacity = 0.5 { didSet { saveSettings(); updateEstimate() } }
    @Published var anchor: Anchor = .bottomRight { didSet { saveSettings(); updateEstimate() } }
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
    @Published var previewImage: NSImage?
    @Published var sourceImageSize: CGSize?
    @Published var watermarkImageSize: CGSize?
    @Published var estimatedSize = ""
    @Published var estimatedFilename = ""
    @Published var status = "Choose a folder and watermark to begin."
    @Published var progress = 0.0
    @Published var isExporting = false
    @Published var isSuggestingPlacement = false
    @Published var smartPlacementProposal: SmartPlacementProposal?
    @Published var presets: [WatermarkPreset] = []
    @Published var orderedImageURLs: [URL] = [] { didSet { saveImageOrder() } }
    @Published var chatTranscript: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "Tell me how you want these watermarked.", chips: ["Just watermark these", "Subtle corner", "Centered bold", "Tiled brand"])
    ]

    enum OpenedURLInput: Equatable {
        case folder(URL)
        case images([URL])
    }

    private var previewTask: Task<Void, Never>?
    private var sourceSizeURL: URL?
    private var watermarkSizeURL: URL?
    private var suppressOffsetPreview = false
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
    var orderedItems: [ImageItem] {
        let numbered = orderedImageURLs.compactMap { url in images.first { $0.url == url } }
        let numberedURLs = Set(orderedImageURLs)
        return numbered + images.filter { !numberedURLs.contains($0.url) }
    }
    var numberedCount: Int { orderedImageURLs.filter { url in images.contains { $0.url == url } }.count }
    var orderSummary: String { "\(numberedCount) of \(images.count) images numbered" }
    var nextAvailableStage: Stage {
        if images.isEmpty { return .selectImages }
        if watermarkURL == nil { return .watermark }
        return .export
    }
    var exportHint: String? {
        if images.isEmpty { return "Choose a folder or images before export." }
        if watermarkURL == nil { return "Choose a watermark image before export." }
        if maxFileSizeBlocksExport { return "Max file size requires JPEG — switch format or clear this limit." }
        return nil
    }
    var settings: WatermarkSettings {
        WatermarkSettings(sizeFraction: sizeFraction, opacity: opacity, anchor: anchor, offsetX: offsetX, offsetY: offsetY, layoutMode: layoutMode, padding: padding, spacing: spacing, rotationPattern: rotationPattern, customAngle: customAngle, exportFormat: exportFormat, jpegQuality: jpegQuality, optimizeForWeb: optimizeForWeb, outputWidth: outputWidth, outputHeight: outputHeight, outputPrefix: outputPrefix, outputSuffix: outputSuffix, maxFileSizeKB: maxFileSizeKB, watermarkTint: watermarkTint)
    }
    var canSavePreset: Bool { watermarkURL != nil }
    var canSuggestPlacement: Bool { selected != nil && watermarkURL != nil && !isSuggestingPlacement }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url)
        }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        if panel.runModal() == .OK {
            setImages(panel.urls)
        }
    }

    func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
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
        if watermarkURL != nil && stage == .watermark { stage = .orderRename }
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
        guard let source = selected?.url, let watermark = watermarkURL else {
            previewImage = selected.flatMap { ImageProcessor.thumbnail(for: $0.url, maxPixelSize: 900) }
            estimatedSize = ""
            estimatedFilename = selected.map { ImageProcessor.outputFilename(for: $0.url, settings: settings, order: orderNumber(for: $0), numberedCount: numberedCount) } ?? ""
            return
        }
        let filename = ImageProcessor.outputFilename(for: source, settings: settings, order: selected.flatMap(orderNumber), numberedCount: numberedCount)
        previewTask = Task.detached {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled { return }
            let image = try? ImageProcessor.watermarkedImage(sourceURL: source, watermarkURL: watermark, settings: settings)
            let data = try? ImageProcessor.encodedWatermarkData(sourceURL: source, watermarkURL: watermark, settings: settings)
            await MainActor.run {
                if !Task.isCancelled {
                    self.previewImage = image.map { NSImage(cgImage: $0, size: .zero) }
                    self.estimatedSize = data.map { "~" + Self.formatBytes($0.count) } ?? ""
                    self.estimatedFilename = filename
                }
            }
        }
    }

    func dragWatermark(startX: Double, startY: Double, delta: CGSize, displayScale: CGFloat) {
        guard let sourceImageSize, let watermarkImageSize, displayScale > 0 else { return }
        let clamped = ImageProcessor.clampedWatermarkOffsets(
            sourceSize: sourceImageSize,
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

    func exportAll(completion: ((Bool) -> Void)? = nil) {
        guard let watermark = watermarkURL else {
            completion?(false)
            return
        }
        isExporting = true
        progress = 0
        status = "Exporting 0 of \(images.count)..."
        let items = orderedItems
        let settings = settings
        let numberedOrder = Dictionary(uniqueKeysWithValues: orderedImageURLs.enumerated().map { ($0.element, $0.offset + 1) })
        let numberedCount = numberedCount
        Task.detached {
            var summary = ExportSummary(success: 0, failed: [], bytes: 0, usedHEICFallback: false)
            var usedOutputURLs = Set<URL>()
            let watermarkAccess = watermark.startAccessingSecurityScopedResource()
            var revealURL: URL?
            defer {
                if watermarkAccess { watermark.stopAccessingSecurityScopedResource() }
            }
            for (index, item) in items.enumerated() {
                let access = item.url.startAccessingSecurityScopedResource()
                defer { if access { item.url.stopAccessingSecurityScopedResource() } }
                do {
                    let output = item.url.deletingLastPathComponent().appendingPathComponent("Watermarked", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let outputURL = ImageProcessor.uniqueOutputURL(for: item.url, outputFolder: output, settings: settings, order: numberedOrder[item.url], numberedCount: numberedCount, usedURLs: &usedOutputURLs)
                    let result = try ImageProcessor.export(sourceURL: item.url, watermarkURL: watermark, outputURL: outputURL, settings: settings)
                    revealURL = revealURL ?? output
                    summary.success += 1
                    summary.bytes += result.bytes
                    summary.usedHEICFallback = summary.usedHEICFallback || result.usedHEICFallback
                    if !result.metSizeTarget { summary.unmetSizeTarget.append(item.filename) }
                } catch {
                    summary.failed.append(item.filename)
                }
                await MainActor.run {
                    self.progress = Double(index + 1) / Double(items.count)
                    self.status = "Exporting \(index + 1) of \(items.count)..."
                }
            }
            await MainActor.run {
                if let revealURL {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
                self.isExporting = false
                var text = "\(summary.success) of \(items.count) images watermarked, total output size ~\(Self.formatBytes(summary.bytes))."
                if summary.usedHEICFallback { text += " HEIC was exported as PNG." }
                if !summary.unmetSizeTarget.isEmpty { text += " \(summary.unmetSizeTarget.count) couldn't reach the max file size target and were shipped at their closest achievable size." }
                if !summary.failed.isEmpty { text += " Failed: \(summary.failed.joined(separator: ", "))." }
                self.status = text
                completion?(summary.success == items.count && summary.failed.isEmpty)
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
        status = "Loaded preset \"\(preset.name)\"."
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
        status = "Applied \(preset.name) export preset."
    }

    func applyIntentSlots(_ slots: IntentSlots, message: String) {
        apply(IntentPreset.settings(from: slots, message: message, current: settings))
        status = slots.assistantReply
    }

    func suggestPlacement() {
        guard let source = selected?.url, let watermark = watermarkURL else { return }
        isSuggestingPlacement = true
        let settings = settings
        Task.detached {
            let proposal = ImageProcessor.smartPlacementProposal(sourceURL: source, watermarkURL: watermark, settings: settings)
            await MainActor.run {
                self.smartPlacementProposal = proposal
                self.isSuggestingPlacement = false
                if proposal == nil { self.status = "Could not analyze this image for placement." }
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
        status = "Applied suggested placement."
    }

    func dismissSmartPlacement() {
        smartPlacementProposal = nil
    }

    private func setFolder(_ url: URL) {
        sourceAccess.replace(with: [url])
        folderURL = url
        saveBookmark(url, key: "folderBookmark")
        reloadImages()
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
        status = images.isEmpty ? "No supported images selected." : "\(images.count) images selected."
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
            status = images.isEmpty ? "No supported images found in this folder." : "\(images.count) images found."
            pruneImageOrder()
            saveImageBookmarks()
            advanceIfReady()
            updateEstimate()
        } catch {
            sourceAccess.stopAll()
            images = []
            selected = nil
            pruneImageOrder()
            status = "Couldn't access the selected folder. Please re-choose it."
        }
    }

    private func saveSettings() {
        defaults.set(sizeFraction, forKey: "sizeFraction")
        defaults.set(opacity, forKey: "opacity")
        defaults.set(anchor.rawValue, forKey: "anchor")
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
    }

    private func restore() {
        restorePresets()
        flowMode = FlowMode(rawValue: defaults.string(forKey: "flowMode") ?? "") ?? .guided
        if defaults.object(forKey: "sizeFraction") != nil { sizeFraction = defaults.double(forKey: "sizeFraction") }
        if defaults.object(forKey: "opacity") != nil { opacity = defaults.double(forKey: "opacity") }
        anchor = Anchor(rawValue: defaults.string(forKey: "anchor") ?? "") ?? .bottomRight
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
            status = "\(images.count) images restored."
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
    private let controlsWidth: CGFloat = 360
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
            } else if state.flowMode == .chat {
                chatContent
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
            Text("A preset named \"\(duplicatePresetName)\" already exists.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AutomalitySpacing.sm) {
            AutomalitySegmentedControl(selection: $state.flowMode)
                .fixedSize()
            if state.flowMode == .guided {
                AutomalityProgressNav(steps: AppState.Stage.allCases.map(\.title), currentStep: Binding(
                    get: { state.stage.rawValue },
                    set: { if let stage = AppState.Stage(rawValue: $0) { state.advance(to: stage) } }
                ))
                Spacer()
                nextButton
            } else {
                Spacer()
            }
        }
    }

    /// The single "continue to the next stage" action, always in the top
    /// header next to the step nav — not buried at the bottom of a scrolling
    /// controls pane. Accent-colored (orange) so it reads as the one thing
    /// to do next; every other button on screen stays primary/secondary.
    @ViewBuilder
    private var nextButton: some View {
        switch state.stage {
        case .selectImages:
            Button("Next") { state.advance(to: .watermark) }
                .buttonStyle(.automalityAccent)
                .disabled(state.images.isEmpty)
        case .watermark:
            Button("Next") { state.advance(to: .orderRename) }
                .buttonStyle(.automalityAccent)
                .disabled(state.watermarkURL == nil)
        case .orderRename:
            Button("Next") { state.advance(to: .export) }
                .buttonStyle(.automalityAccent)
        case .export:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch state.stage {
        case .selectImages:
            selectImagesStage
        case .watermark:
            watermarkStage
        case .orderRename:
            orderRenameStage
        case .export:
            exportStage
        }
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    imagePickerSection
                    imageList
                }
                .padding(panePadding)
            }
            .frame(width: 300)
            Divider()
            previewPane
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    savedPresetLibrary
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
            .frame(width: controlsWidth)
        }
    }

    private var chatContent: some View {
        HStack(spacing: 0) {
            ChatFlowView(
                state: state,
                sizeOpacitySection: { AnyView(sizeOpacitySection) },
                positionPaddingSection: { AnyView(positionPaddingSection) },
                exportSection: { AnyView(exportSection) }
            )
            .frame(width: controlsWidth)
            Divider()
            previewPane
        }
    }

    private var selectImagesStage: some View {
        VStack(alignment: .leading, spacing: spacing) {
            imagePickerSection
            imageList
        }
        .padding(panePadding)
    }

    private var watermarkStage: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    savedPresetLibrary
                    watermarkSourceSection
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
                            Text("+ \(state.images.count - 8) more").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
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
                Button("Choose Folder...") { state.chooseFolder() }
                    .buttonStyle(.automalityPrimary)
                Button("Choose Images...") { state.chooseImages() }
                    .buttonStyle(.automalityPrimary)
            }
            if let folder = state.folderURL {
                Text(folder.lastPathComponent).font(.caption).foregroundStyle(AutomalityColor.inkMuted)
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
                Button("Choose Watermark...") { state.chooseWatermark() }
                    .buttonStyle(.automalityPrimary)
                Spacer()
                if let url = state.watermarkURL { Thumb(url: url, size: 56) }
            }
            Text("Tint").automalityLabelText().foregroundStyle(AutomalityColor.ink)
            AutomalitySegmentedControl(selection: $state.watermarkTint) { tint in
                AnyView(tintSwatch(tint))
            }
            // Smart Placement ("Suggest Placement") is disabled for this
            // release — the suggestions weren't reliable enough yet. The
            // underlying logic (AppState.suggestPlacement, smartPlacementCard,
            // SmartPlacementProposal) is left intact for a future version;
            // this just removes the UI entry point.
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
            AutomalitySegmentedControl(selection: $state.layoutMode)
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
            AutomalitySegmentedControl(selection: $state.exportFormat)
            Toggle("Optimize for Web", isOn: Binding(get: { state.optimizeForWeb }, set: { state.setOptimizeForWeb($0) }))
                .toggleStyle(.automality)
            HStack(spacing: 8) {
                TextField("Width", value: $state.outputWidth, format: .number)
                    .textFieldStyle(.automalityData)
                TextField("Height", value: $state.outputHeight, format: .number)
                    .textFieldStyle(.automalityData)
            }
            Text(state.outputWidth > 0 && state.outputHeight > 0 ? "Output size \(state.outputWidth)x\(state.outputHeight) px" : "Output size original").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            HStack(spacing: 8) {
                TextField("Prefix", text: Binding(get: { state.outputPrefix }, set: { state.outputPrefix = AppState.sanitizedFilenameAffix($0) }))
                    .textFieldStyle(.automality)
                TextField("Suffix", text: Binding(get: { state.outputSuffix }, set: { state.outputSuffix = AppState.sanitizedFilenameAffix($0) }))
                    .textFieldStyle(.automality)
            }
            if state.exportFormat == .jpeg {
                AutomalitySlider(value: $state.jpegQuality, in: 0...1)
                Text("JPEG quality \(Int(state.jpegQuality * 100))%").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
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
                Text("Quality (and, if needed, dimensions) will be reduced to fit ~\(state.maxFileSizeKB) KB per image.")
                    .font(.caption)
                    .foregroundStyle(AutomalityColor.inkMuted)
            }
            if !state.estimatedSize.isEmpty {
                Text("Estimated output size \(state.estimatedSize)").font(.caption)
            }
            if !state.estimatedFilename.isEmpty {
                Text("-> \(state.estimatedFilename)").font(.caption).foregroundStyle(AutomalityColor.inkMuted)
            }
            Button("Watermark All Images") { state.exportAll() }
                .buttonStyle(.automalityPrimary)
                .disabled(!state.canExport)
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
                Button("Skip") { state.advance(to: .export) }
                    .buttonStyle(.automalitySecondary)
                    .disabled(state.images.isEmpty || state.watermarkURL == nil)
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
                ForEach(RotationPattern.allCases) { Text($0.rawValue).tag($0) }
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

struct ControlSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
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
        let scale = displayScale(in: size)
        guard scale > 0 else { return nil }
        let imageSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2)
        let frame = ImageProcessor.watermarkFrame(sourceSize: sourceSize, watermarkSize: watermarkSize, settings: settings)
        return CGRect(
            x: origin.x + frame.minX * scale,
            y: origin.y + (sourceSize.height - frame.maxY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func displayScale(in size: CGSize) -> CGFloat {
        guard let sourceSize = state.sourceImageSize, sourceSize.width > 0, sourceSize.height > 0 else { return 0 }
        let available = CGSize(width: max(0, size.width - padding * 2), height: max(0, size.height - padding * 2))
        return min(available.width / sourceSize.width, available.height / sourceSize.height)
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
