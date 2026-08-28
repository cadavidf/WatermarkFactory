import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var folderURL: URL?
    @Published var watermarkURL: URL?
    @Published var images: [ImageItem] = []
    @Published var selected: ImageItem?
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
    @Published var exportFormat: ExportFormat = .keepOriginal { didSet { saveSettings(); updateEstimate() } }
    @Published var jpegQuality = 0.9 { didSet { saveSettings(); updateEstimate() } }
    @Published var outputPrefix = "" { didSet { saveSettings(); updateEstimate() } }
    @Published var outputSuffix = "" { didSet { saveSettings(); updateEstimate() } }
    @Published var previewImage: NSImage?
    @Published var sourceImageSize: CGSize?
    @Published var watermarkImageSize: CGSize?
    @Published var estimatedSize = ""
    @Published var estimatedFilename = ""
    @Published var status = "Choose a folder and watermark to begin."
    @Published var progress = 0.0
    @Published var isExporting = false
    @Published var presets: [WatermarkPreset] = []

    private var previewTask: Task<Void, Never>?
    private var sourceSizeURL: URL?
    private var watermarkSizeURL: URL?
    private var suppressOffsetPreview = false
    private let defaults = UserDefaults.standard

    init() {
        restore()
    }

    var canExport: Bool { watermarkURL != nil && !images.isEmpty && !isExporting }
    var exportHint: String? {
        if images.isEmpty { return "Choose a folder or images before export." }
        if watermarkURL == nil { return "Choose a watermark image before export." }
        return nil
    }
    var settings: WatermarkSettings {
        WatermarkSettings(sizeFraction: sizeFraction, opacity: opacity, anchor: anchor, offsetX: offsetX, offsetY: offsetY, layoutMode: layoutMode, padding: padding, spacing: spacing, rotationPattern: rotationPattern, customAngle: customAngle, exportFormat: exportFormat, jpegQuality: jpegQuality, outputPrefix: outputPrefix, outputSuffix: outputSuffix)
    }
    var canSavePreset: Bool { watermarkURL != nil }

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
        updateEstimate()
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
            estimatedFilename = selected.map { ImageProcessor.outputFilename(for: $0.url, settings: settings) } ?? ""
            return
        }
        let filename = ImageProcessor.outputFilename(for: source, settings: settings)
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

    func exportAll() {
        guard let watermark = watermarkURL else { return }
        isExporting = true
        progress = 0
        status = "Exporting 0 of \(images.count)..."
        let items = images
        let settings = settings
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
                    let outputURL = ImageProcessor.uniqueOutputURL(for: item.url, outputFolder: output, settings: settings, usedURLs: &usedOutputURLs)
                    let result = try ImageProcessor.export(sourceURL: item.url, watermarkURL: watermark, outputURL: outputURL, settings: settings)
                    revealURL = revealURL ?? output
                    summary.success += 1
                    summary.bytes += result.bytes
                    summary.usedHEICFallback = summary.usedHEICFallback || result.usedHEICFallback
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
                if !summary.failed.isEmpty { text += " Failed: \(summary.failed.joined(separator: ", "))." }
                self.status = text
            }
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
        if let watermarkURL { saveBookmark(watermarkURL, key: "watermarkBookmark") }
        apply(preset.settings)
        status = "Loaded preset \"\(preset.name)\"."
    }

    func deletePreset(_ preset: WatermarkPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    private func setFolder(_ url: URL) {
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
        images = filtered.map(ImageItem.init)
        selected = images.first
        status = images.isEmpty ? "No supported images selected." : "\(images.count) images selected."
        saveImageBookmarks()
        updateEstimate()
    }

    private func setWatermark(_ url: URL) {
        watermarkURL = url
        saveBookmark(url, key: "watermarkBookmark")
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
        outputPrefix = Self.sanitizedFilenameAffix(settings.outputPrefix)
        outputSuffix = Self.sanitizedFilenameAffix(settings.outputSuffix)
        syncPresetSelections()
        updateEstimate(delay: 0)
    }

    private func reloadImages() {
        guard let folderURL else { return }
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            defaults.set(false, forKey: "usedIndividualImages")
            images = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
                .filter { ImageProcessor.supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map(ImageItem.init)
            selected = images.first
            status = images.isEmpty ? "No supported images found in this folder." : "\(images.count) images found."
            saveImageBookmarks()
            updateEstimate()
        } catch {
            images = []
            selected = nil
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
        defaults.set(outputPrefix, forKey: "outputPrefix")
        defaults.set(outputSuffix, forKey: "outputSuffix")
    }

    private func restore() {
        restorePresets()
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
        outputPrefix = Self.sanitizedFilenameAffix(defaults.string(forKey: "outputPrefix") ?? "")
        outputSuffix = Self.sanitizedFilenameAffix(defaults.string(forKey: "outputSuffix") ?? "")
        syncPresetSelections()
        folderURL = restoreBookmark("folderBookmark")
        watermarkURL = restoreBookmark("watermarkBookmark")
        let restoredImages = restoreImageBookmarks()
        if restoredImages.isEmpty {
            reloadImages()
        } else {
            if defaults.bool(forKey: "usedIndividualImages") { folderURL = nil }
            images = restoredImages.map(ImageItem.init)
            selected = images.first
            status = "\(images.count) images restored."
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

    static func formatBytes(_ count: Int) -> String {
        let value = Double(count)
        return value >= 1_048_576 ? String(format: "%.1f MB", value / 1_048_576) : String(format: "%.0f KB", value / 1024)
    }

    static func sanitizedFilenameAffix(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "\0", with: "")
    }

    private func syncPresetSelections() {
        sizePreset = WatermarkSizePreset.allCases.first { abs($0.value - sizeFraction) < 0.0001 }
        opacityPreset = OpacityPreset.allCases.first { abs($0.value - opacity) < 0.0001 }
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var duplicatePresetName = ""
    @State private var showingOverwriteConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            previewPane
            Divider()
            controls
        }
        .sheet(isPresented: $isNamingPreset) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Preset").font(.headline)
                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitPresetName() }
                HStack {
                    Spacer()
                    Button("Cancel") { isNamingPreset = false }
                    Button("Save") { submitPresetName() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Choose Folder...") { state.chooseFolder() }
            Button("Choose Images...") { state.chooseImages() }
            if let folder = state.folderURL {
                Text(folder.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            if state.images.isEmpty {
                Spacer()
                Text("Choose a folder or select individual images to get started.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(state.images, selection: Binding(get: { state.selected }, set: { if let item = $0 { state.select(item) } })) { item in
                    HStack {
                        Thumb(url: item.url, size: 42)
                        Text(item.filename).lineLimit(1)
                    }
                    .tag(item as ImageItem?)
                }
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var previewPane: some View {
        VStack(spacing: 12) {
            ZStack {
                Color(NSColor.windowBackgroundColor)
                if let image = state.previewImage {
                    WatermarkPreview(image: image, state: state)
                } else {
                    Text("Select an image to preview.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            ScrollView(.horizontal) {
                HStack {
                    ForEach(state.images) { item in
                        Thumb(url: item.url, size: 64)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(state.selected == item ? Color.accentColor : .clear, lineWidth: 3))
                            .onTapGesture { state.select(item) }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 86)
            Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(minWidth: 500)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                presetLibrary
                GroupBox("Watermark image") {
                    HStack {
                        Button("Choose Watermark...") { state.chooseWatermark() }
                        if let url = state.watermarkURL { Thumb(url: url, size: 56) }
                    }
                }
                presetSection("Size", presets: WatermarkSizePreset.allCases, selected: state.sizePreset?.id, valueText: state.sizePreset?.label ?? "Custom") { preset in
                    state.sizePreset = preset
                    state.sizeFraction = preset.value
                }
                Slider(value: Binding(get: { state.sizeFraction }, set: { state.sizePreset = nil; state.sizeFraction = $0 }), in: 0.05...1.0)
                Text("\(Int(state.sizeFraction * 100))%").font(.caption)

                presetSection("Opacity", presets: OpacityPreset.allCases, selected: state.opacityPreset?.id, valueText: state.opacityPreset?.label ?? "Custom") { preset in
                    state.opacityPreset = preset
                    state.opacity = preset.value
                }
                Slider(value: Binding(get: { state.opacity }, set: { state.opacityPreset = nil; state.opacity = $0 }), in: 0...1)
                Text("\(Int(state.opacity * 100))%").font(.caption)

                Picker("Layout mode", selection: $state.layoutMode) {
                    ForEach(LayoutMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if state.layoutMode == .single { singleControls } else { tiledControls }
                Slider(value: $state.padding, in: 0...100) { Text("Padding") }
                Text("Padding \(Int(state.padding)) px").font(.caption)
                if state.layoutMode == .tiled {
                    Text("Padding: margin around each mark · Spacing: gap between tiles").font(.caption).foregroundStyle(.secondary)
                }

                Picker("Export format", selection: $state.exportFormat) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("Prefix", text: Binding(get: { state.outputPrefix }, set: { state.outputPrefix = AppState.sanitizedFilenameAffix($0) }))
                    TextField("Suffix", text: Binding(get: { state.outputSuffix }, set: { state.outputSuffix = AppState.sanitizedFilenameAffix($0) }))
                }
                if state.exportFormat == .jpeg {
                    Slider(value: $state.jpegQuality, in: 0...1)
                    Text("JPEG quality \(Int(state.jpegQuality * 100))%").font(.caption)
                }
                Text(state.exportFormat.hint).font(.caption).foregroundStyle(.secondary)
                if !state.estimatedSize.isEmpty {
                    Text("Estimated output size \(state.estimatedSize)").font(.caption)
                }
                if !state.estimatedFilename.isEmpty {
                    Text("-> \(state.estimatedFilename)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Watermark All Images") { state.exportAll() }
                    .disabled(!state.canExport)
                if let hint = state.exportHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                if state.isExporting { ProgressView(value: state.progress) }
            }
            .padding()
        }
        .frame(width: 340)
    }

    private var presetLibrary: some View {
        GroupBox("Presets") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Save current as preset...") {
                    presetName = ""
                    isNamingPreset = true
                }
                .disabled(!state.canSavePreset)
                if state.presets.isEmpty {
                    Text("No saved presets.").font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading) {
            Text("Position").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 3), spacing: 8) {
                ForEach(Anchor.allCases) { anchor in
                    Button { state.anchor = anchor } label: {
                        Image(systemName: anchor.symbol).frame(width: 32, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(state.anchor == anchor ? .accentColor : .secondary)
                }
            }
            HStack {
                TextField("X", value: $state.offsetX, format: .number).frame(width: 70)
                TextField("Y", value: $state.offsetY, format: .number).frame(width: 70)
            }
        }
    }

    private var tiledControls: some View {
        VStack(alignment: .leading) {
            Slider(value: $state.spacing, in: 0...400) { Text("Spacing") }
            Text("Spacing \(Int(state.spacing)) px").font(.caption)
            Picker("Rotation", selection: $state.rotationPattern) {
                ForEach(RotationPattern.allCases) { Text($0.rawValue).tag($0) }
            }
            if state.rotationPattern == .custom {
                TextField("Degrees", value: $state.customAngle, format: .number).frame(width: 90)
            }
        }
    }

    private func presetSection<P: Identifiable>(_ title: String, presets: [P], selected: P.ID?, valueText: String, action: @escaping (P) -> Void) -> some View where P.ID == String {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(valueText)").font(.headline)
            FlowLayout {
                ForEach(presets) { preset in
                    Button(label(for: preset)) { action(preset) }
                        .buttonStyle(.bordered)
                        .tint(selected == preset.id ? .accentColor : .secondary)
                }
            }
        }
    }

    private func label<P>(for preset: P) -> String {
        if let preset = preset as? WatermarkSizePreset { return preset.label }
        if let preset = preset as? OpacityPreset { return preset.label }
        return ""
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
                                .stroke(Color.accentColor.opacity(dragStart == nil ? 0.25 : 0.8), lineWidth: dragStart == nil ? 1 : 2)
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
            }
        }
    }

    private func displayedWatermarkRect(in size: CGSize) -> CGRect? {
        guard state.layoutMode == .single,
              let sourceSize = state.sourceImageSize,
              let watermarkSize = state.watermarkImageSize else { return nil }
        let scale = displayScale(in: size)
        guard scale > 0 else { return nil }
        let imageSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2)
        let frame = ImageProcessor.watermarkFrame(sourceSize: sourceSize, watermarkSize: watermarkSize, settings: state.settings)
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
            Color.gray.opacity(0.12)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) { image = ImageProcessor.thumbnail(for: url, maxPixelSize: size * 2) }
    }
}

struct FlowLayout<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading) { content } }
}
