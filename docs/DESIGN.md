# Inkribe v1 — Product & UI Design

## Design goal

Inkribe should feel like a premium native Mac document app, not a web dashboard and not a floating dictation utility.

The visual hierarchy is:

```text
Library → Transcript → Edit / AI → Export
```

Record and Import are simply ways to create a Transcript.

## Main shell contract

The main window is structurally split into two full-height columns.

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Library                               Search       +     │
├───────────────────┼──────────────────────────────────────────────────────────┤
│                   │                                                          │
│ ▣ Library         │                        CONTENT                           │
│ ● Record          │                                                          │
│ ↓ Import          │                                                          │
│                   │                                                          │
│ Recent            │                                                          │
│                   │                                                          │
│                   ├──────────────────────────────────────────────────────────┤
│ ⚙ Settings        │ Whisper · Qwen · Local only                   Ready     │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

### Non-negotiable geometry

- While the sidebar is expanded, one vertical divider runs continuously from the top edge to the bottom edge; it collapses away with the zero-width sidebar.
- The sidebar owns the traffic-light region above it.
- The main titlebar begins at the divider.
- Never place the app name, page title, search, export, Pro button, or other main-titlebar content above the sidebar.
- Main status/player bars begin at the divider and never extend underneath the sidebar.
- The sidebar remains one uninterrupted vertical region.

## Sidebar toggle

The custom sidebar toggle lives in the main titlebar immediately beside the divider when expanded.

Rules:

- expanded initial target: ~220 pt
- collapsed width: 0
- never overlay the toggle on the structural divider
- when expanded, place the toggle just inside the main titlebar
- when collapsed, reserve native traffic-light space before the toggle
- animate sidebar width, divider, button position, and main-content expansion together
- initial animation target: ~0.20–0.25 s ease-in-out
- keep the button reachable when collapsed
- fade sidebar contents while collapsing if necessary to avoid clipping
- persist visibility state
- expose a menu/keyboard command wired to the exact same state
- respect Reduce Motion

Concept:

```text
Expanded
┌───────────────────┬──────────────────────────────────┐
│ ● ● ●             │ [◀] Library                       │
└───────────────────┴──────────────────────────────────┘

Collapsed
┌──────────────────────────────────────────────────────┐
│ ● ● ●  [▶] Library                                   │
└──────────────────────────────────────────────────────┘
```

## Navigation

Keep the primary sidebar simple:

```text
Library
Record
Import
────────
Recent
  Meeting with Alex
  Product ideas
  Interview

Settings
```

Do not turn AI actions, export formats, models, or queue states into permanent top-level navigation destinations.

Settings opens the separate MacAppFoundation Settings scene rather than replacing the main content view.

## Screen 1 — Library

Purpose: fast re-entry into recent work plus obvious Record/Import actions.

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Library                     Search…     [Unlock Pro] +  │
├───────────────────┼──────────────────────────────────────────────────────────┤
│                   │                                                          │
│ ▣ Library         │  RECENT TRANSCRIPTS                                      │
│ ● Record          │                                                          │
│ ↓ Import          │  Meeting with Alex                         42:18          │
│                   │  Today · Cleaned · English                               │
│ RECENT            │  ───────────────────────────────────────────────────     │
│                   │  Product ideas                              08:41         │
│ Meeting Alex      │  Yesterday · Raw · Vietnamese                            │
│ Product ideas     │  ───────────────────────────────────────────────────     │
│ Interview         │  Interview recording                       1:02:14        │
│                   │  Sep 15 · Summary available                              │
│                   │                                                          │
│                   ├──────────────────────────────────────────────────────────┤
│ ⚙ Settings        │ 18 transcripts · 5h 42m audio          100% on this Mac │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

Design rules:

- no analytics/dashboard cards
- no large empty marketing hero after the user has content
- Record and Import are the two primary creation actions
- rows prioritize title, date, duration, language, and useful processing state
- search should feel native and quick, not dominate the window

## Screen 2 — Recorder

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Recording                                      Offline │
├───────────────────┼──────────────────────────────────────────────────────────┤
│                   │                                                          │
│ ▣ Library         │                         02:14                            │
│ ● Record          │                                                          │
│ ↓ Import          │              ▁▂▃▅▇▆▄▂▂▄▇▅▃▂▁▂▄▆▇▄                      │
│                   │                                                          │
│                   │                    Recording…                            │
│                   │                                                          │
│                   │  Microphone                                              │
│                   │  MacBook Microphone                              ▾       │
│                   │                                                          │
│                   │  Language                                                │
│                   │  Auto Detect                                     ▾       │
│                   │                                                          │
│                   │             [ Pause ]      [ Stop ]                      │
│                   │                                                          │
│                   │             Audio stays on this Mac                      │
│                   ├──────────────────────────────────────────────────────────┤
│ ⚙ Settings        │ Whisper · Recording · 44.1 kHz                          │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

After Stop, transition into a compact transcription-progress state, then automatically open the created Transcript.

Do not require the user to manually save an intermediate recording before transcription.

## Screen 3 — Import Queue

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Import                                            + Add │
├───────────────────┼──────────────────────────────────────────────────────────┤
│                   │ TRANSCRIPTION QUEUE                                      │
│ ▣ Library         │                                                          │
│ ● Record          │ customer-call.m4a                         82%             │
│ ↓ Import          │ ██████████████████████████░░░░░░                         │
│                   │ Transcribing · English                                  │
│                   │                                                          │
│                   │ interview.mov                             Waiting         │
│                   │ 48:32 · Auto Detect                                     │
│                   │                                                          │
│                   │ voice-note.wav                            Complete ✓      │
│                   │ 03:14 · Vietnamese                                      │
│                   │                                                          │
│                   │        Drop audio or video files here                    │
│                   │                 or choose files                          │
│                   ├──────────────────────────────────────────────────────────┤
│ ⚙ Settings        │ 1 job running · Processing locally                      │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

Queue states must be clear without technical runtime terminology.

## Screen 4 — Transcript Editor

This is the most important screen in the product.

Default desktop layout:

```text
┌───────────────────┬──────────────────────────────────────────────┬─────────────┐
│ ● ● ●          ◀  │ Meeting with Alex              Search Export│             │
├───────────────────┼──────────────────────────────────────────────┼─────────────┤
│                   │                                              │ AI TOOLS    │
│ ▣ Library         │ Meeting with Alex                            │             │
│ ● Record          │ Today · 42 min · English                    │ ✦ Clean     │
│ ↓ Import          │                                              │ ✦ Polish    │
│                   │ 00:00                                        │ ✦ Summarize │
│ RECENT            │ We started by talking about the next         │ ✦ Notes     │
│                   │ release and whether we should move...        │ ✦ Actions   │
│ Meeting Alex      │                                              │             │
│ Product ideas     │ 00:14                                        │ Language    │
│ Interview         │ The main concern was shipping time...        │ English     │
│                   │                                              │             │
│                   │                                              │ Local only  │
│                   ├──────────────────────────────────────────────┴─────────────┤
│ ⚙ Settings        │ ▶ 08:32 ━━━━━━━━━━━●━━━━━━━━━━━━ 42:18  🔊        1×    │
└───────────────────┴────────────────────────────────────────────────────────────┘
```

The right inspector should be collapsible. The app should still work comfortably as a two-pane sidebar + editor layout.

### Transcript behavior

- text is directly editable
- timestamps remain visually secondary but easy to click
- clicking a timestamp/segment seeks audio
- player stays at the bottom of the main area
- player never spans beneath sidebar
- current playing segment may highlight subtly
- search is document-local when a transcript is open
- title is editable without forcing a modal dialog

## AI tools design

Do not expose a generic chat box in v1.

AI actions are explicit verbs:

```text
Clean
Polish
Summarize
Notes
Action Items
```

### Clean / Polish preview

Any action that may replace transcript text shows a side-by-side preview first:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Clean Transcript                                               ×    │
├──────────────────────────────────────────────────────────────────────┤
│ ORIGINAL                           CLEANED                            │
│                                                                      │
│ So um we basically decided         We decided to ship the smaller    │
│ that we're gonna ship the          version first and move the        │
│ smaller version first...           remaining features to v1.1.       │
│                                                                      │
│           Cancel          Replace Transcript          Save Copy      │
└──────────────────────────────────────────────────────────────────────┘
```

The original remains recoverable.

### Summary / Notes / Actions

Derived outputs become document modes/tabs rather than overwrite the transcript:

```text
Transcript     Summary     Notes
────────────────────────────────────────────────────────

SUMMARY
The discussion focused on reducing the v1 scope...

KEY POINTS
• Ship the smaller implementation first
• Move advanced features to v1.1

ACTION ITEMS
□ Finish transcript editor
□ Prepare App Store metadata
```

## Settings

Use `MacAppSettingsView` as a separate native Settings scene.

Suggested panes:

```text
General
Recording
Transcription
AI Cleanup
Storage
Appearance      ← MacAppFoundation
Plan            ← MacAppFoundation
About
```

Do not recreate Appearance or Plan UI locally.

## Pro presentation

Place `ProPlanButton` in the **main titlebar** only.

```text
┌───────────────────┬──────────────────────────────────────────────────────────┐
│ ● ● ●          ◀  │ Library                 Search   [Unlock Pro]      +     │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

Rules:

- never place it over the sidebar
- Free click → paywall
- Pro click → Settings → Plan
- use `ProBadge` sparingly on genuinely gated controls
- prefer contextual `ProUpsellView` before showing the full paywall for soft limits

## Theme system

All visible custom shell colors should use MacAppFoundation semantic theme roles.

Theme changes must update:

- main shell
- sidebar/titlebar
- transcript editor
- player/status bar
- dialogs
- onboarding
- Settings
- paywall/upsells
- Debug Developer Tools / Logs where appropriate

Avoid hard-coded light/dark RGB values except for assets that genuinely require them.

## Typography and density

Use native Mac information density rather than oversized mobile/web spacing.

- titles: restrained, not marketing-sized
- transcript text: comfortable reading size with generous line height
- metadata: secondary/tertiary semantic text
- controls: standard Mac hit targets and keyboard focus behavior
- tables/lists: compact enough to show useful information without feeling cramped
- monospaced text is reserved for Logs/diagnostics, not normal transcript UI

## Motion

Motion should explain geometry/state, not decorate it.

Use animation for:

- sidebar collapse/expand
- inspector collapse/expand
- queue progress
- record/stop state change
- small disclosure transitions

Avoid animated gradients, bouncing icons, or excessive spring effects.

## Empty-state layout

Empty/loading/error content may center inside its available body region, but structural chrome never participates in that centering.

- screen toolbars and control rows stay pinned to the top
- queue headers and queue actions stay pinned to the top of their panel
- transcript segment headers stay pinned to the top of the inspector
- sheet headers and Done/Close actions stay pinned to the top
- only the empty-state message/icon/actions center within the remaining content area
- routed screens must own the full main-content rectangle so intrinsic-height empty views cannot pull their headers toward the vertical center

## Accessibility

V1 design acceptance requires:

- keyboard access to all primary actions
- visible focus rings
- semantic accessibility labels for icon-only controls
- sufficient contrast across supported themes
- Reduce Motion support
- no information conveyed by color alone
- logical VoiceOver reading order

## Design principles summary

1. Transcript is the document.
2. Record/Import create documents; they are not separate product silos.
3. The shell divider is structural and always continuous.
4. Main-only bars never cross the sidebar.
5. Local AI uses explicit actions, not chat.
6. Destructive AI edits get a preview.
7. Derived AI outputs coexist with the transcript.
8. Native Mac density and keyboard behavior matter more than web-style visual spectacle.
9. MacAppFoundation supplies shared theme/commerce/settings/onboarding surfaces; Inkribe owns its product shell.
