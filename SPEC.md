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

## Addendum: individual file selection (v1.1)
The left sidebar must offer TWO ways to build the working set, both visible at once:
- **"Choose Folder…"** (existing behavior) — picks a folder, lists every supported
  image inside it (non-recursive is fine, matches current behavior).
- **"Choose Images…"** (new) — opens an NSOpenPanel configured for files only
  (`canChooseFiles = true`, `canChooseDirectories = false`, `allowsMultipleSelection
  = true`), filtered to the same supported types (jpg/jpeg/png/heic/tiff). Adds the
  chosen files to the same sidebar list used for folder contents.
- Either action REPLACES the current working set (don't accumulate across separate
  folder/image picks — one picker's result is the new list), matching how the
  folder picker already behaves. Selecting via "Choose Images…" may pull files from
  different parent folders — that's fine.
- Output path rule becomes **per-image**, not per-folder: each processed image is
  written to `<that image's own parent folder>/Watermarked/<filename>`, regardless
  of whether it was picked via folder or individual selection. (This already matches
  what folder-picked images do today, since they all share one parent; just apply
  the same rule per-file so mixed-origin individual picks work correctly.)
- The "reveal in Finder" step after export should reveal the Watermarked folder of
  the first successfully-processed image (or, if all images share one parent, that
  single Watermarked folder — don't open multiple Finder windows).
- Sidebar empty-state text should mention both actions ("Choose a folder or select
  individual images to get started").
- Persisted last-session state should still restore sensibly even if last session
  ended on an individual-file selection (persist the list of file paths actually
  used, not just a folder path).

## Addendum: watermark padding (v1.2)
Add a user-adjustable **Padding** control to the right sidebar (near Position /
Layout mode) that keeps the watermark from sitting flush against edges or other
tiles. One slider, 0–100px, default 16px, live-numeric readout — applies
differently depending on layout mode:

- **Single mode**: padding is the minimum distance kept between the watermark and
  whichever image edge(s) the selected 9-grid anchor touches (e.g. top-left anchor
  pads both top and left edges; top-center pads only the top edge; center anchor
  ignores padding since it touches no edge). This is separate from, and applied
  before, the existing manual X/Y offset fields — padding sets the baseline
  distance from the edge, the offset then nudges further from there. Live preview
  must reflect this immediately.
- **Tiled mode**: padding is the transparent margin added around each individual
  watermark instance before it repeats — i.e. it increases the effective tile cell
  size beyond the watermark's own bounds, distinct from the existing tile
  "Spacing" slider (padding = margin hugging the watermark itself; spacing = extra
  gap between tile cells on top of that). Both controls remain visible and
  independent in Tiled mode.
- Persist the padding value in the same session-restore mechanism as the other
  watermark settings.
- Label it clearly as "Padding" with a one-line hint distinguishing it from
  Spacing when in Tiled mode (e.g. "Padding: margin around each mark · Spacing:
  gap between tiles").

## Addendum: output filename prefix/suffix (v1.3)
Add filename customization to the Export controls area, near Export format:
- Two optional text fields: **Prefix** and **Suffix** (both empty by default).
- Applied to every exported file's base name (before the extension), e.g. source
  `beach.jpg` with prefix `wm_` and suffix `_final` and format `Keep Original` →
  `wm_beach_final.jpg`. If the export format changes the extension (e.g. HEIC →
  PNG fallback, or an explicit JPEG/PNG/TIFF choice), the new extension is used
  after prefix/suffix are applied to the base name — extension logic is unchanged
  by this feature, only the base name changes.
- Sanitize both fields for filesystem safety: strip `/` and null bytes at minimum;
  no need for exhaustive validation beyond that.
- Live-update the existing single-image "estimated output size" preview area to
  also show what the resulting filename will look like for the currently
  previewed image (e.g. small caption under the estimate: "→ wm_beach_final.jpg"),
  so the user can confirm the pattern before running the batch.
- If prefix and suffix are both empty, behavior is unchanged from today (original
  base name kept).
- If two different source images would collide on the same output filename after
  prefix/suffix are applied (e.g. two folders' files landing in the same per-image
  Watermarked folder — shouldn't normally happen given the per-image parent-folder
  output rule, but guard anyway), append a numeric ` (2)`, ` (3)`, etc. suffix
  before the extension rather than silently overwriting.
- Persist prefix/suffix values in the same session-restore mechanism as other
  settings.

## Addendum: drag watermark with mouse (v1.4)
In the center live-preview canvas (Single layout mode only — Tiled mode has no
single draggable instance so leave it as-is there), let the user click-and-drag
the composited watermark directly on the preview to reposition it:

- On drag, translate the mouse delta (accounting for the preview's display scale
  vs. the source image's native pixel size) into updates of the existing X/Y
  offset fields — dragging is just a mouse-driven way to set the same offset
  state already used by the 9-grid anchor + manual offset fields, not a parallel
  positioning system. The offset number fields must update live as the user drags
  and remain the source of truth.
- Dragging does not change the selected anchor automatically — offset is relative
  to whichever anchor is currently selected, same as manual entry. If the drag
  would move the watermark distance in a direction that makes more sense from a
  different anchor, that's fine to leave as-is for v1 (don't auto-switch anchors).
- Clamp the drag so the watermark cannot be dragged fully outside the visible
  image bounds — always keep at least a small portion (~20% of the watermark) on
  canvas, so the user can't lose it off-frame.
- Show a subtle visual affordance that the watermark is draggable (e.g. cursor
  change to a "move" cursor on hover over the watermark region, or a light
  highlight border while dragging).
- This must feel live — no lag, update on every drag-changed event, not just on
  drag-end.
- Persist the resulting offset the same way the existing offset fields already
  persist.

## Addendum: watermark presets (v1.5)
Let the user save the current watermark configuration as a named preset and
reload it later, in the right sidebar (near the top, above/alongside the
watermark image picker):

- **Save current as preset…** button — prompts for a name (simple text-entry
  alert/sheet), then saves a snapshot of the full current watermark
  configuration: which watermark image (via security-scoped bookmark, same
  mechanism already used for session-restore), size %, opacity %, position
  anchor + X/Y offset, padding, layout mode (single/tiled) + tiled spacing +
  rotation pattern + custom angle, export format + JPEG quality, and filename
  prefix/suffix. Basically everything already covered by the session-restore
  persistence — a preset is a *named, saved* copy of that same state shape,
  not a new one.
- **Presets dropdown/list** — shows saved preset names; selecting one applies
  its full saved configuration immediately (updates every control + live
  preview). Include a way to delete a preset (e.g. a small trash icon next to
  each entry in the list, or a context menu / swipe-to-delete).
- Persist presets in UserDefaults (or a small JSON file in Application Support)
  as an array, independent of the single "last session" auto-restore state —
  presets must survive even after the user changes settings again post-load,
  they are a separate saved library, not tied to session restore.
- Duplicate names: if the user saves with a name that already exists, ask to
  overwrite (simple confirm) rather than silently duplicating or silently
  failing.
- No limit on preset count needed for v1; a plain scrollable list is fine if it
  grows long.
- This is purely a convenience/config-recall feature — it does not change any
  compositing or export behavior on its own.

## Addendum: "Optimize for Web" export option (v1.6)
Add a toggle/button in the Export controls area (near Export format), labeled
**"Optimize for Web"**:

- When enabled, exported images are downscaled (if larger) so their longest
  edge does not exceed a sensible web-optimal cap — use **2048px** as the max
  longest-edge dimension (a widely-used practical ceiling for full-bleed web
  images; images already smaller than this are left at their original size,
  never upscaled).
- When enabled and export format is `Keep Original` or `JPEG`, also nudge JPEG
  quality toward a web-friendly default (e.g. clamp/suggest ~80% if the user's
  current quality slider is set higher) — but don't fight the user: if they've
  explicitly set a quality value, respect it; only apply the web-friendly
  default quality when they haven't touched the slider this session, or show a
  one-time suggestion rather than silently overriding an intentional choice. If
  that nuance is hard to track cleanly, the simpler acceptable fallback is: when
  "Optimize for Web" is on AND format is JPEG, set quality to 80% and let the
  user still adjust it manually afterward if they want.
- Resizing happens at export time only (same as all other export transforms) —
  it must not affect the live preview's own display scaling logic, just the
  final written pixel dimensions.
- Show the effect in the existing "estimated output size" readout, since
  resizing should measurably shrink it.
- This is a single toggle, not a tiered set of presets — keep it simple: off
  (original size) or on (2048px-capped, web-friendly quality nudge for JPEG).
- Persist the toggle state in the same session/settings persistence as other
  export controls.

## Addendum: layout & visual design pass (v1.7)
Do a general polish pass across the whole window — no new functionality, purely
visual/layout quality. Things to specifically address:
- Consistent spacing/padding rhythm across all three panes (sidebar, preview,
  controls) — pick one spacing scale (e.g. 8/12/16/24px) and apply it
  consistently instead of ad hoc values accumulated across the incremental
  feature commits so far.
- Group related controls visually (e.g. with subtle section headers or
  dividers): Watermark source / Size & Opacity / Position & Padding / Layout
  mode / Export / Presets — so the right sidebar reads as organized sections,
  not one long undifferentiated stack of controls (this sidebar has grown a lot
  across v1.1–v1.6, revisit it holistically now).
- Make sure preset chips (size/opacity), the 9-grid position, and the new
  Optimize-for-Web toggle all look visually consistent with each other (same
  corner radius, consistent selected/unselected states, consistent
  typography weights for labels vs. values).
- Center preview area: make sure the filmstrip, the live preview canvas, and
  the drag affordance all have clear visual hierarchy (preview should dominate,
  filmstrip should read as secondary/thumbnail-scale navigation).
- Reasonable minimum window size so controls don't clip/overlap when resized
  smaller; sidebar(s) should not be resizable to the point of crushing labels.
- Keep using only system-native SwiftUI styling (no custom asset-heavy
  chrome) — the goal is tidiness and consistency, not a redesign of the visual
  language.
- Do not change any behavior/logic while doing this pass — if a visual change
  would require touching state/logic beyond trivial layout code, leave it and
  note it instead.

## Addendum: built-in platform export presets (v1.8)
Researched publisher photo specs for three Colombian real-estate portals (source:
public help/blog pages, Aug 2026 — no live API, so these are best-known-current
values, not guaranteed exact):

| Portal | Recommended size | Max file size | Notes |
|---|---|---|---|
| **FincaRaíz** | 860×482px (landscape) | 4.9 MB | horizontal orientation strongly preferred; avoids their frame cropping |
| **Metrocuadrado** | no official pixel spec published; use 1600×1200px (4:3 landscape) as a safe industry-standard fallback | ~5 MB (unofficial, matched to FincaRaíz's stated cap as a safe ceiling) | up to 20 photos/listing on most plans; min ~720px width for acceptable mobile quality |
| **100Cuadras (Ciencuadras)** | 1200×1200px (square — enables their zoom UI) | 2 MB | up to 20 photos/listing |

Add these as three **built-in export presets**, distinct from the user's own saved
watermark presets (v1.5) — they configure *output size/format*, not watermark
placement:
- Show them in the Presets area under a separate non-editable "Platform presets"
  section (or clearly labeled group) above/below the user's own saved presets —
  visually distinct so they're not confused with user-created ones, and not
  deletable/overwritable via the existing preset delete/overwrite UI.
- Selecting one sets: exact output pixel dimensions (resize + center-crop to the
  target aspect ratio if the source doesn't match, rather than distorting/
  stretching — preserve the subject, crop letterbox-style from center), export
  format to JPEG, and a JPEG quality chosen to comfortably land under that
  platform's max file size for a typical photo (start around 85% and note in a
  tooltip that actual size still depends on image content — this is an estimate,
  not a guarantee; the existing live "estimated output size" readout already
  gives real-time feedback so the user can see if they need to lower quality
  further).
- Selecting a platform preset does NOT touch the user's current watermark
  position/opacity/size/padding/tiling settings — only output size/format/quality
  fields change. This is the key difference from a regular saved preset (v1.5),
  which restores everything.
- Each platform preset shows a one-line source note on hover/tooltip, e.g.
  "FincaRaíz: 860×482px landscape, max 4.9MB — per fincaraiz.com.co guidance".
  For Metrocuadrado, be explicit in its tooltip that this is an inferred safe
  default since the portal doesn't publish an exact spec, not an official number.
- These are hardcoded/bundled in the app (not fetched live, not user-editable
  beyond what selecting them pre-fills — the user can still tweak size/format/
  quality afterward like any other export setting once a platform preset is
  applied).

## Addendum: export metadata scrubbing + attribution (v1.9)
**This touches PII (geolocation) — treat as security-relevant code, not just a
cosmetic feature. No shortcuts, and it needs failure-path test coverage (see
below).**

On every exported image, rewrite the metadata (EXIF/IPTC/XMP/any embedded
C2PA or AI-provenance manifest chunks) as follows:
- **Strip everything** by default: camera make/model, exposure/lens data,
  software/tool tags (including any pre-existing "ChatGPT"/"DALL-E"/"Midjourney"/
  other AI-generation provenance tags such as C2PA content-credentials blocks —
  these must be actively detected and removed, not just left alone), author/
  copyright fields, comments, thumbnails embedded in EXIF, and any other
  non-pixel metadata block.
- **Preserve exactly one category**: GPS/geolocation tags (EXIF GPS IFD — lat/
  long/altitude/timestamp-of-fix if present in the source). Copy these through
  unmodified from source to output. If the source has no GPS data, the output
  has none either (don't fabricate).
- **Then write new attribution metadata** identifying this app's output:
  - EXIF `Software` tag → `automality.com`
  - IPTC `CredCreator`/XMP `dc:creator` or `xmp:CreatorTool` → `automality.com`
  (use whichever of these ImageIO/CGImageDestination actually supports writing
  cleanly — pick the standard, well-supported tags rather than inventing custom
  ones; document which specific keys were used in README.md).
- This applies to every export path (Single and Tiled layout, every output
  format — JPEG/PNG/TIFF/Keep Original) — metadata handling must not silently
  no-op for any format CoreImage/ImageIO can write metadata into. For formats
  where ImageIO can't write a given block, skip it gracefully rather than
  crashing the export.
- Implementation: use ImageIO's `CGImageSourceCopyPropertiesAtIndex` /
  `CGImageDestinationAddImage(destination, image, properties)` metadata
  dictionary manipulation (not a hand-rolled binary EXIF parser) — this is the
  platform-native primitive for the job.
- **Required test coverage (failure/edge paths, not just the happy path)**:
  - Source image with GPS data → output retains identical GPS values.
  - Source image with NO GPS data → output has no GPS block (not zeros/nulls).
  - Source image with a fake/malformed EXIF blob → export doesn't crash, still
    produces a valid output image (strip what can't be parsed rather than
    aborting the batch).
  - Source image carrying a C2PA/AI-provenance marker → confirm it's absent from
    the output.
  - Confirm the `Software`/creator attribution tag is present and correct in the
    output regardless of source format.
  - Wire these as unit tests in the project (add an XCTest target if one doesn't
    exist yet) — this is a rejection/PII-adjacent path per project convention,
    it needs real test coverage, not just manual verification.
- Note the exact tag choices and their rationale in README.md under a new
  "Metadata handling" section.
