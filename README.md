# WatermarkFactory

WatermarkFactory is a native macOS 13+ SwiftUI app that batch-applies a watermark image
to every supported image in a folder. Originals are never modified — exports go to a
`Watermarked/` subfolder (or wherever you point the output). The same processing pipeline
also ships as a headless CLI (`wf-metadata`) for scripting and automation.

## What it does

- **Batch watermarking** — pick a source folder and a watermark image (PNG/JPEG/HEIC/TIFF),
  apply it across every supported image in the folder in one pass.
- **Placement** — 9-point anchor grid, additional anchors (stamp more than one corner),
  padding, fine offset, single or tiled layout, rotation (none / diagonal / alternating /
  custom angle), and a Smart Placement suggester that samples image luminance/saliency to
  recommend an anchor and tint that won't collide with the subject or wash out.
- **Intensity presets** — six named points from *Discrete* (barely-there, for polished work)
  through *Protective* (large, tiled, opacity 1.0 — resists cropping/cloning), each bundling
  size, layout style, and opacity so non-technical users don't have to reason about three
  sliders independently. A 2D matrix control (size × layout style, with opacity riding along)
  is available for manual tuning.
- **Tint** — force the watermark to a light or dark rendition, or keep it as-authored, so one
  watermark asset works over both bright and dark photos.
- **Remove watermark background** — for a watermark that wasn't prepared as a proper
  transparent PNG (a flat-color-filled export from a design tool), floods a solid/near-solid
  background out from the edges inward at compose time. Off by default; leaves the watermark
  untouched if the four corners don't agree on a background color (already transparent, or a
  complex/photographic image) rather than guessing.
- **Export formats** — Keep Original, JPEG, PNG, TIFF, single-frame GIF; JPEG quality slider;
  optional "optimize for web" cap (2048px longest edge); optional target max file size in KB
  (binary-searches JPEG quality, falls back to downscaling if quality alone can't hit it);
  explicit output pixel dimensions; filename prefix/suffix and optional numbering.
- **Metadata privacy** — original/hidden metadata (camera make, maker notes, AI-provenance
  descriptions, embedded thumbnails) is always stripped from exports. GPS location is a
  separate, explicit choice: remove entirely, reduce to ~1km precision, or keep exact
  coordinates. Attribution (`automality.com`) is written via IPTC Byline plus format-specific
  carriers (PNG/TIFF Software+Artist, JPEG EXIF UserComment — JPEG silently drops the TIFF
  dictionary in ImageIO, so it gets a second, verified-working carrier).
- **Conversational setup ("Chat mode")** — an optional guided flow that asks a short series of
  questions (style, extra anchors, padding, content type, file-size cap, destination platform,
  filename prefix) and turns the answers into concrete settings; backed by a local Ollama model
  when available, with a scripted fallback when it isn't.
- **Auto-update** — Sparkle-based; the app checks and installs its own updates.
- **Localization** — full English/Spanish string catalog (`Localizable.xcstrings`).
- **CLI** (`wf-metadata`) — the same pipeline, headless, for automation. See below.

## Build

```sh
xcodebuild -scheme WatermarkFactory -configuration Release build
```

Universal (Apple Silicon + Intel) builds require `xcodebuild archive`, not a plain `build`
— a plain build silently constrains to the host architecture regardless of the `ARCHS`
setting. Verify with `lipo -info` on the resulting binary before shipping.

## Package

```sh
./build_dmg.sh
```

The DMG is written to `dist/WatermarkFactory.dmg`.

## CLI (`wf-metadata`)

A separate Swift package at `cli/` that **symlinks** (not copies) the real production
source files — `ImageProcessor.swift`, `Models.swift`, `SecurityScopedAccessTracker.swift` —
from the main app target. The CLI and GUI run the exact same processing code and can't drift
apart.

```sh
cd cli
swift build
./.build/debug/wf-metadata \
  --source ~/Photos/listing \
  --watermark ~/Assets/logo.png \
  --size 0.13 --opacity 0.4 --anchor bottomRight \
  --format jpeg --optimize-for-web \
  --metadata-privacy remove \
  --remove-background
```

Run `wf-metadata --help` for the full flag list (source/watermark/output folders, size,
opacity, anchor, export format, optimize-for-web, max file size, metadata privacy level,
background removal, dry-run).

## Test

```sh
xcodebuild test -scheme WatermarkFactory -destination 'platform=macOS'
```

## Known Limitations

- `Keep Original` preserves JPEG, PNG, and TIFF extensions. HEIC sources export as PNG
  because this app intentionally avoids extra encoders.
- The output size estimate is computed from the currently selected preview image, not the
  entire batch.
- The app uses the standard macOS sandbox user-selected read/write entitlement only.
- Restored folders, image files, and watermarks keep long-lived security-scoped access while
  they are in use, so previews should render after relaunch without requiring the user to
  re-pick files. The actual sandbox relaunch behavior is manual-tested because XCTest cannot
  reliably simulate user-selected security-scoped bookmarks.
- Smart Placement's UI entry point is currently hidden (the underlying logic is intact) — the
  suggestions weren't reliable enough for this release.
- No MCP server yet — see `docs/architecture-go-rewrite.md` for what a CLI+MCP-first
  architecture would look like.
