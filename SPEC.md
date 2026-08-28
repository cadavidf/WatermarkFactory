# WatermarkFactory — Spec

A native macOS SwiftUI app, built and packaged as a `.dmg`, that batch-applies a
watermark image to every image in a chosen folder. Non-destructive: originals are
never modified, output always goes to a new `Watermarked/` subfolder.

## Target platform
- macOS 13+ (Ventura), SwiftUI + AppKit where needed.
- App-sandboxed with user-selected file read/write entitlement (NSOpenPanel /
  security-scoped bookmarks) — no other entitlements.
- Xcode project (not SPM-only), buildable via `xcodebuild -scheme WatermarkFactory
  -configuration Release build`.
- No third-party dependencies — Foundation/AppKit/SwiftUI/CoreImage/CoreGraphics only.

## Window layout (single window, three panes)
1. **Left sidebar** — source folder picker (button "Choose Folder…"), then a
   scrollable list of every image found in it (thumbnail + filename). Supports
   .jpg/.jpeg/.png/.heic/.tiff. Clicking an item selects it for the center preview.
2. **Center** — live preview canvas showing the *selected* source image with the
   watermark composited on top exactly as it will be exported, at current settings.
   Below it: a filmstrip of small thumbnails for every image in the folder so the
   user can page through previews without leaving the settings.
3. **Right sidebar** — controls, top to bottom:
   - **Watermark image** — "Choose Watermark…" button + thumbnail of the chosen
     watermark. Must accept PNG/transparent images.
   - **Size** — 5 clickable preset chips, each visibly distinct and labeled with
     both a plain-language tier AND the underlying %, e.g.:
     `Tiny (10%)` · `Small (20%)` · `Medium (35%)` · `Large (50%)` · `Full (75%)`
     ("%" = watermark's longest side as a fraction of the image's matching
     dimension). Selecting a chip highlights it. Below the chips, a fine-tune
     slider (5%–100%) that free-adjusts from whatever preset was last clicked —
     clicking a preset snaps the slider, dragging the slider deselects the chip
     highlight (shows "Custom").
   - **Opacity** — same pattern: 5 descriptive preset chips + slider, e.g.
     `Ghost (10%)` · `Subtle (25%)` · `Balanced (50%)` · `Bold (75%)` ·
     `Solid (100%)`. Slider range 0–100%, shown as a live percentage readout.
   - **Position** — a 3×3 grid of buttons (like a numpad) representing the 9
     anchor points (corners/edges/center) for single-placement mode. Selected
     anchor is visibly highlighted. Small numeric X/Y offset fields (in px) let
     the user nudge from that anchor.
   - **Layout mode** — segmented control: `Single` vs `Tiled`.
     - In `Tiled` mode, the 9-grid above is replaced/disabled and instead show:
       - Spacing slider (gap between tile repeats, px or % of watermark size).
       - Rotation pattern picker: `None (0°)`, `Diagonal (45°)`,
         `Alternating rows (0°/45° every other row)`, `Custom angle` (with a
         numeric degree field 0–359 when selected).
   - **Live preview** updates on every control change (debounced ~100ms is fine).
   - **Export format** — segmented/dropdown control: `Keep Original`, `JPEG`,
     `PNG`, `TIFF`. Default `Keep Original`. When JPEG is selected, show a
     quality slider (0–100%, default 90%) since JPEG is lossy. Show the format's
     typical traits inline as a one-line hint (e.g. JPEG: "smaller file, no
     transparency"; PNG: "lossless, supports transparency"; TIFF: "largest file,
     lossless, editing-grade").
   - Below the format picker, show a live **estimated output size** per image
     (or at least for the currently-selected preview image) — approximate is
     fine, computed from the actual encoded output of the preview image, updated
     whenever format/quality/watermark settings change. Label it "~X.X MB" (or
     KB) next to the format control.
   - **Export** — "Watermark All Images" button. Shows a progress bar/count
     while processing. Writes output as `<sourceFolder>/Watermarked/<original
     filename with new extension if format changed>`. `Keep Original` preserves
     original format where feasible (fall back to PNG for formats CoreImage
     can't re-encode, e.g. HEIC → PNG, and say so once in the UI). On
     completion, reveal the output folder in Finder and show a success summary
     ("12 of 12 images watermarked, total output size ~48.3 MB").
   - Persist last-used settings (watermark path via bookmark, size/opacity/
     position/tiling choices) across launches via UserDefaults, so reopening the
     app restores the previous session.

## Compositing rules
- Single mode: scale watermark to the chosen % of the *shorter* image dimension
  (keeps it sane on both portrait/landscape), keep aspect ratio, place at chosen
  anchor + offset, apply opacity.
- Tiled mode: repeat the (scaled + rotated) watermark across the full image on a
  grid defined by watermark size + spacing, applying opacity per tile. Tiles may
  extend past the canvas edge (clip at image bounds) — don't leave visible seams
  from rotation clipping oddly; simplest correct approach is fine (e.g. render
  tiles onto a CGContext sized to the image and let CoreGraphics clip).
- All compositing must be done at the source image's native pixel resolution
  (not the preview's display resolution) when exporting — preview may downscale
  for performance but export must not lose quality.

## Error handling (this touches file I/O — do not skip)
- No folder selected → Export button disabled with a hint label.
- No watermark selected → Export button disabled with a hint label.
- Empty folder / no supported images found → sidebar shows an empty-state message,
  not a silent blank list.
- A file that fails to load/decode/write during export → skip it, count it as a
  failure, continue the batch, and list failed filenames in the completion summary
  (never crash the batch over one bad file).
- Folder/watermark picked but permission revoked before export (sandboxed apps can
  lose access) → catch the error and show a clear "couldn't access X, please
  re-choose" message rather than crashing.

## Packaging
- Provide a `build_dmg.sh` script at the project root that:
  1. Builds the Release configuration via `xcodebuild`.
  2. Assembles a `.dmg` (via `hdiutil` — no external deps like create-dmg unless
     already on PATH, in which case prefer it for a nicer drag-to-Applications
     layout) named `WatermarkFactory.dmg` in a `dist/` folder.
  3. Is idempotent (safe to re-run, cleans up its own temp staging dir).
- App icon: simple placeholder is fine (a generated .icns from an SF Symbol or
  basic shape) — not a design priority for v1.

## Deliverable / done-criteria
- `xcodebuild -scheme WatermarkFactory -configuration Release build` succeeds
  with zero errors.
- `./build_dmg.sh` produces `dist/WatermarkFactory.dmg` that mounts and contains
  a working `WatermarkFactory.app`.
- Commit the working tree with git as you go (this is a git-tracked project,
  already `git init`'d at ~/Dev/WatermarkFactory).
- Write a short `README.md` covering: what it does, how to build, how to run the
  test build, known limitations (e.g. HEIC export caveat).

Do NOT ask clarifying questions back — every ambiguous point above already has a
stated default. If you hit a genuinely blocking ambiguity not covered here, make
the most sensible choice, note it in README.md under "Design notes", and continue.
