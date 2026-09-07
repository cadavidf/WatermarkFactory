# Adaptive layout + toolbar + unified global actions

Spec for `codex exec`. Implements all three decisions from `design-council/whole-app-flow.md`
(full rebuild, toolbar primary action, unified global-action entry point). Read
`ContentView.swift` (`AppState.Stage`, `header`, `nextButton`, `stageContent`, `compactContent`,
every `*SectionBody`/`*Stage` var, `FlowMode` usage), `Models.swift` (`FlowMode`),
`WatermarkFactoryApp.swift` (`.commands`), and `PreferencesView.swift` fully before editing —
this touches the app's actual navigational skeleton, not one feature.

## Part 2 finding first, since it gates Part 1 and 3's toolbar dependency

**Confirmed via research, not assumed**: a macOS `ToolbarItem` can host arbitrary SwiftUI content,
including this app's own custom `AutomalityButtonStyle`-styled `Button` — the same
`.buttonStyle(.automalityAccent/.automalityPrimary/.automalitySecondary)` pattern already used
throughout `ContentView.swift` works unchanged inside a toolbar item; dynamic recoloring based on
app state is then just normal SwiftUI re-rendering, nothing toolbar-specific blocks it. The
caveats found in research are about *system-tinted* toolbar chrome (relying on `.tint()` to
recolor Apple's own default toolbar button styling, with real inconsistencies across recent macOS
versions) — irrelevant here, since the plan is to place this app's already-fully-custom button
component inside the toolbar slot, not lean on system tinting at all. `ToolbarItem`/
`.primaryAction` placement has been available since macOS 11, well under this project's macOS 13+
target. No blocker — proceed with Part 1/3 as designed below.

## Part 1: one adaptive layout, replacing Guided + Compact

### The mechanism: one section list, two renderings

Today, section content is duplicated across two places: `compactContent`'s hardcoded
`CollapsibleControlSection` list, and five separate hand-written `*Stage` views
(`selectImagesStage`/`watermarkStage`/`positionStage`/`orderRenameStage`/`exportStage`) each
re-listing a subset of the same section bodies. Replace both with one declarative list every
rendering mode reads from:

```swift
// ContentView.swift, near the other private lets
private struct SectionSpec {
    let id: String
    let title: String
    let stage: AppState.Stage      // which walkthrough stage this section belongs to
    let startExpanded: Bool        // dense-mode default
}

private var allSections: [SectionSpec] {
    [
        SectionSpec(id: "presets", title: "Presets", stage: .watermark, startExpanded: false),
        SectionSpec(id: "crop", title: "Crop", stage: .watermark, startExpanded: false),
        SectionSpec(id: "watermarkSource", title: "Watermark source", stage: .watermark, startExpanded: true),
        SectionSpec(id: "sizeOpacity", title: "Size & Opacity", stage: .position, startExpanded: true),
        SectionSpec(id: "layoutMode", title: "Layout mode", stage: .position, startExpanded: false),
        SectionSpec(id: "positionPadding", title: "Position & Padding", stage: .position, startExpanded: false),
        SectionSpec(id: "orderRename", title: "Order & Rename", stage: .orderRename, startExpanded: false),
        SectionSpec(id: "export", title: "Export", stage: .export, startExpanded: true),
    ]
}

@ViewBuilder
private func sectionBody(_ id: String) -> some View {
    switch id {
    case "presets": savedPresetLibraryBody
    case "crop": cropSectionBody
    case "watermarkSource": watermarkSourceSectionBody
    case "sizeOpacity": sizeOpacitySectionBody
    case "layoutMode": layoutModeSectionBody
    case "positionPadding": positionPaddingSectionBody
    case "orderRename": orderRenameSectionBody
    case "export": exportSectionBody
    default: EmptyView()
    }
}
```

(`imageList`/the folder picker stays outside this array, exactly as today — it's the always-visible
left sidebar in both renderings, not a collapsible section.)

**Dense rendering** (the app's default state, replaces `compactContent`'s hardcoded list):
```swift
ForEach(allSections, id: \.id) { spec in
    CollapsibleControlSection(spec.title, startExpanded: spec.startExpanded) { sectionBody(spec.id) }
}
```

**Walkthrough rendering** (replaces the five hand-written `*Stage` views): group the same array by
`stage` and render only the current stage's sections, uncollapsed (a first-time user shouldn't have
to expand anything mid-walkthrough):
```swift
private func sectionsForCurrentStage() -> [SectionSpec] {
    allSections.filter { $0.stage == state.stage }
}

private var walkthroughContent: some View {
    HStack(spacing: 0) {
        previewPane
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(sectionsForCurrentStage(), id: \.id) { spec in sectionBody(spec.id) }
            }
            .padding(panePadding)
        }
        .frame(width: controlsWidth)
    }
}
```
`.selectImages` stage still renders `imageList` specifically (no sections map to it), same special
case `selectImagesStage` already is today — keep that one small branch, don't force it through
`sectionsForCurrentStage()`.

### What decides walkthrough vs. dense

Precise, persisted, tied to a real milestone — not `images.isEmpty` (resets every launch, so a
returning user with an empty folder selection would incorrectly see the walkthrough again):

```swift
// AppState
@AppStorage("hasCompletedFirstExport") var hasCompletedFirstExport = false
var isWalkthroughActive: Bool { !hasCompletedFirstExport }
```
Set `hasCompletedFirstExport = true` inside `exportAll`'s completion handler, exactly where
`succeeded` is already computed today — the first *successful* export (not just opening the app)
is the real "this person now knows how it works" milestone. A user who quits mid-walkthrough before
ever exporting sees it again next launch, which is correct (they haven't actually learned the flow
yet).

`state.stage` (`AppState.Stage`, unchanged: `selectImages, watermark, position, orderRename,
export`) continues to drive walkthrough progression exactly as it does today via `advance(to:)` —
no change to that mechanism, only to what consumes it.

Add a lightweight escape hatch for an impatient first-time user — a text-button in the header,
visible only during the walkthrough: `Button("Skip to full view") { state.hasCompletedFirstExport =
true }`. This is the direct answer to the whole-app-flow doc's "nothing notices which kind of
session this is" gap for a returning user who somehow still has `hasCompletedFirstExport == false`
(a fresh install on a new machine, e.g.) but already knows what they're doing.

### `FlowMode` removal

Delete `FlowMode` (`Models.swift`) and `AppState.flowMode` entirely — there is no longer a
user-facing Guided/Compact choice, so there's nothing to store. Every place that branched on
`state.flowMode == .guided`/`.compact` (today: `body`, `header`, `nextButton` vs.
`compactWatermarkAllButton`) branches on `state.isWalkthroughActive` instead, collapsing what were
two parallel button/layout implementations into one each (see Part 2 below for the button side).
The `AutomalitySegmentedControl(options: FlowMode.allCases, ...)` in `header` is removed along with
it — there's nothing left to toggle.

### `body`

```swift
var body: some View {
    VStack(spacing: AutomalitySpacing.sm) {
        if state.isWalkthroughActive {
            walkthroughHeader   // today's AutomalityProgressNav + "Skip to full view", no toolbar duplication of stage nav
        }
        if state.isWalkthroughActive {
            state.stage == .selectImages ? AnyView(selectImagesStage) : AnyView(walkthroughContent)
        } else {
            denseContent   // renamed from today's compactContent, now driven by allSections
        }
    }
    .frame(minWidth: 980, minHeight: 680)
    .background(AutomalityColor.gray100)
    .toolbar { primaryActionToolbarItem; globalActionsToolbarItem }   // see Parts 2 and 3
    // .sheet/.alert modifiers unchanged from today
}
```
(`AnyView` used here only to keep this sketch short — pick whichever non-type-erased structure
reads cleanest once actually written, e.g. a `@ViewBuilder` computed property, same as this file
already does elsewhere for similar branches.)

**Confirmed unchanged by this part**: crop, watermark placement, order/rename, and export
*functionality* — every `*SectionBody` computed property keeps its existing content and logic
untouched; this redesign only changes what assembles them into a screen.

## Part 3: one unified global-actions entry point

A single toolbar `Menu` becomes the discoverable, portable home for Preferences + Open Recent +
Presets — the thing a future web app can reconstruct directly (a header dropdown), since it has no
native File-menu/Cmd+, scaffolding to inherit for free. Native Mac conveniences (Cmd+, still opens
Preferences directly, `File > Open Recent` stays in the menu bar) remain as additive shortcuts
layered on top, not removed — redundant access paths (menu bar *and* toolbar *and* keyboard
shortcut reaching the same action) are normal, expected Mac behavior; what's being fixed is that
these three concerns were scattered across three *unrelated* UI locations with no single common
surface, not that native shortcuts are themselves wrong.

```swift
// ContentView.swift
private var globalActionsToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
        Menu {
            if !state.recentFolders.isEmpty {
                Section("Recent Folders") {
                    ForEach(state.recentFolders) { recent in
                        Button(recent.name) { state.selectRecentFolder(recent) }
                    }
                }
            }
            if !state.exportHistory.isEmpty {
                Section("Past Batches") {
                    ForEach(state.exportHistory) { entry in
                        Button("\(entry.folderName) \u{2190} \(entry.watermarkName)") { state.redoFromHistory(entry) }
                    }
                }
            }
            if !state.presets.isEmpty {
                Section("Presets") {
                    ForEach(state.presets) { preset in Button(preset.name) { state.applyPreset(preset) } }
                }
            }
            Divider()
            Button("Save Current as Preset...") { /* today's isNamingPreset = true path */ }
                .disabled(!state.canSavePreset)
            Divider()
            Button("Preferences...") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help("Recent, Presets, and Preferences")
    }
}
```

`WatermarkFactoryApp.swift`'s existing `CommandGroup(after: .newItem) { Menu("Open Recent") { ... }
}` stays as-is (zero extra code, native File-menu convention some users will reach for reflexively)
— it now duplicates a subset of this toolbar menu's content rather than being the *only* place
Recent/History live. The header's standalone gear-icon button (`Button { ... showSettingsWindow ...
}`) is removed — Preferences now reachable via this toolbar menu and the unchanged Cmd+, shortcut,
not a dedicated icon anymore.

`savedPresetLibrary`/`savedPresetLibraryBody` (today rendered as its own always-expanded-by-default
section in the dense list) — decide whether it stays as a section too (redundant with the toolbar
menu's Presets group, but harmless) or is removed from `allSections` now that the toolbar menu
covers "apply a preset." Recommend removing it from `allSections` (drop the `"presets"` entry) and
keeping only "Save Current as Preset..." in the toolbar menu (above) — having a preset *library
browser* in both the toolbar menu and a dense section is the exact kind of duplication this part is
meant to eliminate.

## Verification

1. `xcodebuild -scheme WatermarkFactory -configuration Debug -destination 'platform=macOS' build`
   — clean.
2. `xcodebuild -scheme WatermarkFactory -configuration Debug -destination 'platform=macOS' -enableCodeCoverage NO test`
   — no new failures vs. `main` (`testPreservesGPSAndScrubsOtherMetadata` known pre-existing).
   Any test referencing `FlowMode`/`state.flowMode` needs updating or removing, since that type is
   deleted by this change — grep test files for `FlowMode`/`flowMode` first.
3. Manually reason through (can't screenshot in this environment, per today's established
   limitation): fresh install (`hasCompletedFirstExport == false`) shows the walkthrough; after one
   successful export, relaunch shows dense mode directly; the toolbar's primary action button
   changes color/label correctly through both states; the global-actions menu shows/hides its three
   sections correctly when each is empty.
4. Do not commit or push.
