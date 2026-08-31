# WatermarkFactory, redesigned in Go: architecture

This describes how WatermarkFactory's current feature set (see `README.md`) would be
structured if rebuilt from scratch in Go, with the CLI and an MCP server as first-class
interfaces instead of an afterthought bolted onto a GUI. The actual app stays Swift/SwiftUI
— this is a design reference, not a migration plan in progress.

## Why this shape

The current app already proves the right seam: **one processing library, several front
doors** (GUI calls it directly; the CLI symlinks the same Swift files). A Go rewrite keeps
that seam but makes it the literal package boundary instead of a filesystem symlink trick,
and adds a third front door (MCP) for free once the library has a clean API, because MCP
tools are just handler functions over the same calls the CLI makes.

```
                    ┌─────────────────────────────┐
                    │   watermark (core library)   │
                    │  pure functions over image.  │
                    │  Image / bytes, no I/O owned  │
                    └───────────────┬───────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
     ┌────────▼────────┐   ┌─────────▼─────────┐   ┌─────────▼─────────┐
     │   cmd/wf (CLI)   │   │  cmd/wf-mcp (MCP)  │   │  internal/gui/*   │
     │  cobra + flags   │   │  stdio/HTTP server │   │  Wails/Fyne shell │
     └───────────────────┘   └────────────────────┘   └────────────────────┘
```

## Backend

### Module layout

```
watermarkfactory/
  go.mod
  internal/
    watermark/          # core image pipeline (pure, no I/O)
      compose.go        #   source + watermark + settings -> image.Image
      background.go     #   flood-fill background removal
      tint.go            #   light/dark/original recoloring
      placement.go       #   anchor math, tiling, rotation, smart-placement scoring
      presets.go         #   intensity presets, size/opacity presets
    metadata/           # EXIF/IPTC/XMP handling
      scrub.go           #   strip camera/AI-provenance/thumbnails
      gps.go             #   remove / reduce-precision / keep-exact
      attribution.go     #   write IPTC Byline + format-specific carriers
    export/              # encode + target-size fitting
      encode.go           #   jpeg/png/tiff/gif encoders, quality search
      naming.go           #   output filename prefix/suffix/numbering
    jobs/                 # batch orchestration, shared by CLI/MCP/GUI
      batch.go            #   fan-out over a folder, progress events, error collection
    intent/               # optional: local-LLM-backed natural-language settings parsing
      parser.go
  cmd/
    wf/                   # CLI entrypoint
    wf-mcp/                # MCP server entrypoint
  gui/                    # optional native/web shell (see Frontend)
```

`internal/watermark` and `internal/metadata` are pure: `func Compose(src, wm image.Image,
settings Settings) (image.Image, error)` with no file or network I/O, so they're trivially
unit-testable with synthetic `image.Image` values — the same discipline the current Swift
tests use (`ImageProcessorMetadataTests`), just without CoreGraphics-specific gotchas like
the untagged-color-space pitfall that bit the Swift test fixtures.

### Core types

```go
package watermark

type Settings struct {
    SizeFraction   float64
    Opacity        float64
    Anchor         Anchor
    AdditionalAnchors []Anchor
    OffsetX, OffsetY float64
    Layout         LayoutMode      // single | tiled
    Padding, Spacing float64
    Rotation       RotationPattern // none | diagonal | alternating | custom
    CustomAngle    float64
    Tint           Tint            // original | light | dark
    RemoveBackground bool
    BackgroundTolerance float64    // default 0.12

    ExportFormat   ExportFormat
    JPEGQuality    float64
    OptimizeForWeb bool
    OutputWidth, OutputHeight int
    MaxFileSizeKB  int
    OutputPrefix, OutputSuffix string

    MetadataPrivacy MetadataPrivacyLevel // removeLocation | reducedPrecision | keepExact
}
```

`Settings` is the Go analogue of Swift's `WatermarkSettings`, with the same
backward-compatibility discipline: it's the versioned contract between every front end and
the core, so every new field gets a zero-value default that preserves old behavior (Go's
zero values do this more naturally than Swift's `Codable` custom-decoder pattern — a struct
literal with a missing field just gets `false`/`0`/`""`, no migration code needed — but a
`Settings.Validate()` / `Settings.WithDefaults()` step should still exist as the single place
that pins those defaults, so CLI, MCP, and GUI agree on them).

### Background removal (flood-fill)

Direct port of the current algorithm, since it's already format-agnostic reasoning over
pixels, not CoreGraphics-specific:

```go
func RemoveBackground(img image.Image, tolerance float64) image.Image {
    // sample 4 corners; if they disagree beyond tolerance, return img unchanged
    // BFS flood-fill from every border pixel, zeroing alpha for pixels within
    // tolerance of the sampled background color and connected to the border
}
```

Go's `image.NRGBA` gives direct pixel access without the CGContext dance the Swift version
needs, and avoids the color-space pitfall entirely as long as decode/encode consistently
target sRGB (Go's `image/color` model doesn't silently color-match between untagged and
tagged spaces the way CoreGraphics does — but decoding real-world JPEGs/PNGs with embedded
ICC profiles other than sRGB is still a real edge case worth a test, same lesson learned
here).

### Metadata

Go doesn't have an ImageIO-equivalent standard library, so this is the one place the rewrite
takes on a real external dependency: `github.com/rwcarlsen/goexif` or `github.com/dsoprea/go-exif`
for reading, plus a small hand-rolled JPEG-segment writer or `github.com/evanoberholster/imagemeta`
for writing back a *reduced* EXIF/IPTC block rather than round-tripping the original — mirrors
the current approach of building a fresh, minimal properties dict rather than filtering the
source one down (safer default: nothing leaks that wasn't explicitly re-added).

### Batch orchestration

```go
package jobs

type Progress struct {
    Total, Done, Failed int
    Current             string
    LastError           error
}

func RunBatch(ctx context.Context, sourceDir, watermarkPath, outDir string,
    settings watermark.Settings, onProgress func(Progress)) (Summary, error)
```

`onProgress` is the seam all three front ends use differently: the CLI prints a line per
file, the GUI updates a progress bar, the MCP server streams progress notifications on tools
that support it (or just returns the final `Summary` for a simple synchronous tool call).
Errors are collected per-file with `error.Error()` text preserved end to end — the current
Swift app's most concrete lesson learned this session was a silently-swallowed error message
("0 of 18 watermarked" with no reason); a Go rewrite should treat "always carry the real
error string to the caller" as a design invariant, not a bug fix.

## CLI (`cmd/wf`)

Built on `cobra` (or `urfave/cli` — either is fine; cobra if subcommands grow). One binary,
one subcommand per real operation, flags mirror `Settings` field-for-field so the CLI's
`--help` output *is* the settings documentation:

```sh
wf batch \
  --source ~/Photos/listing --watermark ~/Assets/logo.png \
  --size 0.13 --opacity 0.4 --anchor bottom-right \
  --format jpeg --optimize-for-web \
  --metadata-privacy remove --remove-background \
  --out ~/Photos/listing/Watermarked

wf preset list                     # print the six intensity presets
wf preview --source a.jpg --watermark logo.png --size 0.2 --out preview.png
```

Design choices carried over from the current `wf-metadata` CLI:
- **No reimplementation risk** — the CLI package imports `internal/watermark` directly (Go's
  module system makes this the default, not something that has to be engineered the way the
  Swift symlink trick does).
- **Dry-run** support (`--dry-run`) for scripting against unfamiliar folders safely.
- **Structured output option** (`--json`) so the CLI can be shelled out to by other tooling
  (including a future non-Go automation layer) without scraping human-readable text.

## MCP server (`cmd/wf-mcp`)

An MCP server is a thin adapter: each tool handler validates input, builds a `Settings`,
and calls the same `jobs.RunBatch` / `watermark.Compose` functions the CLI calls. Using
`github.com/modelcontextprotocol/go-sdk` (mark/spf13-style official Go SDK) over stdio for
local use, or streamable-HTTP for a remote/shared deployment.

```go
package main

func main() {
    server := mcp.NewServer("watermarkfactory", version, nil)

    server.AddTool(&mcp.Tool{
        Name: "watermark_batch",
        Description: "Apply a watermark to every supported image in a folder.",
        InputSchema: batchInputSchema,
    }, handleBatch)

    server.AddTool(&mcp.Tool{
        Name: "watermark_preview",
        Description: "Render one image with a proposed watermark/settings for review before running a full batch.",
    }, handlePreview)

    server.AddTool(&mcp.Tool{
        Name: "watermark_presets",
        Description: "List the named intensity presets (Discrete..Protective) with their size/opacity/layout values.",
    }, handlePresets)

    server.AddTool(&mcp.Tool{
        Name: "metadata_inspect",
        Description: "Report what metadata (GPS, camera info, provenance markers) is present in a source image before processing.",
    }, handleMetadataInspect)

    server.Run(context.Background(), mcp.NewStdioTransport())
}
```

Tool surface, deliberately small and composable rather than one giant "do everything" tool
(matches MCP tool-design guidance and mirrors the CLI's subcommands):

| Tool | Maps to | Notes |
|---|---|---|
| `watermark_batch` | `jobs.RunBatch` | The main operation. Returns a summary (succeeded/failed counts, per-file errors). |
| `watermark_preview` | `watermark.Compose` on one image | Lets an agent iterate on settings against a single file before committing to a batch — important for a chat-driven workflow, since re-running a full folder per trial is wasteful. |
| `watermark_presets` | `watermark.Presets()` | Read-only; lets an agent describe intensity options to the user in the user's own words instead of guessing numeric size/opacity. |
| `metadata_inspect` | `metadata.Inspect` | Read-only; answers "what's actually in this file's metadata" before deciding a privacy level — directly addresses the "why is the metadata not removed" class of question that came up with the current app. |

A local MCP client (Claude Desktop, an agent harness) then gets natural-language-driven
batch watermarking for free: "watermark everything in ~/Photos/listing with my logo,
bottom-right, strip GPS" becomes one `watermark_batch` call with `Settings` filled in by the
model, no bespoke chat UI needed — which also means the current app's in-house `ChatFlowView`
+ `IntentParser` (a local-Ollama-backed structured-extraction flow) becomes optional: an MCP
client is a *better* version of the same idea, since it already knows how to hold a
conversation and only needs the tool surface, not a hand-built question tree.

## Frontend

Three real front-end concerns, decreasing in required investment:

1. **CLI is the primary interface for automation** (scripts, CI, cron jobs, this app's own
   test harnesses) — already covered above, no separate UI code needed.
2. **MCP is the primary interface for agent-driven / conversational use** — also covered
   above; this replaces the bespoke chat UI's job.
3. **A native GUI is still worth having for the non-technical/point-and-click case** (the
   actual target user for a "batch watermark my listing photos" tool is often not going to
   open a terminal). Two real options, both keeping the exact same `internal/watermark` core:
   - **Wails** (Go backend + a web-tech frontend rendered in a native window) — fastest path
     to something visually equivalent to the current SwiftUI app (2D intensity matrix,
     drag-and-drop folder picker, live preview canvas), cross-platform for free, and the
     frontend can be built with plain HTML/CSS/JS or a lightweight framework since it's not
     shipping to the web — it's a native app shell.
   - **Fyne** — pure Go, no JS/web toolchain at all, but a more limited widget set; better fit
     if "no web stack in the build" is a hard requirement than if visual polish matters more.
   Either way, the GUI layer talks to `internal/jobs`/`internal/watermark` in-process (no
   IPC needed, unlike the MCP server) — same shape as the current Swift app's `AppState`
   calling `ImageProcessor` directly.

Given the current app already has a mature, brand-consistent SwiftUI frontend
(`DesignSystemKit`/`AutomalityUI`, the 2D intensity matrix, Smart Placement, chat mode), the
realistic recommendation is **not** to rewrite the frontend in Go at all: keep the Swift
GUI, and if CLI/MCP access is genuinely wanted beyond what `cli/wf-metadata` already
provides, add a small Go (or Swift, via a lightweight MCP Swift SDK) MCP server that shells
out to `wf-metadata` or links against the same symlinked Swift sources as a C-callable
library. A full Go rewrite only pays for itself if cross-platform (Linux/Windows) support is
an actual goal — Apple's ImageIO/CoreGraphics/Vision frameworks WatermarkFactory currently
depends on are macOS-only regardless of Swift vs. Go, so "Go" alone doesn't buy portability;
only replacing those frameworks with Go's `image`/`golang.org/x/image` stack does, and that
tradeoff (giving up Vision-based Smart Placement's saliency detection, ImageIO's broad format
support, and Apple's mature EXIF handling) is the real cost of this rewrite, not the language
choice itself.
