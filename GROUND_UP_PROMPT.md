# Watermark Factory — ground-up build prompt

This is what you'd hand a fresh builder today to produce this app well, informed by everything
learned across `SPEC.md`'s 20+ incremental addenda (some of which are now dead ends — see
"Explicitly not included" below) and today's design-thinking passes. Not a diff. If you're
starting from an empty repo, this is the whole brief.

## What this is, for whom

A native macOS app for real estate agents that does three things to a folder of listing photos,
well, in bulk:

1. **Watermark and rename in bulk** — protect every photo in a shoot with one drag, rename them
   into a consistent, listing-tied pattern.
2. **Compress for fast upload** — every export sized/compressed for wherever it's going (an MLS
   portal, email, social), without touching originals.
3. **Strip geolocation** — remove or fuzz the GPS coordinates every phone/camera embeds invisibly
   in each photo, independent of watermarking.

Full rationale for each, written for the actual user, lives in `PRODUCT_DESCRIPTION.md` — read it,
it's the source of truth for *why*, this doc is the *what/how*.

## Platform & stack

- macOS 13+ (Ventura), SwiftUI + AppKit where needed, Xcode project (not SPM-only).
- No third-party dependencies beyond `Sparkle` (auto-update) and the local `AutomalityUI`/
  `DesignSystemKit` packages (Felipe's shared design system, path dependencies at `~/Dev/AutomalityUI`
  and `~/Dev/DesignSystemKit`) — everything else is Foundation/AppKit/SwiftUI/CoreGraphics/ImageIO/
  Vision.
- **Architect the processing core (watermark math, crop, rename, EXIF/GPS, room classification)
  with zero AppKit-specific code**, even though only a Mac app ships today — this is what makes a
  future iPad/iPhone app (sharing that core as a real Swift Package, not symlinked files) and a
  future Linux/Windows CLI (a separate Go engine mirroring this one's behavior, not sharing code)
  additive later instead of a rewrite. See `GO_CLI_DESIGN.md` for the full multi-platform strategy
  — not part of this build, but don't paint yourself into a corner that makes it harder.
- Signed with a Developer ID certificate and notarized (`build_dmg.sh` handles archive → export →
  notarize → staple) — a downloaded, unsigned app that triggers a Gatekeeper warning is not
  acceptable for a real public download link.

## Information architecture

Two flow modes, not three — **no Chat mode**. An earlier version had a third conversational mode
(local-LLM intent parsing, scripted fallback questions) that was built and then deliberately
removed; don't rebuild it unless explicitly asked again.

- **Guided**: a numbered stage wizard (Select Images → Watermark → Position → Order & Rename →
  Export), one focused screen per stage, a single always-visible top-right action button whose
  color/label is the *one* next actionable thing on screen (orange/accent only when it's genuinely
  the next step — the moment a stage needs a choice made elsewhere, that other control gets the
  accent instead, never two orange things competing for attention at once).
- **Compact**: every control visible in one dense screen, no stage gating. Right-pane sections are
  **collapsible** (disclosure triangle, only the first section expanded by default, an "Expand"
  hint on collapsed ones) since a dozen-plus setting groups shouldn't all be permanently expanded.
  Compact mode gets its own always-visible top-right "Watermark All Images" button, same
  orange-when-ready rule as Guided.
- A `Preferences` window (`Cmd+,`, plus a gear icon in the header) with a **"Use Automality Brand
  Colors" toggle, off by default** — the app defaults to plain native macOS appearance (system
  accent color, standard materials), with the teal/orange brand look as something the user opts
  into, not the default. Route this through the existing `@Environment(\.brandTheme)` mechanism in
  `AutomalityUI`/`DesignSystemKit` (a `BrandTheme`-conforming `SystemTheme` swapped in at the app
  root) rather than hand-checking a flag at every color call site.

## The left panel — a settled design decision, not a starting point

This was rebuilt five times in one session before landing correctly. **Do it right the first time**:
the image sidebar is a thumbnail browser and *nothing else* — matching Apple's own HIG distinction
(sidebars are for content/navigation, toolbars and menus are for commands, not the reverse).
Concretely:
- Native `ScrollView` + thumbnail grid (Preview/Quick Look-style: image-forward, ~88pt square
  thumbnails, filename caption below each, not beside). Never nest a self-scrolling container
  (SwiftUI `List`) inside another custom scroll container — pick one scrolling mechanism per pane.
- Empty state (no images loaded yet): the "Choose Folder or Images..." button + drag-and-drop hint,
  centered, in place of the thumbnail grid — mutually exclusive with it, not stacked above it.
- A small checkmark badge on any thumbnail whose watermarked output already exists in the sibling
  `Watermarked/` folder (a cheap filesystem check, no new persisted state).
- **Recent folders** and **redo a past batch** (export history) are *commands*, not content — they
  live in the app's own **File → Open Recent** menu (`CommandGroup(after: .newItem)`), the actual
  macOS-native home for "reopen something I used before," not a custom widget competing for space
  in the sidebar. Any collection of variable-length strings (folder names, combined folder+watermark
  labels) rendered through a general-purpose flow/wrap layout must have its labels truncated
  (`.lineLimit(1)`, `.truncationMode(.middle)`, an explicit `maxWidth`) — a flow layout that measures
  children at their unconstrained natural width will blow out a fixed-width pane the instant a real
  (long) filename appears, which is exactly what happened here, twice, before being fixed.

## Core features

**Image intake**: folder picker or individual multi-file picker (both visible, either replaces the
current working set), plus drag-and-drop onto the window. Supports jpg/jpeg/png/heic/tiff/gif.

**Crop** (optional, off by default): a toggle in its own section. When on, the preview shows a
crop-selection overlay — thick orange L-shaped corner brackets, generously-sized drag targets, a
dimmed scrim over the excluded region, dashed X/Y guide lines while actively dragging. Crop happens
*before* watermark compositing (crop the source raster, then feed the cropped image into the
existing compose step) so all anchor/padding/offset math automatically respects the cropped canvas
with zero changes to that math. An upfront **scope toggle** — "Only This Image" / "All Images" —
decided before dragging, not a post-hoc confirmation dialog; the drag itself commits directly to
the right target based on whichever's selected. A purely decorative overlay (the scrim) must be
`.allowsHitTesting(false)` — a filled `Shape` is hit-testable across its full path bounds by
default regardless of even-odd fill styling used for rendering, which is exactly the bug that made
the crop handles undraggable the first time this was built.

**Watermark placement**: size (5 presets + fine-tune slider), opacity (5 presets + slider), a 9-point
anchor grid + manual X/Y offset + drag-to-reposition directly on the preview, padding, single vs.
tiled layout (with spacing + rotation pattern in tiled mode), a tint control (original/light/dark,
generated at runtime from the one watermark image the user provides — no second asset needed), and
a **Suggest Placement** button using Vision's saliency detection (avoid the busiest part of the
photo) + luminance sampling (recommend a tint with real contrast) — suggest-then-apply, never
auto-applied without an explicit tap.

**Room classification** (on-device, zero dependencies): Apple's built-in `VNClassifyImageRequest`
(already used elsewhere in this app for saliency — no new framework) recognizes kitchen, bathroom,
bedroom, balcony, living room, dining room, garage, patio, pool, closet, garden, and porch — confirm
this exact label list against `VNClassifyImageRequest.knownClassifications(forRevision:)` rather
than assuming, and match against an **exact allowlist**, never substring matching (a naive `"room"`
substring match also hits "mushroom"/"broom"/"classroom" — confirmed the hard way). "Auto-name by
Room" runs classification per image in the background and threads a room label into the existing
filename-generation function as an *additive* option (replaces the numeric sequence for images with
a confident match; images below the confidence threshold keep today's numeric naming, never a
forced wrong guess).

**Order & Rename**: click-to-number or drag-to-reorder thumbnails, a live rename preview before
export, prefix/suffix fields, room-label naming (above) layered on top of the same mechanism.

**Export**: format (keep original / JPEG / PNG / TIFF) with per-format guidance text, JPEG quality,
a user-settable max-file-size target (iterative quality/dimension reduction to hit it), "Optimize
for Web" (2048px cap), three built-in real-estate-portal presets (researched, cited, with an
explicit note where a portal's spec is an inferred safe default rather than a confirmed number —
don't present a guess as fact), GPS/metadata privacy levels (keep original precision / reduced
precision / remove entirely — reduced precision rounds coordinates while preserving the rest of
EXIF; every export also strips camera/software/AI-provenance metadata and writes a clean
`automality.com` attribution tag), and a **compress-only** path (export runs the resize/format/
GPS-strip pipeline with no watermark step at all) reachable the moment someone taps the main export
action with no watermark chosen — offer it as a real choice ("Upload Watermark" / "Compress Only"),
never silently block export just because watermarking is the app's headline feature.

**Feedback**: an orange, gently-pulsing-glow progress bar (not the plain system `ProgressView`)
plus an ETA readout during export, and a one-shot orange/teal confetti burst on a fully successful
run — gated strictly on zero failures, never fired on a partial/failed batch, since a "success"
celebration over real failures would be actively misleading.

**Presets & history**: named, savable full watermark configurations (distinct from the built-in
platform presets, which only touch output size/format/quality and never disturb the user's current
watermark position/opacity/settings). Export history remembers folder + watermark + settings per
past batch for one-click redo — surfaced via Open Recent (see left-panel section above), not an
inline sidebar widget.

**Non-destructive by construction**: originals are never modified; every export goes to a sibling
`Watermarked/` subfolder. This already satisfies the safety need behind "versioning" — don't build a
version-stack UI on top of it unless a real gap beyond simple visibility (the export-status badge,
above) shows up.

## Explicitly not included (checked and deliberately deferred, not overlooked)

- **Chat mode** — built once (local Ollama intent parsing + scripted fallback), removed. Don't
  rebuild without being asked again.
- **A map/geodata batch view** — no GPS-reading pipeline exists in the Mac app; this is designed
  (Leaflet.js + OpenStreetMap tiles, free, no API key) but only for the future Linux/Windows CLI in
  `GO_CLI_DESIGN.md`. Speccing UI for data that isn't read anywhere yet is premature — build the
  read step first if this becomes a priority, then reuse that same free-map approach rather than a
  native MapKit view invented separately.
- **Multi-batch "group by property"** — the app is strictly one folder/batch loaded at a time today
  (`AppState.folderURL`/`images`), and that already *is* one property per session implicitly. Real
  cross-batch grouping needs a genuine data-model change (a collection of batches, not one), which
  ripples into export, preview, and settings scoping — a real feature, not a sidebar tweak.
- **Full version-stack UI** (Lightroom-style before/after toggle, revert) — see "non-destructive by
  construction" above; the underlying need is already met.
- **HEIC support outside macOS** — Vision/ImageIO give this for free on Apple platforms; a future
  Linux/Windows engine has no equivalent without a cgo dependency, deliberately deferred there.

## Design principles this session actually taught (apply them, don't relearn them)

- **Sidebars hold content, not commands** — this single Apple HIG distinction would have prevented
  the left panel's entire five-round rebuild if applied from the start.
- **One accent color on screen at a time**, pointing at the one real next action — not a static
  brand-color assignment per button.
- **Never trust a flow/wrap layout with unconstrained-width children** — cap and truncate every
  label that could plausibly be a long real filename, not just short test strings.
- **Never nest two independently-scrolling containers** around the same content.
- **A purely decorative overlay needs `.allowsHitTesting(false)`** — SwiftUI `Shape` hit-testing
  uses non-zero winding regardless of the fill style used to *render* it looking like a hole.
- **Ship code implementation to `codex`/`gemini` CLI when available**; do design docs, audits, and
  independent build+test verification directly rather than trusting a subagent's own self-report —
  rebuild from scratch in a clean derived-data path and re-run the full test suite yourself before
  calling anything done.
- **A screenshot beats three rounds of blind guessing** — when a UI bug report and code-reading
  diagnosis don't converge after one real attempt, ask for a screenshot before trying a second blind
  fix, not after a third.

## Delivery bar

- `xcodebuild -scheme WatermarkFactory -configuration Debug -destination 'platform=macOS' build` —
  clean.
- `xcodebuild ... -enableCodeCoverage NO test` — full suite green (a from-scratch project has no
  pre-existing failures to carry forward; if `testPreservesGPSAndScrubsOtherMetadata`-style flake
  shows up, actually fix it rather than treating it as permanently known-acceptable).
- `./build_dmg.sh` produces a signed, notarized `dist/WatermarkFactory.dmg` that mounts and passes
  `spctl -a -vv` as `Notarized Developer ID`.
- `PRODUCT_DESCRIPTION.md` (the three pillars + why they matter to a real estate agent) and this
  doc both live at the repo root as the canonical "what and why" — keep them current as real
  scope decisions get made, the way `SPEC.md`'s addenda record was meant to but grew unwieldy at
  1300+ lines across 20 increments including dead ends. Prefer updating this doc's relevant section
  over appending a 21st addendum to `SPEC.md`.
