# Design council: whole-app flow & structure

Demo run #2, scoped up from one section (`export.md`) to the whole app per Felipe's request — same
three bounded personas, same discipline, bigger canvas. Grounded in the actual shipping structure:
`ContentView.swift`'s `header`/`nextButton`/`Stage` enum/`stageContent`/`compactContent`, the full
section list, `WatermarkFactoryApp.swift`'s commands, and `PreferencesView.swift`.

## Positions

**HIG Purist.** Two real structural issues, not style nitpicks. First: Apple's guidance frames
progressive disclosure as revealing complexity *within one adaptive interface as it becomes
relevant* — not as two permanently-maintained parallel modes a user has to keep choosing between
every launch ([HIG discusses this under managing complexity](https://modelessdesign.com/backdrop/401);
[progressive disclosure defers advanced features to when they're needed](https://ixdf.org/literature/topics/progressive-disclosure)).
Guided vs. Compact is disclosure solved by duplication (two hand-built layouts, two places every
future feature has to be added) instead of disclosure solved by *layout* — the same content, denser
or more guided depending on state, not two apps wearing one name. Second: this is a genuinely
single-purpose batch tool (one input, one job, one output), which is exactly the carve-out Apple's
own multi-window guidance names for *not* needing Cmd+N/multiple windows — the single-window
approach here is actually correct, not a shortcut, and shouldn't be second-guessed.

**User Advocate.** The agent's actual moment of use is bimodal in a way that matters: first listing
ever, versus the two-hundredth. First time, they want to be told what to do — Guided's stage nav is
right for that. By the fiftieth listing, re-clicking through 5 stages for a workflow they've already
locked into a saved preset is real, felt friction — Compact exists because that friction is real,
not invented. The actual gap isn't "which mode is right," it's that nothing in the app *notices*
which kind of session this is and defaults accordingly — a returning user with a saved preset and a
folder full of familiar-looking files still lands on whatever mode they last used, which is fine,
but there's no lighter-weight "just run it again" path even in Compact — every session, expert or
not, still touches the same dense control surface. Section order (Crop bundled with Watermark
source in the Watermark stage) matches the real sequence fine; that's not where the friction is.

**Platform Realist.** Whatever Guided/Compact resolves to, it has to survive translation to a CLI
that has no visual stage nav or dense-grid concept at all — a wizard becomes an interactive prompt
flow, "compact" becomes flags, per `GO_CLI_DESIGN.md`'s own persona split (an on-site agent's touch
flow is not a Linux ops user's batch job, and neither is a mouse-and-cursor desktop session). The
one thing that has to be identical everywhere, not reinvented per surface, is the underlying
sequence of *decisions* (photos → watermark-or-skip → organize → export) — today that sequence
lives implicitly in `Stage`'s case order and in `compactContent`'s hardcoded section list
separately, two places that could drift. Global actions (Preferences, Open Recent, presets) landing
in three different places — a gear icon, the File menu, an inline section — is a bigger risk for a
future web app than for Mac, where at least native conventions (File menu, Cmd+,) paper over it;
a web app has no such native scaffolding to lean on and would need those conventions decided
explicitly, not inherited for free the way Mac gets them.

## Rebuttal round

**HIG Purist → User Advocate:** The "nothing notices which kind of session this is" gap is real, but
the fix isn't a third mode or a smarter default picker — it's proof the two-mode split is already
straining. An adaptive layout that's dense by default but *foldable* toward a guided walkthrough on
first run (empty state, no saved presets) solves the exact bimodal need described without
permanently forking the codebase in two.

**User Advocate → Platform Realist:** Agreed the decision sequence needs one source of truth, not
two — but don't let "must translate cleanly to a future CLI" override what a mouse-and-preview-pane
session actually needs today. The Mac app's whole value is *seeing* the photo while deciding; a
structure chosen to make Linux flag-parity easy shouldn't flatten that away.

**Platform Realist → HIG Purist:** Fair on progressive disclosure being about layout, not duplicated
modes — but flag that "one adaptive layout" is a bigger rebuild than it sounds from the Mac side
alone. It's the right target; it's not a small change, and shouldn't be scoped as if it were.

## Where they actually disagree

1. **Collapse Guided/Compact into one adaptive layout, or keep two modes and just fix the
   disclosure/decision-sequence duplication between them?** HIG Purist and User Advocate converge on
   "the two-mode split is the actual friction," but not on the fix's size — a full merge into one
   adaptive layout is a real rebuild (Platform Realist's caution), versus a smaller fix: keep two
   modes but make `Stage`'s decision sequence the single source of truth both layouts read from
   (today `compactContent`'s section list is a separately-hardcoded parallel structure, not derived
   from `Stage` at all), and add a lightweight "just run it again" path in Compact for a
   preset-loaded returning user. No consensus on which of these two is worth doing now.
2. **Should the primary action stay a single color/label-shifting header button, or does an app this
   dense need a persistent bottom action bar / toolbar instead?** Nobody raised this as broken — the
   "one accent color, always the real next step" rule (already a hard-won lesson from today's other
   work) is sound — but nobody actively defended the *header* specifically as the right location
   either, versus a macOS toolbar item (which would also survive translation to a menu-bar-driven
   convention more naturally than a bespoke header button does). Genuinely unexamined rather than
   actively contested — worth a real look, not assumed correct by default.
3. **Where do global actions (Preferences, Open Recent, Presets) belong as a *set* of conventions?**
   Today: gear icon + Cmd+,, File menu, and an inline collapsible section, respectively — three
   different patterns for three conceptually similar "app-level, not photo-level" actions. HIG
   Purist is fine with this (each individually matches a real macOS convention). Platform Realist
   isn't, given a future web app inherits none of those native affordances for free and would need
   an explicit, unified answer. Real disagreement about whether "matches Mac convention per-item" is
   sufficient or whether "one coherent pattern across all three, portable to other platforms" is the
   actual bar.

No confirmed bug this pass, unlike the GPS default in the export demo — everything above is a real
structural judgment call, not a correctness issue found while reading the code.

## Questions for Felipe

1. Is collapsing Guided/Compact into one adaptive layout worth the rebuild, or do you want the
   smaller fix now (one shared decision-sequence source of truth + a faster returning-user path in
   Compact) and revisit a full merge later?
2. Should the primary action move from the header button to a macOS toolbar item, or does the
   current header placement stay?
3. Do Preferences/Open Recent/Presets need one deliberately unified pattern (thinking ahead to a web
   app with no native menu-bar/Cmd+, scaffolding to lean on), or is "whichever native Mac convention
   fits each one individually" good enough for now?
