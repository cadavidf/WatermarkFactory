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

## Addendum: preview before watermark chosen + max file size target (v2.0)

### Part A — show images before a watermark is selected
Currently the center preview / filmstrip may only render once a watermark image
is chosen. Fix this: as soon as a source folder or individual images are picked,
the sidebar thumbnails, filmstrip, and center preview must all show the plain
source image immediately (no watermark overlay, since there isn't one yet) —
never a blank/placeholder state just because no watermark has been picked. Once
the user picks a watermark, the preview updates live to show it composited, same
as before. The Export button can stay disabled with a hint until a watermark is
chosen (that's correct — you can't watermark without one) but *seeing* the
images must never depend on having picked a watermark.

### Part B — user-settable max output file size (KB)
Add a **"Max file size"** numeric field (in KB) to the Export controls, near the
existing format/quality controls, default empty/off (no cap). Example target:
`200 KB`. When set:
- Applies per-image at export time: after compositing, if the encoded output
  would exceed the target, iteratively reduce JPEG quality (binary search
  between e.g. 20%–95%) until it fits, or as close as reasonably achievable.
- If quality alone can't hit the target even at the low end (e.g. a very large
  source image with a tiny KB target), fall back to also downscaling the pixel
  dimensions in steps (e.g. 90% of previous size each step) and re-encoding,
  repeating until it fits or a sane minimum size floor is hit (don't downscale
  below ~400px longest edge — if it still doesn't fit at that floor, ship the
  smallest achievable result and flag that file in the completion summary as
  "couldn't reach target size" rather than looping forever or failing the
  batch).
- Format interaction: a max-KB target only makes sense with a lossy format.
  If the user has `PNG` or `TIFF` selected (lossless, can't be quality-adjusted
  down) AND a max file size is set, show an inline warning next to the field
  ("Max file size requires JPEG — switch format or clear this limit") and
  disable Export until resolved, rather than silently ignoring the size target
  or silently switching their format choice for them.
- Interacts with existing "Optimize for Web" toggle and platform presets: if
  both a 2048px cap (or platform preset's fixed dimensions) AND a max-KB target
  are active, both constraints apply — resize/crop first per those rules, then
  the quality/further-downscale loop still applies on top to hit the KB target.
- Update the live "estimated output size" readout to reflect the actual quality/
  size the target-fitting logic would produce for the current preview image,
  so the user can see it's working before running the full batch.
- Persist the max-file-size value in the same session/settings persistence as
  other export controls.
- Completion summary should note how many images (if any) couldn't fully reach
  the target and were shipped at their closest achievable size.

## Addendum: Automality design system adoption + Order & Rename stage (v3.0)

### Part A — adopt AutomalityUI
Add the local `AutomalityUI` Swift Package (at `~/Dev/AutomalityUI`, built
separately per its own SPEC.md) as a local path dependency of this Xcode
project. Restyle the existing UI to use it in place of default SwiftUI/system
styling:
- All primary action buttons (Choose Folder/Images/Watermark, Watermark All
  Images, Save Preset) use `AutomalityButtonStyle`.
- Each existing `ControlSection` (Watermark source / Size & Opacity / Position
  & Padding / Layout mode / Export / Presets) is rebuilt on `AutomalitySectionBox`
  so related controls read as a visually connected, labeled group — this is
  the "bounding box that shows what relates to what" the design pass is for.
- Replace ad hoc colors/spacing introduced by earlier iterative feature passes
  with the token set from AutomalityUI (8pt grid, teal/ink/offWhite palette,
  hard shadows, no rounded corners beyond the 2pt input allowance).
- Do not restyle the live preview canvas's own content (the composited photo
  preview) — only the chrome/controls around it.

### Part B — stage progress navigation
Add an `AutomalityProgressNav` across the top of the window with four stages:
**1. Select Images → 2. Watermark → 3. Order & Rename → 4. Export**. This
replaces (or sits above, if layout requires) the current always-visible
three-pane layout — the app becomes stage-driven: each stage shows the
relevant pane(s) for that step, and the nav lets the user jump back to any
already-visited stage (never forward-skip past the current furthest-reached
stage, per AutomalityProgressNav's own navigation rule). Concretely:
- **Stage 1 (Select Images)**: folder/image picker + thumbnail list (today's
  sidebar), advances automatically (or via a "Next" button) once at least one
  image is loaded.
- **Stage 2 (Watermark)**: today's watermark controls + live preview +
  filmstrip, advances once a watermark is chosen (Export itself still isn't
  triggered here — this stage is just for dialing in appearance).
  Reordering/renaming doesn't belong here.
- **Stage 3 (Order & Rename)**: the new feature described in Part C below.
- **Stage 4 (Export)**: today's Export section (format/quality/max file
  size/prefix/suffix/platform presets/Watermark All Images button) plus a
  summary of the chosen order so the user can confirm before running the
  batch.
- Settings/presets persistence, live preview, and all existing functional
  behavior from v1.x/v2.0 must keep working exactly as before — this is a
  navigation/layout restructuring, not a rewrite of underlying logic. Reuse
  the existing `AppState` and view logic; wrap/reorganize, don't reimplement.

### Part C — Order & Rename stage (new feature)
On Stage 3, show all loaded images in a grid (thumbnail per image, using the
existing `Thumb` view). The user assigns an export order two ways, both
available and interoperable:
- **Click-to-number**: clicking an unordered thumbnail stamps it with the next
  sequence number (starting at 1) as a visible badge overlay on the thumbnail.
  Clicking an already-numbered thumbnail again removes its number and shifts
  every later number down by one (so numbers stay contiguous, no gaps).
- **Drag-and-drop reorder**: images can also be dragged to reposition within
  the grid; the grid's visual left-to-right/top-to-bottom position IS the
  order (numbers renumber automatically to match position after a drag).
  Combine cleanly with click-to-number: dragging an unordered image into the
  ordered sequence assigns it a number at that position; dragging within the
  numbered sequence renumbers everyone between old and new position.
- A **"Clear order"** button resets all numbering (images become unordered
  again — export then falls back to today's default filename order, i.e. no
  sequence number applied).
- A **"Number in current order"** convenience button auto-assigns 1..N in the
  grid's current display order in one click (for the common case where the
  user just wants to number everything as currently sorted, without
  clicking/dragging each one).
- Images with no assigned number are visually distinct (dimmed/no badge) and
  are still exported — see filename rule below — they just don't get a
  sequence number prefix.
- **Filename rule (per user decision — number is ADDED to the existing
  filename, not a replacement)**: for a numbered image, the sequence number is
  prepended to the existing computed output filename (which already includes
  the user's prefix/suffix/format-extension logic from earlier versions), zero
  -padded to the width needed for the total numbered count (e.g. 01_, 02_...
  09_, 10_ for 10+ images; just the number if 1-9 total images, no padding
  needed — pick a sane padding width from the count of *numbered* images, not
  total images). Example: source `beach.jpg`, existing prefix `wm_`, assigned
  order 3 of 12 → `wm_03_beach.jpg` (number inserted right after the existing
  prefix, before the base filename; unordered images keep exactly today's
  `wm_beach.jpg` filename with no number). Update `ImageProcessor.outputFilename`
  accordingly, threading the assigned order value through.
- Persist the assigned order (as part of session state, keyed by image URL)
  the same way other settings persist, so it survives app relaunch as long as
  the same images are still loaded.
- Stage 4 (Export)'s summary should show "N of M images numbered" so the user
  can confirm before running the batch.

## Addendum: fix light/dark contrast regressions from v3.0 (v3.1)

**Root cause (confirmed via code read, not guesswork)**: `AutomalityButtonStyle`
and `AutomalityProgressNav` correctly use only fixed `AutomalityColor` tokens, so
they render consistently regardless of system appearance — that's why the top
progress nav is legible. But `ContentView.swift` was only partially migrated in
v3.0: many controls still use plain system-adaptive SwiftUI colors
(`.foregroundStyle(.secondary)`, `.buttonStyle(.bordered).tint(.secondary)`,
`Color(NSColor.textBackgroundColor)`, `Color(NSColor.controlBackgroundColor)`),
which resolve differently depending on whether macOS is in Light or Dark mode.
Since every `AutomalitySectionBox` is a *fixed* light `offWhite` panel with fixed
`ink` borders (never adapts), any leftover system-adaptive text/tint inside or
near those boxes can end up near-invisible (confirmed: on a system in Dark Mode,
`.secondary` resolves to a light color meant for dark backgrounds, rendering as
faint light-gray-on-light-offWhite — exactly the washed-out "Tiny (10%)" size
chips, "Opacity" readouts, and "1 images found." status text seen in the bug
report screenshot).

**The fix is NOT to add a dark theme** — the Automality brand spec (per its own
design tokens) is a fixed light palette, not an adaptive one. The fix is to
finish the migration: eliminate every remaining system-adaptive color reference
in `ContentView.swift` so the whole app is internally consistent and renders
identically regardless of the user's system light/dark setting (this guarantees
correct contrast in both, since the app's own colors never change).

Concretely:
1. **Sweep every `.foregroundStyle(.secondary)` in ContentView.swift** (status
   captions, value readouts, hints, "N images found" text, preset value labels,
   etc.) and replace with an explicit, sufficiently-legible Automality token —
   add a new semantic alias to AutomalityColor if useful (e.g.
   `AutomalityColor.inkMuted` = ink at reduced opacity, ~0.6, for secondary/
   caption text) so this doesn't need to be a one-off judgment call per site.
2. **Fix the preset chips** (`presetSection` in ContentView.swift: Size/Opacity
   Tiny/Small/Medium/Large/Full and Ghost/Subtle/Balanced/Bold/Solid) and the
   9-anchor position grid and any other `.buttonStyle(.bordered).tint(...)`
   controls — replace with a proper Automality-consistent chip style (can be a
   new small `AutomalityChipStyle`-equivalent added to ContentView.swift itself
   if it doesn't belong in the shared package, or promoted into AutomalityUI if
   it's clearly reusable) with explicit selected/unselected fill+text+border
   colors from the token set, never relying on `.secondary`/`.accentColor`.
3. **Fix `Color(NSColor.textBackgroundColor)` / `Color(NSColor.controlBackgroundColor)`**
   usages (live preview canvas background, filmstrip strip background) —
   replace with fixed Automality tokens (e.g. `gray100`/`offWhite`) so these
   panes don't flip to a jarring near-black in system Dark Mode while
   everything else stays fixed-light. The composited photo/watermark preview
   image itself is unaffected (it's real photo content, not a themed surface).
4. **Verify (don't just assume) the Part A behavior from v2.0 still holds after
   the v3.0 stage restructuring**: as soon as images are loaded, the live
   preview area must show the plain source image (or its thumbnail) even
   before a watermark is chosen — the screenshot shows a populated thumbnail
   next to what looks like an empty/blank center preview pane on the Watermark
   stage, which suggests this may have regressed during the v3.0 rework. Trace
   `previewImage`/`updateEstimate()` through the new stage-based view and fix
   if broken; if it turns out to be intentional/still-correct, leave it and
   just fix the background-color issue.
5. Placeholder/empty-state text (e.g. "Select an image to preview.") must use
   an explicit Automality ink-family color, not `.secondary`, so it's legible
   against the new fixed background from point 3.
6. After the sweep, there should be **zero** remaining references to
   `.secondary`, `.tint(.secondary)`, `Color(NSColor.textBackgroundColor)`, or
   `Color(NSColor.controlBackgroundColor)` in ContentView.swift — grep to
   confirm as part of verification.
7. This is a visual/contrast bug fix — do not change any functional behavior,
   export logic, or the stage/ordering features from v3.0 while doing this
   pass (same constraint as the earlier pure-layout polish pass).

## Addendum: Guided/Compact flow modes + Smart Placement (v3.2)

Decisions locked in (do not re-litigate these, implement as stated):
- Two full layout modes sharing the same `AppState`/logic: **Guided** (today's
  4-stage wizard) and **Compact** (dense single-screen, no stage gating).
- Smart Placement is suggest-then-apply — it NEVER changes settings without an
  explicit user click on "Apply".
- Watermark tint variants are generated at runtime from the single watermark
  image the user provides (no second asset required from them).
- Build all of this in one pass (not staged into a later request).

### Part A — Guided ⇄ Compact mode toggle
- Add a small Automality-styled segmented toggle (new `AutomalityModeToggle`-
  style control, can live in AutomalityUI or directly in WatermarkFactory if
  it's not clearly reusable elsewhere — your call) fixed at the top of the
  window, next to/above the existing `AutomalityProgressNav`.
- **Guided** = current v3.1 behavior exactly (4-stage wizard, nav, everything
  already built) — no regressions.
- **Compact** = single screen showing all three panes at once (source list /
  live preview+filmstrip / all controls including Order & Rename and Export),
  similar in spirit to the pre-v3.0 three-pane layout, but restyled with the
  Automality components already built (buttons, section boxes) — this is a
  new arrangement of existing views/state, not new functionality. Order &
  Rename's grid can be a collapsible `AutomalitySectionBox` within this layout
  rather than a separate stage.
- Persist the chosen mode (UserDefaults) same as other settings, so it's
  remembered across launches.
- Relabel Stage 3/4 in the Guided progress nav as "Reorder *(optional)*" and
  "Rename *(optional)*" — actually these are really one combined stage today
  ("Order & Rename"); split the *label* to make clear numbering-order is
  optional and doesn't block export, or add a visible "Skip" button on that
  stage that advances to Export without assigning any order (functionally
  this already works today since unordered images export fine — this is a
  labeling/affordance fix, not a logic change).

### Part B — Export format explainer
On the Export stage/section, expand the existing format hint text (currently
one line via `ExportFormat.hint`) into a slightly fuller inline explainer
covering practical guidance for real-estate-listing use, e.g.:
- JPEG: "Best for photos going to listing sites — small files, fast uploads,
  no transparency needed."
- PNG: "Use only if you need transparency or plan to edit further — much
  larger files, most listing portals don't need this."
- TIFF: "Archival/print-quality only — very large files, not for web upload."
- Keep this short (1-2 sentences per format, shown for the currently selected
  format, not all three at once) — don't turn this into a wall of text.

### Part C — Smart Placement (Vision-based suggestion)
Add a **"Suggest Placement"** button on the Watermark stage/section (both
Guided and Compact modes), enabled once both an image and a watermark are
loaded. On tap, analyze the *currently previewed source image* using Apple's
`Vision` framework (already available, no new dependency, no extra
entitlement needed — confirmed via existing sandbox entitlements) and produce
a proposal — NOT applied automatically:
1. **Saliency avoidance**: run `VNGenerateAttentionBasedSaliencyImageRequest`
   on the source image to get its salient-region bounding box. Among the 9
   anchor positions, prefer whichever anchor's watermark-placement rect has
   the least overlap with the salient region (ties broken toward the current
   anchor, to avoid needless suggestion churn).
2. **Optical centering / safe margin**: compute a recommended padding value as
   ~4% of the image's shorter dimension (a real minimum-margin rule, not a
   fixed px default) — if the anchor is `.center`, additionally offset the
   watermark ~5% of image height upward from literal geometric center (the
   classic "optical center sits above true center" design rule) via the
   Y-offset field, not a change to the centering math itself.
3. **Tint recommendation**: sample the average luminance of the source image's
   pixels within the proposed watermark placement rect. If dark (below a
   reasonable midpoint threshold), recommend an offWhite/light runtime variant
   of the watermark; if light, recommend the watermark as provided (or an
   ink-tinted dark variant if the original watermark is itself very light and
   would still be low-contrast against a light region). Generate the runtime
   variant via a `CIFilter`/`CGContext` luminosity-based recolor (not a new
   asset) — implement as a pure function so it's testable independent of the
   Vision call.
4. Show the proposal as a **preview overlay + explanation card** (e.g. "Move
   to top-right, increase padding to 32px, use light-tinted watermark — avoids
   the busiest part of your photo and improves contrast") with **Apply** and
   **Dismiss** buttons. Apply writes the suggested anchor/offset/padding/tint
   choice into the existing settings (reuses existing fields; tint becomes a
   new setting — see below). Dismiss discards the proposal with no changes.
5. **New setting**: add `watermarkTint: WatermarkTint` (`.original`, `.light`,
   `.dark`) to `WatermarkSettings`, defaulting to `.original` (today's
   behavior, unchanged unless the user applies a suggestion or picks a tint
   manually). Also expose it as a small manual control (segmented picker:
   Original/Light/Dark) near the watermark source picker, independent of
   Smart Placement, so a user can pick a tint without running the suggestion
   flow at all. `ImageProcessor.compose` must apply the selected tint to the
   watermark image before compositing.
6. Handle the no-saliency-result / analysis-failure case gracefully (Vision
   requests can fail on some images) — fall back to just the margin/tint
   heuristics without the saliency-avoidance step, never crash or block the
   UI; show a brief note if saliency specifically couldn't be computed.
7. Add unit tests for the pure, non-Vision-dependent logic: the luminance-
   sampling → tint decision function, the optical-center offset formula, and
   the safe-margin percentage calculation. Vision's actual saliency call
   itself doesn't need a unit test (it's a system framework call) but the
   "pick the anchor with least saliency overlap" comparison logic, given a
   fake bounding box, should be unit-testable.

### Verification
- Both app build and `WatermarkFactoryTests` must pass (use a derivedDataPath
  under /tmp).
- Guided mode must be pixel-for-pixel unchanged in behavior from v3.1 (only
  additive: the mode toggle, the Skip/optional labeling, the Suggest
  Placement button, the manual tint picker).
- Commit incrementally (Part A, then B, then C) rather than one giant commit.

## Addendum: fix missing security-scoped access for previews (v3.3)

**Bug (confirmed via code read)**: `WatermarkFactory` is sandboxed with the
`com.apple.security.files.user-selected.read-write` entitlement, meaning every
read of a user-selected file (outside the app's own container) requires an
active `startAccessingSecurityScopedResource()` session for that URL at the
moment of the read. Today, that call only happens in two places:
`exportAll()` (around the batch export loop) and `reloadImages()` (only for
the instant it lists a folder's contents). **Every other read path —
`Thumb`'s thumbnail generation, `updateEstimate()`'s live preview/estimated-
size generation, `ImageProcessor.imageSize`/`watermarkedImage` calls used for
the preview canvas — has no active access session**, so those reads can
silently fail (return nil), especially after an app relaunch when images are
restored purely from security-scoped bookmarks with no fresh NSOpenPanel
interaction. This is very likely the cause of a real bug report: after
relaunch, the status bar correctly said "1 images restored" but the preview
area showed "Select an image to preview" — the restored URL couldn't actually
be read for the thumbnail.

**The fix**: adopt the standard sandboxing pattern for URLs the app needs
*repeated, ongoing* read access to (not just a one-shot batch operation like
export) — start access once when a URL enters use and keep that access session
open for as long as the app is using that URL, rather than start/stop around
each individual read:
- When a folder is chosen/restored (`setFolder`, `reloadImages`, `restore()`'s
  folder-bookmark path) or individual images are chosen/restored
  (`setImages`, `restore()`'s image-bookmark path), or a watermark is chosen/
  restored (`setWatermark`, `restore()`'s watermark-bookmark path): call
  `startAccessingSecurityScopedResource()` on each URL and **keep it active**
  (don't stop immediately) — track which URLs currently have an open access
  session (e.g. a `Set<URL>` or per-URL flag in `AppState`).
- Stop access for a URL only when it's no longer in use: the folder/images are
  replaced by a new selection, the watermark is replaced, or on app
  termination (best-effort cleanup, e.g. via `NSApplication` termination
  notification or simply relying on process exit — don't over-engineer
  cleanup-on-quit, sandboxed access is automatically released when the process
  exits regardless).
- `exportAll()`'s existing start/stop-per-item pattern during the batch loop
  is fine to leave as-is (it's already correct for that one-shot operation)
  but should not conflict with or double-release access already held by the
  "keep it open" mechanism above — guard against double-stopping the same URL
  (e.g. don't call stop from both places for the same URL; check the tracked
  open-access set before stopping, or simply rely on the long-lived session
  covering export reads too and only stop what export itself explicitly
  started).
- This must work correctly across the exact repro sequence: launch app fresh
  → images/watermark restore from bookmarks → preview renders correctly
  without requiring the user to re-pick anything. Add this as a scenario in
  README.md's "Design notes"/known-limitations section if a full automated
  test of the actual sandboxed relaunch flow isn't practical in XCTest (real
  security-scoped bookmark behavior is hard to unit test in isolation) — but
  DO add a unit test for the access-tracking logic itself (e.g. "starting
  access for a URL twice doesn't double-count", "stopping access for a URL
  not currently tracked is a no-op", "replacing the current image set stops
  access for URLs no longer in the new set") using a lightweight fake/mock
  rather than real file URLs if that's the practical boundary.
- Verify manually if possible (not required for the automated test gate, but
  note in your summary whether you did): build, run, pick a folder+watermark,
  quit, relaunch, confirm the preview renders without any user action beyond
  launching.

This is a correctness bug fix — no other functional/visual behavior should
change. Verify both the app build and `WatermarkFactoryTests` pass (derived
data under /tmp).

## Addendum: Finder Quick Action — auto-run with last-used settings (v3.4)

Add a macOS Quick Action ("Watermark with Last Preset") that appears in
Finder's right-click menu on a selected folder (or image files), and runs
WatermarkFactory's export automatically using whatever watermark/settings
were last used — no app UI interaction required for the common case.

### Why not a custom URL scheme
The app is sandboxed with only `com.apple.security.files.user-selected.
read-write`, which grants read/write access exclusively to items the user
selected through the standard file picker (NSOpenPanel) or through Finder's
built-in "Open With" mechanism (Launch Services). A custom URL scheme
(`watermarkfactory://run?path=...`) passing a raw path string from an
external process would NOT carry that access grant — the sandbox would
block reads of that folder. The correct, sandbox-compliant mechanism is to
receive the folder via the app's standard file-open path (Finder "Open
With" / Automator's "Open Finder Items" action targeting this app), which
macOS automatically grants temporary read/write access for.

### Part A — app-side: handle being opened with a folder
- Add an `NSApplicationDelegateAdaptor` to `WatermarkFactoryApp` (a small
  `AppDelegate: NSObject, NSApplicationDelegate` class) implementing
  `application(_:open:)` (the `[URL]`-taking variant) to receive folder/
  image URLs Finder opens this app with.
- Register the app as able to open folders: add `CFBundleDocumentTypes` to
  Info.plist declaring it accepts `public.folder` (and the existing
  supported image UTIs: jpeg, png, heic, tiff) as document types, role
  `Editor` or `Viewer` — whichever is simpler; this is what makes "Open
  With → WatermarkFactory" and Automator's "Open Finder Items" action able
  to target this app at all.
- On receiving opened URL(s): if any is a directory, treat it exactly like
  `chooseFolder()`'s result (replace the working image set, same
  `setFolder` path) — if files, treat like `chooseImages()`'s result. Reuse
  existing `AppState` methods, don't duplicate logic.
- After loading: if a watermark is already set from the last-used/restored
  session settings (it will be, via the existing `restore()` logic, as long
  as the user has used the app at least once and picked a watermark before)
  AND `canExport` is true, **automatically call `exportAll()`** without
  requiring further user interaction — this is the whole point of the
  Quick Action, a true one-click/no-click batch run.
- If no watermark is set yet (first-ever use, nothing to reuse), do NOT
  silently fail or silently skip — bring the app to the foreground showing
  its normal UI with the folder already loaded, so the user can pick a
  watermark once; after that, subsequent Quick Action invocations will
  auto-run since the watermark is now remembered.
- **Auto-quit behavior**: if the app was launched fresh specifically to
  handle this open-URL event (i.e., it wasn't already running when the
  Quick Action was invoked — check via a flag set at launch, before the
  first `applicationDidFinishLaunching`), and the auto-run export completes
  successfully, quit the app automatically ~2 seconds after showing the
  completion status (matches "run it and it's done" automation feel). If
  the app was already open/running when invoked, don't auto-quit — just
  reveal the result normally, the user is already interacting with it.
- Keep existing manual UI flows (Choose Folder/Images buttons, stage
  navigation, etc.) completely unchanged — this is purely an additional
  entry point into the same `AppState`, not a parallel code path.

### Part B — the Quick Action itself (Automator workflow, built as a file,
not built by scripting Automator.app's UI)
- Build a `.workflow` bundle by hand (Automator workflow bundles are just a
  plist-based `Contents/document.wflow` + `Contents/Info.plist` inside a
  `.workflow` directory — no need to drive Automator.app's UI to create
  one) containing a single **"Open Finder Items"** action configured to:
  - Accept input: files or folders, from Finder.
  - Target application: `WatermarkFactory.app` (reference by bundle
    identifier, matching whatever `PRODUCT_BUNDLE_IDENTIFIER` the Xcode
    project already uses).
- Name the Quick Action **"Watermark with Last Preset"** — this is the
  label that will appear in Finder's right-click → Quick Actions submenu.
- Install it to `~/Library/Services/Watermark with Last Preset.workflow`
  (the standard per-user Quick Actions/Services location — no admin/signing
  requirement to install here, unlike `/Library/Services/`).
- Write a short install note in README.md: what the Quick Action does, that
  it requires having used the app at least once with a watermark set, and
  that it can be removed via System Settings → Extensions → General → Quick
  Actions, or by deleting the `.workflow` file directly.

### Verification
- Both app build and `WatermarkFactoryTests` must pass (derived data under
  /tmp). Add a unit test for the "which AppState method handles an
  opened-URL folder vs. file list" dispatch logic if it's factored as a
  testable pure function; the Quick Action installation itself isn't
  something XCTest can verify — note in your summary that it needs a
  manual right-click check in Finder, don't claim automated coverage of it.
- This is additive — no existing functional behavior changes.

## Chat flow mode — intent-driven Q&A over local Ollama (Phase 1 of 2)

Adds a third `FlowMode` — `.chat` — alongside Guided/Compact. Instead of
navigating stages via buttons, the user types what they want in plain
language ("watermark bottom right, subtle, for instagram") into a left-hand
chat panel; a local Ollama model maps that to `AppState` settings and the
app asks a follow-up question for whatever wasn't covered. This is
**intent-first, not button-first**: the app should propose a good default
branch of the settings tree for vague/short answers, while every control
Guided/Compact expose stays reachable for exact custom values — chat must
never be the only way to reach a setting.

Voice is explicitly out of scope for this phase (text only) — design the
input as a single `TextField`/`TextEditor` so a future voice-to-text layer
is a drop-in replacement for how the text arrives, not a UI redesign.
**An MCP server (a separate process letting an external agent like Claude
drive the app) is Phase 2 — do not build it in this pass.** This phase is
the in-app chat wizard only.

### Model: `IntentParser`

New file `WatermarkFactory/IntentParser.swift`. A small async service, not
a general chat client — it exists to map one free-text message plus "what
slots are still unanswered" into structured `AppState` updates.

```swift
struct IntentSlots: Codable {
    var anchor: String?          // one of Anchor.allCases rawValue, or "tiled"
    var sizeFraction: Double?    // 0.05...0.6
    var opacity: Double?         // 0...1
    var tint: String?            // WatermarkTint rawValue
    var exportPlatform: String?  // "instagram" | "web" | "print" | "original"
    var renamePrefix: String?
    var needsClarification: [String]  // slot names the model could not infer
    var assistantReply: String        // one short sentence to show back to the user
}
```

- Call `POST http://localhost:11434/api/chat` with `model: "gpt-oss:20b"`,
  `stream: false`, `think: false` (per this project's known-good pattern —
  `gemma4:26b`/`gemma3` chat is broken on this machine, see
  `~/bin/check-ollama`; `gpt-oss:20b` is confirmed working via a manual
  `curl` test this session). Read `message.content` — ignore/discard any
  `message.thinking` field if present.
- System prompt: enumerate the slot names above, their valid values (pull
  straight from `Anchor`, `WatermarkTint`, etc.'s `CaseIterable` cases so
  the prompt can't drift out of sync with the real enums), and instruct the
  model to reply with **only** a JSON object matching `IntentSlots` — no
  prose outside the JSON. Decode with `JSONDecoder`; if decoding fails,
  treat it as "could not parse" (see fallback below), don't crash or retry
  silently more than once.
- **Offline/unreachable fallback is required, not optional**: if Ollama
  isn't running or the request errors/times out (use a real timeout, e.g.
  10s — cold model load was ~10s in this session's test, budget for that
  once then assume warm), fall back to the existing scripted one-question-
  at-a-time flow (a fixed `[ChatQuestion]` array walked in order, each with
  quick-reply chips, no NLP) rather than leaving the user stuck. Surface
  this in the transcript once ("Working offline — I'll ask a few quick
  questions instead.") not as a silent degradation.

### Preset branches (the "good default" tree)

A small table of named presets the parser/UI can suggest for common intents
— each preset is just a bundle of the same `AppState` values Guided/Compact
already set, nothing new at the settings layer:

- `cornerSubtle` — anchor `.bottomRight`, size 0.18, opacity 0.5, tint
  `.original` — the default when intent is vague ("just watermark these").
- `centeredBold` — anchor `.center`, size 0.35, opacity 0.85.
- `tiledBrand` — `layoutMode = .tiled`, rotation `.diagonal`, spacing 80.
- Platform → export mapping: `instagram`→ existing Instagram preset in
  `platformPresets`, `web`→`optimizeForWeb = true`, `print`→ `.tiff`/no
  size cap, `original`→ `exportFormat = .keepOriginal`.

When the parser returns a slot as `nil` (not mentioned and not inferable),
apply the matching preset default rather than leaving the setting at
whatever it happened to be — the whole point is one deliberate default
branch, not silent inheritance of stale state from a previous session.

### UI: `ChatFlowView`

New file `WatermarkFactory/ChatFlowView.swift`, wired into `ContentView`'s
`stageContent`/mode switch as a full left-hand panel (mirrors where
`compactContent`'s image list column sits — chat replaces that column,
`previewPane` stays on the right, unchanged).

- Scrolling transcript: assistant bubbles (question/confirmation text) and
  user bubbles (what they typed or which chip they tapped), oldest to
  newest, auto-scrolls to bottom on new message.
- Each assistant bubble that's still awaiting an answer shows the relevant
  quick-reply chips inline (`AutomalityChipStyle`, matching Guided's visual
  language) **and** a "Customize…" disclosure that expands the actual
  underlying control (the 9-grid, the opacity slider, etc. — reuse the
  existing `positionPaddingSection`/`sizeOpacitySection` view pieces rather
  than rebuilding them) for anyone who wants an exact value instead of a
  preset.
- Bottom-anchored text input + "Send" button (`.automalityAccent` — this is
  the flow's one continue action, consistent with the Next-button fix
  earlier this session). While a request is in flight, show a lightweight
  "thinking…" state on the send button (disabled, not a full-screen
  spinner) — first real request can take ~10s (cold model load).
- Once every slot has an answer (or the user explicitly says "just export"/
  taps a "Skip remaining, use defaults" chip), advance to the Export stage
  exactly like Guided mode's Next button does — don't build a parallel
  export path.

### `AppState`/`Models.swift` changes
- Add `case chat = "Chat"` to `FlowMode`.
- Add a `chatTranscript: [ChatMessage]` published property (`ChatMessage`:
  `id`, `role` (.assistant/.user), `text`, optional `chips: [String]`) so
  the transcript survives stage navigation within a session (not persisted
  across launches — this is working conversation state, not a setting).

### Verification
- Unit-test `IntentParser`'s JSON-decoding path with fixed sample model
  output strings (both well-formed and malformed) — this doesn't need a
  live Ollama call to test the parsing/fallback logic, only the actual
  network call itself is manual/live-only.
- Unit-test the preset-application logic (`cornerSubtle` etc. → correct
  `AppState` values) as a pure function, same pattern as existing
  `ImageProcessorMetadataTests`.
- `WatermarkFactoryTests` must still pass in full (currently 15 tests) —
  this is additive, don't touch existing Guided/Compact code paths.
- Manual verification only for: an actual live chat exchange against
  Ollama, and the offline-fallback path with Ollama stopped — note in the
  summary that these need a human to actually run the app, same caveat as
  this file's Quick-Action section above.


## Chat flow mode — Phase 1b: padding, multi-corner, reorder, max size, content-type format

Refinements to Phase 1 (already built and committed) based on review of the
full question tree. Five additions, all bounded — no new export pipeline
(video export was discussed and explicitly deferred to a separate future
phase; do not touch video/AVFoundation in this pass).

1. **Padding as its own explicit chat question** — it's a real, frequently-
   adjusted setting (`WatermarkSettings.padding`) that Phase 1's question
   list never surfaces. Add a question after placement: "How much padding
   from the edge?" with chips "Tight (8px)" / "Default (16px)" / "Generous
   (32px)", plus free-text accepts a bare number as pixels.

2. **Multiple simultaneous positions (niche, opt-in)** — add
   `var additionalAnchors: [Anchor] = []` to `WatermarkSettings` (default
   empty = today's single-anchor behavior, completely unchanged for
   existing presets/tests). When non-empty, `ImageProcessor.compose` draws
   the watermark at `settings.anchor` **and** at each entry in
   `additionalAnchors`, same size/opacity/tint each time — factor the
   existing single watermark-placement-and-draw block into a small helper
   so it can loop over `[settings.anchor] + settings.additionalAnchors`
   instead of duplicating the draw logic. In chat, this is opt-in only —
   the placement question's chips stay single-choice; a follow-up "Add it
   to another corner too?" only appears after the first placement answer,
   default declined.

3. **Reorder step** (was missing from Phase 1's question list) — add a
   `reorder: String?` slot (`"byCurrentOrder"` or `"skip"`) to `IntentSlots`
   and a chat question "Number these in the order shown, or skip
   numbering?" with chips "Number them" / "Skip" — wires to the existing
   `state.numberInCurrentOrder(state.orderedItems)` / no-op, exactly like
   `orderRenameHeader`'s buttons. This is presentation only; don't touch
   the reorder logic itself.

4. **Max file size step** (also missing) — add `maxFileSizeKB: Double?` to
   `IntentSlots`, question "Cap the file size per image?" with chips
   "No limit" / "500 KB" / "200 KB", free text accepts a bare KB number.
   Because `AppState.maxFileSizeBlocksExport` already blocks export when
   this is set with PNG/TIFF, if the parser's `contentType` (see below)
   implies PNG or TIFF, don't ask this question at all — skip straight
   past it — rather than setting a value the app will then refuse to
   export with.

5. **Content-type-driven export format** — add
   `case gif = "GIF"` to `ExportFormat` (static single-frame only; give it
   a `hint` string same style as the others: e.g. "Single-frame GIF —
   simple, widely supported, no transparency gradient."). In
   `ImageProcessor.resolvedFormat`, add `case .gif: return (.gif, "gif",
   false)` (import `UniformTypeIdentifiers`' `.gif` — confirm it exists in
   the SDK before assuming; if not, use
   `UTType("com.compuserve.gif")!`). Add a new `contentType: String?` slot
   to `IntentSlots` (values: `camera`, `graphic`, `geoData`, `gif`,
   `other`) with its own chat question: "What kind of images are these? —
   Camera photos / Logos or screenshots / Geo or technical data / GIFs /
   Not sure". Map: `camera`→`.jpeg`, `graphic`→`.png`, `geoData`→`.tiff`,
   `gif`→`.gif`, `other`/unset→`.keepOriginal`. This format choice takes
   precedence over whatever `exportPlatform` (instagram/web/print) would
   otherwise set for format — `exportPlatform` still governs
   dimensions/quality/optimizeForWeb, `contentType` governs the format
   itself. Update `IntentPreset.applyPlatform`/`settings(from:)` so
   `contentType`, when present, is applied *after* the platform mapping so
   it wins the format field specifically (don't let it clobber the
   dimension/quality fields platform already set).

### Verification
- Extend `IntentParserTests` with cases for: `contentType` → correct
  `exportFormat`, `contentType` set alongside `exportPlatform: "instagram"`
  (format should follow contentType, dimensions should follow instagram),
  `additionalAnchors` round-tripping through `settings(from:)`.
- Add one `ImageProcessor`-level test exporting through the new
  `.gif` case if there's an existing fixture image to reuse (match however
  `testExactOutputSizeUsesRequestedPlatformPixels` or similar is set up) —
  if no fixture exists and building one is disproportionate, note that gap
  explicitly in your summary rather than skipping silently.
- All existing tests (19 as of Phase 1) must still pass unchanged.
- `xcodebuild ... build` and `... test` tails, same as Phase 1's
  verification section.


## Chat flow mode — Phase 2: tiered local backend, no Ollama dependency

Replaces Phase 1's Ollama-backed `IntentParser` (kept working until this
lands, then removed) with three tiers the user picks between on first use
of Chat mode. **No "bring your own OpenAI-compatible endpoint" tier in this
pass** — explicitly deferred; that needs Keychain-backed credential storage
and its own appsec-mode review later.

### Tiers, in preference order
1. **Apple Foundation Models** (macOS 26+, Apple Intelligence-enabled Mac,
   user has it turned on) — zero download, zero setup, silently used if
   available. Check via `SystemLanguageModel.default.availability` from
   Apple's `FoundationModels` framework (or the `MLXFoundationModels`
   bridge product in `mlx-swift-lm` if it wraps this more conveniently —
   inspect that package's actual API before committing to one or the
   other, don't guess).
2. **Downloaded local model** (MLX Swift, Apple Silicon only) — one-time
   ~1.8GB download of `mlx-community/Llama-3.2-3B-Instruct-4bit` via
   `LLMRegistry.llama3_2_3B_4bit`, run in-process afterward. Chosen for
   officially-documented Spanish + English support (Meta lists Spanish
   among Llama 3.2's 8 supported languages) — this app needs to handle
   Spanish-language chat input, not just English.
3. **Scripted fallback** (already built in Phase 1/1b, `ChatFlowView`'s
   `applyScripted`) — always available, zero dependency, no changes needed
   here beyond keeping it reachable.

### Package dependency
Add `https://github.com/ml-explore/mlx-swift-lm` as an SPM dependency,
products `MLXLLM` and `MLXLMCommon` (and `MLXFoundationModels` if tier 1's
check is cleaner through it — verify at implementation time). This is
Apple Silicon-only; on Intel Macs, tiers 1-2 are simply unavailable and the
app goes straight to tier 3 — check `#if arch(arm64)` or the equivalent
runtime capability check, don't let this crash on an Intel build.

### `IntentBackend` abstraction
Define a protocol so `ChatFlowView` doesn't care which tier is active:
```swift
protocol IntentBackend {
    func parse(message: String, unansweredSlots: [String]) async throws -> IntentSlots
}
```
`FoundationModelBackend` and `MLXBackend` both conform, reusing the same
system prompt / `IntentSlots` JSON contract `IntentParser.systemPrompt`
already defines in Phase 1 (don't redesign the prompt or slot schema —
only the transport/inference layer changes). Move `IntentParser`'s
existing prompt-building logic into a shared place both backends call.

### Onboarding flow (new, in `ChatFlowView` or a small new
`ChatBackendSetupView`)
- On first navigation to the Chat tab in a session: silently check tier 1.
  If available, use it — no prompt, ever.
- Else, check if the MLX model is already cached on disk from a prior
  session (`LLMModelFactory`/`HubClient`'s local cache — check its API for
  how to test this without triggering a download). If cached, use it
  silently too.
- Else, show a one-time sheet: "Chat mode uses a small local AI model to
  understand what you type (~1.8GB one-time download, runs fully on this
  Mac afterward)." with two choices: **"Download and start"** / **"Skip —
  use simple click-through questions instead."**
  - Download: show real progress from the loader's progress handler
    (percentage or bytes/total, whichever the API actually exposes — don't
    fake a progress bar), a Cancel button that aborts cleanly, and on
    completion transitions straight into the first chat question.
  - Skip: proceeds with the scripted tier for this session.
- Persist the resulting choice in `UserDefaults`
  (`chatBackendPreference: "foundationModel" | "mlxDownloaded" |
  "scriptedOnly"`) so the sheet doesn't reappear on next launch. Add a
  small, low-emphasis "Change chat AI settings..." link somewhere in the
  Chat panel (footer is fine) so the user can revisit this later — e.g. a
  Skip user who changes their mind, or to re-trigger a download that was
  cancelled.

### Removal
Delete `WatermarkFactory/IntentParser.swift`'s Ollama HTTP-calling code
(`URLSession` POST to `localhost:11434`, `OllamaRequest`/`OllamaResponse`)
once `FoundationModelBackend`/`MLXBackend` replace it — keep
`IntentParser.decodeSlots`/`systemPrompt`/`slotNames` if they're reused by
the new backends, delete the rest. Update `IntentParserTests` accordingly;
its existing JSON-decoding/preset tests should still pass unchanged since
`IntentSlots`/`IntentPreset` aren't touched by this phase.

### Verification
- This phase's live paths (real Foundation Model call, real ~1.8GB MLX
  download + inference, the progress UI, cancel-mid-download) are
  **manual-only** — note explicitly in your summary which parts you could
  not verify by running `xcodebuild test`, same as this file's existing
  "manual verification only" notes elsewhere. Do not claim these work
  end-to-end without having actually run them.
- What CAN be unit-tested without live downloads: `ChatBackendPreference`
  persistence round-trip, the tier-selection logic given mocked
  availability states (Foundation Model available / MLX cached / neither),
  and that `IntentBackend` conformances compile and satisfy the protocol
  (a fake/mock `IntentBackend` fed to `ChatFlowView` to test its UI logic
  without a real model, if the view's structure allows injecting one —
  refactor for that testability if it doesn't already).
- All existing tests (23 as of Phase 1b) must still pass.


## Phase 3: Quick Tasks — crop/resize and package, no watermark, no LLM

**Do not start this phase until Phase 2 is merged and verified** — both
touch the same core files and running concurrently will corrupt each
other's edits.

Not everyone opening this app wants to watermark anything — some just need
an image cropped/resized to fit somewhere, or a folder of already-processed
images bundled into one file to attach/upload. Forcing those people through
watermark-flavored questions (or, worse, an LLM chat) is exactly the wrong
shape. This phase adds a lightweight, deterministic path that needs no
model at all.

### Top-level goal picker
Before `flowMode` (Guided/Compact/Chat), add a `WorkflowGoal` choice shown
once per session on Select Images: **Watermark** / **Crop or resize** /
**Just package what I have**. Watermark keeps every existing behavior
completely unchanged (this is additive, not a restructuring of the current
flow). The other two skip straight past all watermark-related
sections (`watermarkSourceSection`, `sizeOpacitySection`,
`positionPaddingSection`, layout/tiling) — those views simply aren't shown,
not disabled/greyed.

### Crop/resize (freeform drag tool)
- New `CropOverlayView`: a draggable, resizable rectangle over
  `previewPane`'s image, with corner/edge drag handles. Aspect ratio: free
  by default, with quick-lock chips (1:1, 4:5, 16:9, "Custom WxH" text
  entry) — reuse `AutomalityChipStyle` for consistency with the rest of the
  app.
- The crop applies as one **normalized rect** (0...1 in both axes, not
  pixels) stored once and applied identically to every image in the batch
  by default — this is a batch tool, re-asking per image defeats the
  "fewer questions" goal. Add a small per-thumbnail "Adjust this one..."
  affordance in the image list for the person who does need one exception,
  rather than a mandatory per-image step.
- `WatermarkSettings` gains `var cropRect: CGRect?` (nil = no crop, default
  everywhere else). In `ImageProcessor`, apply
  `source.cropping(to: pixelRect)` (CGImage's native crop, translate the
  normalized rect to that image's actual pixel dimensions) as the very
  first step in `export`/`compose`, before anything else — so if this goal
  is later combined with watermarking, watermark placement is relative to
  the cropped result, not the original frame.

### Output packaging (a new shared final step — applies to ANY goal)
After the existing per-file export completes (unchanged), offer one
additional choice, not gated to Crop/Package goals — useful after
watermarking too: **Individual files** (today's only behavior, stays
default) / **.zip** / **PDF, one image per page**.
- `.zip`: shell out via `Process` to `/usr/bin/zip -r -q <output>.zip
  <exported files>` (present on every Mac, no new dependency) rather than
  linking Apple's Archive framework for one call site — simpler, and this
  is a one-shot batch operation, not something needing streaming/progress.
- PDF: build with `CGContext(consumer:...)`'s native PDF page support —
  one page per image, page size set to exactly that image's pixel
  dimensions (points = pixels at 72dpi is fine for this use case; note in
  code that this isn't print-resolution-accurate, it's "fits without
  cropping or letterboxing," which is what "just needs them to fit
  somewhere" actually means) so nothing is cropped or padded.

### Verification
- Unit test crop-rect-to-pixel-rect translation (a pure function, several
  image dimensions × normalized rects).
- Unit test the zip/PDF packaging functions against a small set of fixture
  images already in the test target (reuse whatever
  `ImageProcessorMetadataTests` already sets up) — verify the produced
  .zip contains the expected file count/names (`Foundation`'s `URL`-based
  zip inspection, or shell `unzip -l` via `Process` in the test itself if
  simpler) and the PDF has the expected page count
  (`PDFDocument(url:)?.pageCount` from PDFKit).
- All prior tests must still pass.


## Auto-update (Sparkle)

App ships as a signed dmg via GitHub Releases, not the Mac App Store — no
built-in update mechanism exists today, users have to notice a new release
and manually re-download. Add Sparkle (`https://github.com/sparkle-project/
Sparkle`, SPM dependency, current major is 2.x), the de facto standard for
this exact distribution shape.

### Package + wiring
- Add Sparkle as an SPM package dependency (`SparkleCore`/`Sparkle`
  product — check the package's actual product name at implementation
  time, don't assume).
- `WatermarkFactoryApp.swift`'s `AppDelegate` gets an
  `SPUStandardUpdaterController` (Sparkle's ready-made controller — don't
  hand-roll the update-check/download/relaunch flow, that's exactly what
  this type exists for), created in `applicationDidFinishLaunching`, with
  `startingUpdater: true` **unless** the app was launched via the
  Finder-Quick-Action auto-run path (`didFinishLaunching` check already
  exists for that in `AppDelegate` — an update check firing during a
  silent, auto-quitting batch run would be surprising and could block the
  auto-quit on a downloaded-update prompt; skip starting the updater in
  that path, still check normally on an interactive launch).
- Add a "Check for Updates…" menu item wired to
  `updaterController.checkForUpdates(_:)`, in whatever menu the app's
  existing menu bar customization (if any) lives, or the default
  Help/App menu if none — check `WatermarkFactoryApp.swift`'s `Scene` for
  any existing `.commands {}` block before adding a new one.

### Appcast + signing
- Generate an EdDSA key pair via Sparkle's bundled `generate_keys` tool
  (ships in the package's `bin/` after SPM resolves it, or via `brew
  install sparkle` if that's easier to invoke standalone). **The private
  key must never be committed to git** — store it in Keychain or a local
  file outside the repo, document where in README.md, and treat generating
  it as a one-time manual step you report back on rather than something
  to automate blindly.
- Embed the **public** key in `Info.plist` as `SUPublicEDKey`, and the feed
  URL as `SUFeedURL`.
- Host `appcast.xml` alongside releases — simplest: commit it into the
  `WatermarkFactory` repo itself (e.g. `docs/appcast.xml`) and serve via
  GitHub Pages, or generate it fresh on each release and attach it as a
  release asset with a stable raw-GitHub-content URL
  (`raw.githubusercontent.com/cadavidf/WatermarkFactory/main/appcast.xml`)
  — pick whichever needs less new infrastructure, note the choice and why
  in your summary.
- Each release needs: the dmg (already produced by the existing
  build+sign+package steps — no change there), an EdDSA signature over
  that dmg (Sparkle's `sign_update` tool), and an appcast entry with
  version, minimum system version, release notes, and the signed download
  URL. This should become a repeatable step in whatever script/process
  currently runs `gh release create` — extend it, don't hand-write the XML
  each time.

### Verification
- Unit-testable: none of this is meaningfully unit-testable (Sparkle's own
  update-check/download/install flow is the library's job, not this app's
  code) — say so plainly rather than inventing a test for it.
- Manual-only, and genuinely needs a real two-version test: build v1.1.2
  with this integrated, publish an appcast pointing a fake "v1.1.3" at a
  real signed dmg, launch v1.1.2, and confirm Sparkle's update UI actually
  offers and installs it. This is the one piece of this whole session that
  can't be verified any other way — flag it clearly as unverified until
  that manual pass happens, the same way the Chat mode fix was flagged
  unverified until it was actually run live.
- `xcodebuild build`/`test` tails as usual; all 24 existing tests must
  still pass.


## Spanish localization (proper internationalization, not just Chat mode's existing Spanish input parsing)

This app has **zero** localization infrastructure today — no String Catalog,
no `*.lproj` folders, no `CFBundleLocalizations` in Info.plist. Chat mode's
`IntentParser` already understands Spanish *input* (verified live earlier
this session), but that's unrelated to this task: every button label,
section title, hint, alert, and menu item in the actual UI is a hardcoded
English string literal. This adds real UI internationalization.

**Note on tooling**: this was meant to be a two-tool pass (codex for the
infrastructure, gemini for translation quality) but the `gemini` CLI is
currently blocked on a `GOOGLE_CLOUD_PROJECT` auth gap in this environment
(confirmed failing again just before writing this spec). Do both parts
yourself rather than leave translation quality unaddressed — but flag any
string you're genuinely unsure how to translate naturally (idiom, brand
terms like "Watermark Intensity", technical terms like "clear space")
rather than guessing silently.

### Infrastructure
- Add a String Catalog (`WatermarkFactory/Localizable.xcstrings`, Xcode 15+
  format) to the project, registered in the Resources build phase the same
  way `Assets.xcassets`/the bundled watermark PNG were added (see recent
  git history for the exact PBXFileReference/PBXBuildFile pattern this
  project uses for adding new resources by hand-editing `project.pbxproj`
  — this project isn't opened in Xcode's GUI during this work, so the file
  needs to be added the same manual way).
- Set `knownRegions = (en, es, Base)` and add `CFBundleLocalizations`
  (`en`, `es`) to Info.plist / build settings as appropriate.
- SwiftUI's `Text("literal")`, `Button("literal") { }`, `Label("literal",
  systemImage:)` etc. are automatically extractable into a String Catalog
  by Xcode's build system as long as they're plain string literals (not
  already-computed `String` variables) — verify this project's actual
  string usage patterns hold that property before assuming it, and note in
  your summary which files needed restructuring (e.g. a computed `String`
  property that builds a label via string interpolation needs
  `String(localized:)` with explicit interpolation arguments instead of
  relying on automatic `Text` extraction).
- Interpolated/pluralized strings (e.g. `"\(count) images selected"`,
  `"\(index + 1) of \(count)"`) need real localization-safe handling —
  `String(localized:)` with a format string and named arguments, not naive
  string concatenation, since Spanish word order can differ from English.
- `AutomalityType`/label components that force `.textCase(.uppercase)` for
  the brand's tracked-uppercase look — confirm this doesn't break Spanish
  accented uppercase characters (Á, É, Í, Ó, Ú, Ñ) by testing at least one
  string containing each.

### Translation
- Translate every extracted string to natural, professional Spanish (not
  literal word-for-word) — reader is the same audience as English users, a
  Spanish-speaking photographer/creator using a batch watermarking tool.
- Keep brand/proper nouns untranslated: "WatermarkFactory", "Automality",
  preset names that are also visual labels (the Watermark Intensity chip
  labels "Discrete"/"Subtle"/etc. — translate these too, they're UI copy,
  not brand names, e.g. "Discreto"/"Sutil"/"Equilibrado"/"Seguro"/
  "Marcado"/"Protector" or similar — use your best judgment on natural
  Spanish naming here and flag your choices for review rather than assume
  they're final).
- Match the app's existing tone: direct, no exclamation-point enthusiasm,
  matches the plain English copy already in the app (e.g. "Choose Folder or
  Images...", "Watermark all images", not overly formal or overly casual
  Spanish).

### What NOT to touch
- `IntentParser.systemPrompt` (the prompt sent to the local Ollama model)
  stays in English regardless of the app's display language — it's an
  instruction to the model, not UI copy, and changing it isn't part of this
  task.
- Don't add a language picker/settings UI in this pass — rely on the
  system's own Language & Region setting (standard macOS localization
  behavior: the app picks up whatever language macOS is set to, falling
  back to English if Spanish isn't available for a given string). A
  manual in-app override can be a later addition if wanted.

### Verification
- `xcodebuild build`/`test` must still pass -- string-literal changes
  shouldn't affect any existing test's assertions (tests check values, not
  display strings, as far as this codebase's existing test suite goes;
  confirm that's still true rather than assume it).
- Genuinely testing the Spanish UI requires either changing this Mac's
  system language (disruptive, don't do it) or launching with
  `-AppleLanguages '(es)'` as a launch argument — note in your summary that
  you verified the String Catalog structurally (every English string has a
  non-empty Spanish counterpart, no missing keys) but the actual rendered-
  in-Spanish UI needs a manual check with that launch argument, same
  "flag what's unverified" pattern used elsewhere in this file.

