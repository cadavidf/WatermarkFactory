# WatermarkFactory v2 — Single View PRD

Status: in execution (branch `v2-single-view`, codex job `bww642ji6`)
Author: Felipe + Claude, 2026-09-08

## Problem

Two issues surfaced from real customer use of the current shipped app
(`/Applications/WatermarkFactory.app`, Guided + Compact dual-mode):

1. **Permission errors on export.** Customers hit "You don't have permission
   to save the file 'Watermarked' in the folder '<X>'" with no recovery path
   — the app just reports the failure and stops.
2. **Guided walkthrough is the wrong default.** The first-run wizard
   (SELECT IMAGES → WATERMARK → POSITION → ORDER & RENAME → EXPORT) and the
   separate Compact mode it hands off to are more UI than the task needs.
   Decision, on reviewing it live: replace both with one plain view.

## Goal

One always-visible window layout, no modes, no wizard, functionality-first.

## Layout (confirmed)

Three columns, left to right:

1. **Far left — thumbnail strip.** Every loaded image, thumbnail-only.
   Clicking one only changes what's shown in the center preview. It does
   **not** change any settings — settings are batch-wide, one set applies to
   every loaded image on export (matches current behavior, not a new
   per-image system).
2. **Center — live preview.** The selected image with the current watermark/
   crop settings applied, reusing the existing `WatermarkPreview` /
   `CropOverlay` views.
3. **Right — settings panel.** Every export control that exists today:
   watermark source/tint/size/opacity, position/anchor/layout mode, export
   format, JPEG quality, max file size, output width/height, prefix/suffix,
   optimize-for-web, metadata privacy. The "Watermark All Images" button
   lives here (or in a toolbar item) and calls `exportAll()` directly —
   **no intermediate review sheet**, no popup.

**Empty state:** no images loaded → a single drag-and-drop / click-to-browse
box fills the window. Static label, same every time — no first-run-only
copy, no dismissible tip.

## Removed

- The Guided walkthrough entirely: `isWalkthroughActive`,
  `hasCompletedFirstExport` gating, `walkthroughHeader`, the step indicator.
- Any remaining Compact-vs-Guided mode toggle.
- The Export Review sheet built in an earlier pass on branch
  `export-settings-sheet` — superseded by the settings panel being always
  visible, so a confirm-before-export step adds nothing. That branch is
  abandoned; this PRD's branch (`v2-single-view`) was cut from `main`
  before that work landed.

## Kept as-is (explicitly in scope to leave alone)

- `ConfettiView` (export-complete celebration)
- `GlowingProgressBar`
- `BrandScrollBar`
- Underlying export/watermark/crop logic in `ImageProcessor.swift` — this
  PRD only touches UI chrome and design tokens, not the pipeline.

## Vanilla design pass (narrow scope, confirmed)

Replace only:
- `AutomalityColor.*` → system colors (`.primary`, `.secondary`,
  `Color(nsColor: .windowBackgroundColor)`, etc.)
- `.buttonStyle(.automalityPrimary/.automalityAccent/.automalitySecondary)`
  → stock button styles (`.borderedProminent`, `.bordered`, plain)
- `AutomalitySegmentedControl` → stock SwiftUI `Picker` with
  `.pickerStyle(.segmented)`

Everything else (confetti, glow bar, scroll bar, component structure/
behavior) stays untouched — this is a token swap, not a redesign.

## Permission-failure recovery (carried over, independent of the scrapped sheet)

On an export write that fails with a permission error
(`NSFileWriteNoPermissionError` / `EACCES` / `EPERM`, including wrapped
underlying errors):
1. Show a short alert explaining the folder-permission problem.
2. Auto-open an `NSOpenPanel` folder picker so the customer can pick/
   re-authorize a destination.
3. Store that folder's security-scoped bookmark via the existing
   `SecurityScopedAccessTracker`.
4. Retry the export to the newly chosen folder once.

Wired directly into `exportAll()` — no sheet needed to host it.

## Execution plan

1. ✅ Branch `v2-single-view` cut from `main` (pre-dates the abandoned
   export-sheet work).
2. ⏳ Delegated to `codex` (per `~/.claude/CLAUDE.md` implementation-delegation
   order — codex is on PATH, so it's first in line, not the git-implementor
   fallback) with the full spec above as a single contract-first prompt.
   Running as job `bww642ji6`, log at
   `~/.claude/jobs/525aaf32/tmp/codex_v2_run.log`.
3. On completion: Claude verifies with a real
   `xcodebuild -project WatermarkFactory.xcodeproj -scheme WatermarkFactory
   -configuration Debug build` (codex's own sandbox can't reliably run
   xcodebuild — confirmed on the first pass of this app, where codex reported
   a clean build that didn't actually compile until Claude caught and fixed
   an actor-isolation error).
4. Claude launches the built app and screenshots it for Felipe to review
   against this PRD before any merge to `main`.
5. Felipe reviews against this document; iterate or merge.

## Out of scope for this pass

- Per-image settings.
- Any first-run onboarding, however minimal.
- Redesigning `ConfettiView`/`GlowingProgressBar`/`BrandScrollBar`.
- Changes to the watermark/crop/export pipeline logic itself.
