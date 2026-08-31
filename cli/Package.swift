// swift-tools-version:5.9
import PackageDescription

// Shares the real production source (symlinked, not copied) with the
// WatermarkFactory.app target -- this CLI runs the exact same
// ImageProcessor/scrubbedMetadata logic the GUI does, not a reimplementation
// that could silently drift out of sync with it.
let package = Package(
    name: "wf-metadata",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "wf-metadata")
    ]
)
