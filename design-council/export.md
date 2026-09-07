# Design council: Export settings

Demo run #1 of a bounded, three-persona review process. Grounded in the actual shipping code
(`exportSectionBody`, `ContentView.swift:1514`) and `Models.swift`'s `MetadataPrivacyLevel`/
`PlatformExportPreset`, not a hypothetical version of the feature.

## Positions

**HIG Purist.** Apple's own guidance on sensitive data is explicit about *secure defaults* — Photos'
Hidden and Recently Deleted albums are locked by default, not opt-in-locked
([Apple HIG — Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)).
`MetadataPrivacyLevel` defaults to `.keepOriginalPrecision` (confirmed in `Models.swift:365,420`) —
the exact opposite of a secure default for a field whose own product description calls it "on by
default, adjustable per export." Separately: ten-plus peer-level controls (format, web-optimize,
location privacy, width, height, prefix, suffix, quality, max-size, plus a *second* section for
platform presets) sit in one flat, ungrouped list with no visual hierarchy — a textbook case for
grouping or progressive disclosure, not a flat stack.

**User Advocate.** For the actual user — an agent processing 40-200 photos against a deadline — the
current flat layout is mostly fine *once they've set it up once*, since settings persist across
sessions. The real risk isn't clutter, it's the GPS default: an agent who never touches the location-
privacy control (very plausible — it's one segmented row among ten controls) ships their seller's
exact address on every listing without ever making a conscious choice. That's not a UI-polish
concern, it's the thing `PRODUCT_DESCRIPTION.md` names as the app's third pillar, silently not
happening by default.

**Platform Realist.** The Mac app's soft default is at least *visible* — the segmented control sits
right there before export, one glance catches it. A future CLI run non-interactively (a broker's
cron job, per `GO_CLI_DESIGN.md`'s Linux persona) has no glance to catch it on — whatever the default
is *is* the behavior, every run, unattended. A GUI can afford to get away with a debatable default in
a way a headless batch tool cannot. Separately, the platform-preset section silently overwrites
width/height/quality that the main section also exposes — fine with a mouse and live visual
feedback: it's much riskier as a flag-driven CLI command, where "which flag wins if both are passed"
needs an explicit, documented rule instead of "whichever the user clicked more recently in a GUI."

## Rebuttal round

**HIG Purist → User Advocate:** Agreed the GPS default is the sharper problem — but disagree it's
separable from the "too many flat controls" critique. If location privacy needs to stop being
missable, it needs to stop being one row in a wall of ten; visual prominence and a safe default are
the same fix, not two.

**User Advocate → Platform Realist:** The cron-job framing is right, but don't let CLI risk drive the
Mac app's decision *the other way* — the Mac user in the deadline scenario likely wants secure-by-
default too, for the same "one missable row" reason above, not because a hypothetical future CLI
needs it more.

**Platform Realist → HIG Purist:** Fair, but flag one thing HIG doesn't have an opinion on: platform
consistency across three surfaces. A default that changes behavior by platform (Mac defaults safe,
CLI also defaults safe) is fine; a default that changes based on *interactive vs. scripted* — safe
in the wizard, unsafe if a flag is omitted in scripted mode — would be the actual footgun, and HIG
alone won't catch that, only a cross-platform contract will.

## Where they actually disagree

Two real, unresolved tensions — everything else above converged:

1. **Fixing the GPS default is unanimous. How much to restructure the section around it is not.**
   HIG Purist wants grouping/disclosure as part of the same fix; User Advocate is fine with a
   narrower fix (just flip the default, maybe promote that one control's visual weight) that
   doesn't touch the other nine controls' layout. Restructuring the whole section is a bigger,
   riskier change than fixing one dangerous default — reasonable people land in different places on
   whether that's worth doing *now* versus *eventually*.
2. **Should platform presets be allowed to silently override manually-set width/height/quality, or
   should applying one require confirming it'll discard the current manual values?** No persona
   objects to presets existing; the disagreement is purely about whether the current silent-override
   behavior is a fine, expected "presets are shortcuts" convention (User Advocate's read) or a
   real footgun that needs a confirmation step, especially once a CLI equivalent has to make the same
   precedence rule explicit and *documented*, not just implicit in click order (Platform Realist's
   read).

## Questions for Felipe

1. **`MetadataPrivacyLevel` currently defaults to `.keepOriginalPrecision`, contradicting
   `PRODUCT_DESCRIPTION.md`'s claim that GPS removal is "on by default."** This reads as a real bug,
   not a design debate — confirm the intended default (recommend `.removeLocation`, matching both
   HIG's secure-default pattern and the product description already written) so it can be fixed
   directly rather than treated as one of the open paradoxes above.
2. Once that's fixed: is a narrow fix (correct the default, make that one control visually louder)
   enough for now, or do you want the export section actually regrouped/disclosed given it's already
   ten-plus flat controls deep — knowing the broader restructure is the bigger, slower change of the
   two?
3. Should selecting a platform preset that would overwrite manually-set width/height/quality ask for
   confirmation, or is silent-override-as-shortcut the intended, acceptable behavior worth documenting
   explicitly (for the future CLI's own flag-precedence rule) rather than changing?
