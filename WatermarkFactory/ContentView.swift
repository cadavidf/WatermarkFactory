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
    @Published var offsetX = 24.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var offsetY = 24.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var layoutMode: LayoutMode = .single { didSet { saveSettings(); updateEstimate() } }
    @Published var padding = 16.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var spacing = 80.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var rotationPattern: RotationPattern = .diagonal { didSet { saveSettings(); updateEstimate() } }
    @Published var customAngle = 30.0 { didSet { saveSettings(); updateEstimate() } }
    @Published var exportFormat: ExportFormat = .keepOriginal { didSet { saveSettings(); updateEstimate() } }
    @Published var jpegQuality = 0.9 { didSet { saveSettings(); updateEstimate() } }
    @Published var previewImage: NSImage?
    @Published var estimatedSize = ""
    @Published var status = "Choose a folder and watermark to begin."
    @Published var progress = 0.0
    @Published var isExporting = false

    private var previewTask: Task<Void, Never>?
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
        WatermarkSettings(sizeFraction: sizeFraction, opacity: opacity, anchor: anchor, offsetX: offsetX, offsetY: offsetY, layoutMode: layoutMode, padding: padding, spacing: spacing, rotationPattern: rotationPattern, customAngle: customAngle, exportFormat: exportFormat, jpegQuality: jpegQuality)
    }

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

    func updateEstimate() {
        previewTask?.cancel()
        guard let source = selected?.url, let watermark = watermarkURL else {
            previewImage = selected.flatMap { ImageProcessor.thumbnail(for: $0.url, maxPixelSize: 900) }
            estimatedSize = ""
            return
        }
        let settings = settings
        previewTask = Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            let image = try? ImageProcessor.watermarkedImage(sourceURL: source, watermarkURL: watermark, settings: settings)
            let data = try? ImageProcessor.encodedWatermarkData(sourceURL: source, watermarkURL: watermark, settings: settings)
            await MainActor.run {
                if !Task.isCancelled {
                    self.previewImage = image.map { NSImage(cgImage: $0, size: .zero) }
                    self.estimatedSize = data.map { "~" + Self.formatBytes($0.count) } ?? ""
                }
            }
        }
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
                    let result = try ImageProcessor.export(sourceURL: item.url, watermarkURL: watermark, outputFolder: output, settings: settings)
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
    }

    private func restore() {
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
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: key)
        }
    }

    private func restoreBookmark(_ key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
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
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            previewPane
            Divider()
            controls
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
                    Image(nsImage: image).resizable().scaledToFit().padding()
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
                if state.exportFormat == .jpeg {
                    Slider(value: $state.jpegQuality, in: 0...1)
                    Text("JPEG quality \(Int(state.jpegQuality * 100))%").font(.caption)
                }
                Text(state.exportFormat.hint).font(.caption).foregroundStyle(.secondary)
                if !state.estimatedSize.isEmpty {
                    Text("Estimated output size \(state.estimatedSize)").font(.caption)
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
