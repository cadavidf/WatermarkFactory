# WatermarkFactory PRD — Real Estate Agent Workflow

Status: in execution (branch `v2-single-view`)
Author: Felipe + Claude, 2026-09-08

## Who this is for

A real estate agent (or their photographer/assistant) with a folder of
listing photos who needs to get them ready to send to a portal, a client,
or MLS — fast, without touching Photoshop, and without leaking anything
about the property, the client, or themselves in the file.

## The six real requirements

Framed the way the agent actually experiences the pain, not as feature
bullets — then mapped to what the app does today.

### 1. Put a watermark on the image
**Pain:** unwatermarked listing photos get lifted and reused by other
agents/portals with no attribution back to the source.
**Status: done.** Core feature — choose a watermark image, it's composited
onto every export.

### 2. Auto-position the watermark near a corner, with adjustable padding
**Pain:** a watermark dead-center blocks the photo; one that's too close
to the edge gets cropped by portals that auto-thumbnail. Needs to sit near
a corner with breathing room, and that corner should be the obvious
default, not a setting the agent has to hunt for.
**Status: done.** `anchor` defaults to `.bottomRight`
(`ContentView.swift:60`), with `padding`/`offsetX`/`offsetY` to fine-tune
distance from the edge. Multiple corners (`additionalAnchors`) and tiled
layout mode also exist if one mark isn't enough deterrence.

### 3. Batch process — same watermark, same settings, whole folder at once
**Pain:** 30-80 photos per listing; doing this one at a time is the whole
reason this app needs to exist.
**Status: done.** `exportAll()` applies one batch-wide settings object to
every loaded image. Confirmed intentionally single-settings, not
per-image — an agent sets it up once per listing and exports the folder.

### 4. Strip geolocation and all other metadata — guaranteed, not best-effort
**Pain:** EXIF/GPS on a listing photo can expose the exact address before
a listing goes live, a seller's other property, or personal device info
in the file. "Mostly removed" isn't good enough — it has to be a
guarantee, because the agent won't manually check every file.
**Status: done, and worth understanding why it's built this way.**
`ImageProcessor.scrubbedMetadata()` (`ImageProcessor.swift:555`) does NOT
copy-then-delete the source file's metadata — it builds a brand-new,
minimal properties dictionary from scratch and only ever re-adds GPS data
if the user explicitly chose to keep it. Confirmed intentional design
(not a bug): every export additionally **overwrites** the handful of
metadata fields that different viewers/formats tend to surface
(TIFF/IPTC/EXIF/PNG Software, Artist, Copyright, UserComment) with a
neutral `"automality.com"` placeholder — so even in a format-specific edge
case where a field can't be left fully empty, whatever ends up there is
inert, not identifying. Default privacy level is `.removeLocation`
(strip GPS entirely); `.reducedPrecision` (~1.1km) and
`.keepOriginalPrecision` are opt-in for the rare case an agent wants
neighborhood-level geotagging on purpose.

### 5. Export format + size/quality control, with a hard cap for portal limits
**Pain:** portals reject uploads over a size limit — sometimes per-image
("no file over 5MB"), sometimes it's the images that need to look good at
a small size for fast page loads. The agent needs "just make these work,"
not manual compression per photo.
**Status: mostly done — one real gap.**
- Format switch (JPEG/PNG/TIFF/GIF/keep original), JPEG quality,
  "optimize for web" toggle: all exist (`ContentView.swift:69-98`).
- Per-image max file size (`maxFileSizeKB`): exists — quality (and
  dimensions, if needed) is automatically reduced per image to hit the
  target, exactly matching "some images might come out worse quality to
  fit the cap." Blocked for PNG/TIFF today since those aren't
  lossy-compressible (`maxFileSizeBlocksExport`, `ContentView.swift:137`)
  — agent has to switch to JPEG to use a size cap, which is reasonable.
- **Gap:** no aggregate/whole-batch size cap ("all images total under
  5MB" as opposed to "each image under X"). Only the per-image cap exists
  today. Worth confirming with Felipe whether real customers actually
  need the aggregate version, or whether "each image ≤ X" already covers
  every portal limit seen in practice, before building it.

### 6. Batch rename — company/location/client name baked into filenames, reordered
**Pain:** exported files need to be identifiable at a glance in a shared
folder or upload queue — "which listing is this," not `IMG_3127.jpg`.
**Status: partial gap.**
- Prefix/suffix text fields exist (`outputPrefix`/`outputSuffix`,
  `ContentView.swift:80-81`) and get sanitized/applied to every filename
  on export.
- Reordering exists (drag to reorder before export, per the existing
  "ORDER & RENAME" step).
- **Gap:** prefix/suffix are static free-text only — no token/variable
  substitution (e.g. a `{client}` or `{location}` placeholder that
  auto-fills per batch). Today the agent types the company/listing name
  into the prefix field by hand each time, which does satisfy the ask
  ("your company name on the images") but isn't the dynamic
  location/client-aware naming implied by "based on the location/client/
  etc." Needs a follow-up conversation on exactly what should drive the
  auto-fill (a saved client/location list? the source folder name?)
  before it's buildable — not scoping it blind.

## How this gets delivered — v2 single view

The UI work already scoped and in progress doesn't change any of the six
requirements above — it's the delivery vehicle: one always-visible window
(thumbnails far left, live preview center, all six requirements' controls
in a settings panel on the right) instead of the old Guided-wizard/Compact
dual-mode split. See git history on branch `v2-single-view` for that
layout work, currently delegated to the `git-implementor` fallback agent
(codex rate-limited until 10:36 AM, gemini blocked on a broken
`GOOGLE_CLOUD_PROJECT` env var).

Also carried into that same pass: permission-denied recovery on export
(alert + folder re-picker + retry), unrelated to the six requirements but
fixing a real reported customer failure.

## Open items before closing out this PRD

1. Confirm with Felipe whether the aggregate batch-size cap (item 5) is
   worth building, or whether per-image cap already covers real portal
   requirements.
2. Get real answer on what should drive dynamic rename tokens (item 6) —
   a client/location list, folder-name parsing, or something else —
   before scoping that as a follow-up task.
