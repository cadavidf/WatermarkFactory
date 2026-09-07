# Watermark Factory — multi-platform strategy (Mac/iPad/iPhone native, Linux CLI)

Status: **design only, not started**. First written 2026-09-03 as a straight "Go CLI for
Linux/Windows" doc; revised the same day once the real target became clearer — Mac now, iPad and
iPhone later, Linux (and possibly Mac) via a CLI. That's a platform-family decision, not just a
CLI detail, so this revision starts from usability/personas per surface and lets the architecture
follow from that, rather than architecture-first.

**Windows confirmed back in scope** (some real estate agents already run Windows machines) — the
first message said "Linux and Windows," the second said "Linux and Mac" without mentioning it,
which read as a possible narrowing; it isn't one. Everything below targets Linux **and** Windows
for the Go engine.

## Design thinking: who actually uses each surface, and for what

Four different surfaces, four different real jobs — not one flow ported four ways.

- **Mac (existing app, desktop)**: an agent back at their desk after a shoot, working through a
  full folder — reviewing every photo, adjusting crop/watermark position by eye, checking the
  rename preview, exporting. Deliberate, visual, mouse-driven, session length measured in minutes.
  This is what the app already is. No change here.
- **iPad, on-site**: the agent is *at the property*, phone or tablet in hand, possibly still
  shooting. The valuable version of this isn't "the Mac app's panels squeezed onto a touchscreen"
  — it's closer to a **live capture assistant**: shoot a photo, get an instant on-device room guess
  ("Kitchen?") to confirm or correct with one tap, watermark applied automatically per whatever
  preset is already configured, done. Touch-first means big tap targets and as little manual
  positioning/typing as the job allows — the crop-drag interaction that makes sense with a mouse
  and a precise cursor is a worse idea to port directly to a fingertip on a 10" screen without
  rethinking the interaction (bigger handles, snap-to-grid, maybe skip freeform crop entirely on
  this surface in favor of a few tap-to-select aspect presets).
- **iPhone**: same job as iPad, more constrained — the "quick capture, confirm the guess, auto-
  everything-else, share" path, deliberately feature-reduced versus iPad/Mac (no deep crop/position
  editing at all is a reasonable v1 cut here), same way most pro iOS apps scale capability down on
  the smallest screen rather than cramming the full desktop feature set in.
- **Linux CLI**: **not the same persona as the other three at all.** Nobody is going to sit at a
  Linux terminal mid-showing. The realistic Linux user is an ops/automation profile — a broker
  running a nightly batch job across every agent's dropbox folder, a script wired into an existing
  intake pipeline, someone on a home server/NAS processing a backlog. That means the CLI's design
  center is **scriptability and composability first** (flags, predictable exit codes, an optional
  machine-readable output mode, pipeable), with an interactive wizard as a secondary onboarding
  aid for a human trying it manually — not the other way around. Designing the CLI *as* a ported
  GUI wizard would optimize for the wrong user.

The consequence: **there is no single flow to design once and port four ways.** The core
processing job (watermark, crop, rename, compress, strip GPS, classify room) is one shared
capability; the interaction layer is genuinely different per surface by design, not by omission.

## Architecture: what this implies

Given the above, the highest-leverage split is by **language/runtime reality**, which lines up
cleanly with the persona split:

- **Mac, iPad, iPhone are all Apple platforms.** They can share one native Swift core across all
  three — not a hypothetical, this repo already does exactly this in miniature: `cli/Package.swift`
  (the existing `wf-metadata` headless tool) symlinks the GUI app's real `ImageProcessor.swift`/
  `Models.swift` rather than reimplementing them, so the CLI never silently drifts from the app.
  The real move here is generalizing that pattern: pull the platform-agnostic-within-Apple core
  (watermark math, crop, rename, EXIF/GPS handling, the new room classifier — all of which already
  use only cross-Apple-platform frameworks: Core Graphics, ImageIO, Vision) into a proper local
  Swift Package that the Mac app, a future iPad app, and a future iPhone app all depend on, each
  with their own thin SwiftUI shell tuned to that surface's actual usability needs (per the
  personas above — not a shared UI, a shared *engine*). This is strictly less work than it sounds:
  most of `ImageProcessor.swift` already has zero AppKit-specific code in it.
- **Linux is the real outlier**, because Swift's story there is genuinely worse for this specific
  job — no Vision framework (so the room classifier needs a different approach entirely, see
  below), no ImageIO. **This is where Go earns its place**: not as "the cross-platform layer
  everything funnels through," but as a **separate, Linux-specific engine that mirrors the Swift
  engine's behavior and CLI contract**, not its code. Two implementations of the same job,
  deliberately, rather than forcing one implementation to serve both a native-Apple-frameworks
  world and a Linux world equally badly.
- If Mac also wants a CLI (per this message's "linux and mac options"), that's actually the *easy*
  case: it's the existing `cli/wf-metadata` pattern, extended to cover watermark/crop/rename/room-
  classification, not new work — it already runs on Mac today because it's Swift using Mac-native
  frameworks, same as the GUI app. The Go engine only needs to exist for Linux.

## Room classification on Linux/Windows (no Vision framework on either)

The Mac/iPad/iPhone room-labeling feature (kitchen/bathroom/bedroom/balcony/etc., see
`PRODUCT_DESCRIPTION.md`) uses Apple's built-in `VNClassifyImageRequest` — free, on-device, zero
model to manage, confirmed working against exactly the room categories needed. Neither Linux nor
Windows has an OS-level equivalent. Options, cheapest first:
1. **Ship without room classification in the Go engine's v1** — the three core pillars
   (watermark+rename, compress, strip GPS) don't need it; room-naming is valuable but not load-
   bearing. Reasonable scope cut given the ops/automation persona above may not even want
   auto room-naming for a batch job the way an on-site agent does.
2. **A small ONNX-exported scene classifier via ONNX Runtime's Go bindings** (MobileNet-class
   model fine-tuned on room categories, a few MB, fully local/offline, and ONNX Runtime itself has
   native Windows support alongside Linux) if parity is wanted later — real work, not a copy-paste,
   and a model has to be sourced or trained (Places365-derived data covers this exact category
   set).
Recommendation: cut it from Go-engine v1 explicitly (documented, not silently missing), revisit if
Linux/Windows users actually ask for it.

## EXIF: still the hard part on the Go side

(Carried over from the original draft, unchanged — this risk doesn't depend on the platform
reframing above.)

Three GPS privacy levels exist today (`MetadataPrivacyLevel`: keep original precision / reduced
precision / remove entirely):
- **Remove entirely** — trivial in Go: decode raster, re-encode via `image/jpeg` or `image/png`.
  Neither stdlib encoder writes EXIF at all, so this is *less* code than the Swift version, which
  has to explicitly strip metadata Apple's encoder would otherwise preserve.
- **Keep original precision** — straightforward: copy the source file's EXIF blob unmodified.
- **Reduced precision (round GPS, keep everything else)** — the real work: parse the EXIF IFD
  tree, rewrite just the GPS lat/long tags, re-serialize the rest byte-for-byte unchanged.
  `github.com/dsoprea/go-exif/v3` supports writing (unlike read-only alternatives) but is far less
  battle-tested than Apple's ImageIO. **Recommendation unchanged: spike this specific capability
  first, in isolation**, before building the rest of the Linux engine. If it proves too fragile,
  Linux v1 ships "keep" and "remove" only, drops "reduced precision."
- **HEIC**: no first-class Go decoder without a cgo dependency (`libheif` bindings), which works
  against "simple static cross-compiled binary." **Recommendation unchanged: JPEG/PNG/TIFF/GIF
  only for Linux v1**, HEIC is a v2 decision once the cgo trade-off is deliberately evaluated.

## Watermark compositing (Go side)

No risk — `image/draw`'s `draw.DrawMask` handles alpha-blended overlay compositing directly from
the standard library; anchor/padding/tile/rotation math ports as plain arithmetic from the Swift
version. `golang.org/x/image/draw` gives high-quality resampling (`CatmullRom`) matching the
visual quality of the Mac app's resize step.

## The map/geodata batch browser

Unchanged from the original draft, applies to whichever engine runs it (Swift or Go — it's cheap
either way, just an HTML file generator):

Generate a local, self-contained HTML file, open it in the default browser. No paid API, no key:
1. Read GPS EXIF from every image in the batch, before any stripping.
2. Emit `<batch>/map.html`: **Leaflet.js** (MIT, free) against **OpenStreetMap** tiles (free tile
   usage, appropriate for one agent's own shoots). Pin per photo, click for thumbnail + filename.
   Auto-centers/zooms to the pin cluster; scattered pins (multiple properties mixed into one
   folder) are immediately visually obvious — that's the actual value of this feature.
3. Open it via `open` (macOS) / `xdg-open` (Linux) / `start` (Windows, if in scope).
4. No GPS data in the batch at all: render a plain "no location data" message, don't error.

## CLI usability design, specifically (the part that needed rethinking)

The original draft designed the CLI as "the Mac wizard's flow, but in a terminal." Per the persona
work above, that's backwards for the CLI's actual primary user (automation/ops, not a step-by-step
novice). Redesigned around **composability first, wizard second**:

**Primary interface — flags, scriptable, boring and predictable:**
```
watermarkfactory run \
  --dir ~/batch/123-Maple-St \
  --watermark ~/branding/logo.png --anchor bottom-right --opacity 0.5 --size medium \
  --rename-prefix maple-st_ \
  --target web \
  --strip-gps remove \
  --json                      # machine-readable result on stdout, for piping into another tool
```
Non-zero exit code on any failure, `--json` output mode for scripted consumers (a broker's own
tooling parsing results, not a human), no interactive prompts unless explicitly requested — the
opposite default from a wizard-first design, matching how the actual Linux user runs this (cron, a
CI step, a script), not how the Mac user runs the app.

**Secondary interface — `watermarkfactory wizard`, opt-in, for a human trying it manually:**
same step-by-step flow as the original draft (select → watermark or skip → rename with live
preview → target size → GPS setting → optional map view → confirm), built with `github.com/
charmbracelet/huh`. This exists for onboarding/manual use, not as the primary documented path —
the README leads with the flag examples, not the wizard.

`watermarkfactory map --dir <folder>` stands alone too (map view without a full export run) — a
legitimate one-off use independent of processing.

Command structure via `github.com/spf13/cobra` (subcommands: `run`, `wizard`, `map`, `rename`
dry-run-only, `version`).

## Package layout (Go engine, Linux + Windows)

```
watermarkfactory-cli/
  cmd/watermarkfactory/main.go       # cobra root + subcommands
  internal/imageproc/                # watermark math, compose, resize, rename — ported logic
  internal/exif/                     # GPS read + selective write (the risky part, spike first)
  internal/mapgen/                   # Leaflet HTML generation + per-OS "open" dispatch
  internal/wizard/                   # secondary interactive flow (huh-based)
  testdata/                          # fixtures, mirrors WatermarkFactoryTests
```

## Swift core package (Mac/iPad/iPhone, the other half of this plan)

Not previously called out as its own workstream — it should be, since it's real work even though
it's "just" extraction:
```
WatermarkFactoryCore/                # new local Swift Package
  Sources/WatermarkFactoryCore/
    ImageProcessor.swift             # moved from app target, zero AppKit dependencies today
    Models.swift
    RoomClassifier.swift             # new, from today's Vision-based room-naming work
  Tests/
```
The Mac app target, the existing `cli/wf-metadata` tool, and future iPad/iPhone app targets all
depend on this package instead of symlinking individual files — the symlink approach in
`cli/Package.swift` was a reasonable minimal fix for one file; a real package is the right shape
once three-plus targets (Mac app, Mac CLI, iPad app, iPhone app) all need the same core.

## Distribution

Go engine: `GOOS=linux/windows GOARCH=amd64/arm64 go build` (four binaries; `darwin` dropped from
this matrix since Mac gets its CLI via the Swift package instead, not the Go engine). GitHub
Releases, same shape as the existing `.dmg` release flow. Windows binaries need an eventual
code-signing story too (Authenticode) if Gatekeeper-equivalent SmartScreen warnings matter to
Felipe the same way the Mac Gatekeeper warning did — not urgent for a design-doc stage, but worth
carrying forward as the same class of problem already solved once for macOS.

Swift core: no separate distribution — it's a dependency of each Apple-platform target, built as
part of that target's normal release (the Mac app's existing signed+notarized `.dmg` pipeline
already covers this once `ImageProcessor.swift` moves into the package without changing what it
compiles into).

## What Felipe should decide before this becomes buildable milestones

1. ~~Is Windows actually still in scope~~ — **resolved: yes**, confirmed. `go-exif/v3`'s write
   path and the EXIF risk spike below need validating on Windows too, not just Linux.
2. **Reduced-precision GPS in v1 or deferred?** — gated on the `go-exif/v3` spike (Linux + Windows
   both).
3. **HEIC in v1 or v2?** — gates the cgo dependency question, same on both target OSes.
4. **Room classification: cut from v1 (recommended above) or worth the ONNX Runtime effort now?**
5. **Same repo (Go engine in a new top-level dir) or a new sibling repo** for the Go CLI?
6. **Timing**: does the Swift-core-package extraction (Mac/iPad/iPhone shared engine) happen before
   or after the Go engine work? They're independent efforts that don't block each other, but only
   one can be first.

Once those are answered, milestone 1 is still the EXIF spike (unknown that could reshape the Go
side) run in parallel with the Swift-package extraction (mechanical, low-risk, unblocks iPad/
iPhone work whenever that starts) — not the wizard, not the map generator, not the room classifier
port, since none of those are genuinely uncertain.
