# ReadAloud 1.0 iOS Design

## Design intent

ReadAloud should feel like a serious reading/listening product: closer to a focused combination of Apple Books and a podcast player than a document utility.

The app should hide sophisticated local generation, queue, cache, and package machinery behind a calm native iOS interface.

The design should not mechanically copy Spokio's Mac UI. Reuse Spokio's product concepts and state semantics, then reinterpret them for iPhone. iPad is outside the 1.0 product boundary.

## Information architecture

Primary structure:

```
TabView
├── Library
│   ├── Add / Import
│   ├── Project Detail
│   │   └── Reader
│   └── Search / Sort
└── Settings

Global
└── Mini Player when playback is active
```

The normal user journey should remain:

```
Library
   ↓
Project
   ↓
Reader
```

not:

```
Importer
   ↓
Editor
   ↓
TTS utility
```

---

## Visual principles

- Native SwiftUI navigation and sheets.
- Large readable typography.
- Generous spacing.
- Artwork carries identity where available.
- One primary accent color.
- Avoid dashboard density.
- Avoid exposing technical TTS terminology unless necessary.
- Use familiar media controls.
- Prefer labels users understand: "Ready Offline" over "Generated WAV".
- Keep advanced generation/cache actions available but secondary.
- Current playback should remain visible throughout the app via mini-player.
- Status should be visible without becoming noisy.

---

# 1. Library

The Library is the app's home screen.

Primary responsibilities:

- resume listening
- browse projects
- add content
- search/sort
- show useful offline/generation state
- enter Settings

Suggested layout:

```
┌─────────────────────────────────┐
│ Library                    🔍  + │
│                                 │
│ Continue Listening              │
│ ┌─────────────────────────────┐ │
│ │ ┌──────┐                    │ │
│ │ │cover │  The Great Gatsby  │ │
│ │ │      │  Chapter 4         │ │
│ │ └──────┘  42%               │ │
│ │           ━━━━━━━●━━━━━━     │ │
│ │           Heart · 1.0×       │ │
│ │                       ▶      │ │
│ └─────────────────────────────┘ │
│                                 │
│ Your Library              Sort⌄ │
│                                 │
│ ┌──────┐  Atomic Habits         │
│ │cover │  EPUB · 18 chapters    │
│ │      │  7 ready offline       │
│ └──────┘                        │
│                                 │
│ ┌──────┐  AI Research Paper     │
│ │ PDF  │  PDF · 43 pages        │
│ │      │  31% listened          │
│ └──────┘                        │
│                                 │
│ ┌──────┐  Notes                 │
│ │ TXT  │  Text · 22 min         │
│ └──────┘                        │
│                                 │
│─────────────────────────────────│
│ Library                 Settings│
└─────────────────────────────────┘
```

### Library card metadata

Show only high-value information:

- title
- author if available
- source type
- progress
- current chapter when relevant
- offline/generated state when relevant

Do not put queue internals, model names, cache file details, or technical diagnostics on normal cards.

### Continue Listening

If there is a resumable project, it should be visually prominent.

Tapping the card should resume or open the Reader at the saved position.

### Empty state

```
┌─────────────────────────────────┐
│ Library                       + │
│                                 │
│                                 │
│              📚                 │
│                                 │
│       Your library is empty     │
│                                 │
│  Add a book, PDF, or document   │
│      and listen completely      │
│          on your device.        │
│                                 │
│       [ Add a Document ]        │
│                                 │
└─────────────────────────────────┘
```

---

# 2. Add / Import

Tapping + presents an iOS-native action sheet or compact sheet.

```
┌─────────────────────────────────┐
│          Add to Library         │
│                                 │
│  📖  Import EPUB                │
│  📄  Import PDF                 │
│  📝  Import Document            │
│  ✍️  Paste Text                 │
│                                 │
│              Cancel             │
└─────────────────────────────────┘
```

The file picker should be scoped appropriately for each action.

## Import progress

Do not hide substantial parsing behind an unexplained spinner.

```
┌─────────────────────────────────┐
│ Importing                  Cancel│
│                                 │
│            ┌──────┐             │
│            │cover │             │
│            └──────┘             │
│                                 │
│ The Great Gatsby                │
│ EPUB                            │
│                                 │
│ Extracting chapters…            │
│ ███████████░░░░░  68%           │
│                                 │
│ 18 chapters found               │
│ Cover extracted                 │
│ Metadata loaded                 │
│                                 │
└─────────────────────────────────┘
```

Use real progress when the underlying package provides it. Otherwise show clear stage-based progress.

## Import review

After extraction succeeds:

```
┌─────────────────────────────────┐
│ Add Document                    │
│                                 │
│            ┌──────┐             │
│            │cover │             │
│            └──────┘             │
│                                 │
│ The Great Gatsby                │
│ F. Scott Fitzgerald             │
│ EPUB · 18 chapters              │
│                                 │
│ Voice                    Heart ›│
│ Speed                     1.0× ›│
│                                 │
│        [ Add to Library ]       │
│                                 │
└─────────────────────────────────┘
```

Allow title editing if metadata is poor.

Do not make the user configure advanced generation options before the project exists.

---

# 3. Project Detail

This is the iOS reinterpretation of a Spokio Project window.

It should answer:

- What am I listening to?
- Where am I?
- What is ready offline?
- What chapter is next?
- What voice/speed does this project use?
- What can I generate or manage?

```
┌─────────────────────────────────┐
│ ‹ Library                   ••• │
│                                 │
│             ┌──────┐            │
│             │cover │            │
│             │      │            │
│             └──────┘            │
│                                 │
│        The Great Gatsby         │
│      F. Scott Fitzgerald        │
│                                 │
│        42% listened             │
│      ━━━━━━━━━●━━━━━━           │
│                                 │
│    [ ▶ Continue Listening ]     │
│                                 │
│ Voice        Heart          ›   │
│ Speed        1.0×           ›   │
│                                 │
│ Chapters                        │
│                                 │
│ ✓  1  In My Younger Years       │
│ ✓  2  The Valley of Ashes       │
│ ▶  3  The Party                 │
│ ◌  4  Gatsby                    │
│ ·  5  Reunion                   │
│ ·  6  Daisy                     │
│                                 │
└─────────────────────────────────┘
```

## Item status language

Internal states may be richer, but UI should map them simply:

```
✓  Ready offline
▶  Playing
◌  Queued / generating
·  Not generated
!  Needs attention
```

Use color only as a secondary cue; icons/text must carry meaning.

## Chapter interaction

Tap:

- open/play chapter depending on current context

Swipe actions may expose:

```
Generate     More
```

Long press / More menu:

```
Play
Generate Offline
Regenerate
Clear Generated Audio
Voice…
Speed…
Chapter Info
```

Keep destructive/cache-clearing actions out of the primary row.

## Project More menu

Potential actions:

```
Project Info
Generate Remaining Chapters
Manage Offline Audio
Rename
Storage
Delete Project
```

---

# 4. Reader

The Reader is the most important screen.

It should feel calm and content-first while retaining powerful playback.

```
┌─────────────────────────────────┐
│ ‹ Gatsby                    ☰ •••│
│─────────────────────────────────│
│                                 │
│ Chapter 3                       │
│                                 │
│ In my younger and more          │
│ vulnerable years my father      │
│ gave me some advice that        │
│ I've been turning over in       │
│ my mind ever since.             │
│                                 │
│ Whenever you feel like          │
│ criticizing anyone...           │
│                                 │
│                                 │
│                                 │
│─────────────────────────────────│
│ Chapter 3                  42%  │
│ ━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━  │
│                                 │
│      ↶ 15     ❚❚      15 ↷     │
│                                 │
│   Heart        1.0×      ☾      │
└─────────────────────────────────┘
```

## Reader behavior

- Text scrolls independently.
- Playback continues when the user scrolls away from the active paragraph.
- Current spoken paragraph may be subtly highlighted.
- The app should not forcibly jump the user's scroll position while they are reading.
- Provide an explicit "return to current" affordance if needed.
- Playback controls stay stable.
- Voice and synthesis-speed changes should clearly explain when regeneration is required for cached audio.
- Preserve the current content bookmark when narration changes. Exact seconds apply only to matching audio; after regeneration or clearing audio, resume at the bookmarked source segment and allow a short replay of that segment.

## Reader toolbar

Suggested:

- Back
- Chapters
- More

More menu can include:

- Project Details
- Generate Current Chapter
- Regenerate Current Chapter
- Clear Current Audio
- Reader Appearance
- Sleep Timer
- Chapter Info

---

# 5. Chapters sheet

Chapters/sections should be accessible without leaving Reader.

```
┌─────────────────────────────────┐
│ Chapters                    Done│
│                                 │
│ ✓  1  In My Younger Years       │
│ ✓  2  Valley of Ashes           │
│ ▶  3  The Party                 │
│ ◌  4  Gatsby                    │
│ ·  5  Reunion                   │
│                                 │
│ ─────────────────────────────── │
│ Generate Remaining Chapters     │
└─────────────────────────────────┘
```

For large documents:

- searchable list
- current item auto-revealed
- preserve TOC hierarchy where useful
- avoid flattening meaningful EPUB structure unnecessarily

---

# 6. Mini Player

When playback is active outside Reader, show a persistent mini-player above the tab bar.

```
┌─────────────────────────────────┐
│                                 │
│ Your Library                    │
│ ...                             │
│                                 │
│─────────────────────────────────│
│ Gatsby · Chapter 3       ❚❚  ›  │
│ ━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━  │
│─────────────────────────────────│
│ Library                 Settings│
└─────────────────────────────────┘
```

Mini-player behavior:

- tap body → Reader
- play/pause inline
- show title + current item
- lightweight progress indication
- remain stable while navigating Library/Settings

Do not duplicate a second playback state. It must observe the same runtime as Reader/background playback.

---

# 7. Voice picker

Use a dedicated picker rather than an overly dense menu if voice previews/metadata are valuable.

```
┌─────────────────────────────────┐
│ Voice                       Done│
│                                 │
│ ✓ Heart                         │
│   Bella                         │
│   Michael                       │
│                                 │
│ ─────────────────────────────── │
│ Project Default                 │
│                                 │
│ This chapter uses Heart.        │
└─────────────────────────────────┘
```

For per-item settings, clearly distinguish:

```
Project Default — Heart
Custom — Bella
```

Changing between Default and Custom must preserve the stored custom value, including after relaunch. Voice and synthesis speed each persist an independent `inherit`/`custom` mode and remembered value; selecting Default changes the mode only.

---

# 8. Speed picker

```
┌─────────────────────────────────┐
│ Narration Speed             Done│
│                                 │
│ 0.8×                            │
│ ✓ 1.0×                          │
│ 1.1×                            │
│ 1.2×                            │
│ 1.5×                            │
│                                 │
│ Custom…                         │
└─────────────────────────────────┘
```

This picker changes Kokoro synthesis speed and can require regeneration; it is not a separate playback-rate control. Final allowed speeds should match TTS/runtime quality and not be chosen purely for UI convenience.

---

# 9. Offline / generation management

Project-level management:

```
┌─────────────────────────────────┐
│ ‹ Project       Offline Audio   │
│                                 │
│ Ready                    7 / 18 │
│ Generating                     1│
│ Queued                         3│
│                                 │
│ Chapter 1             ✓  42 MB  │
│ Chapter 2             ✓  38 MB  │
│ Chapter 3             ▶  44 MB  │
│ Chapter 4             ◌         │
│ Chapter 5             ·         │
│                                 │
│ [ Generate Remaining ]          │
│                                 │
│ Clear Generated Audio…          │
└─────────────────────────────────┘
```

Use human language:

- Ready Offline
- Generating
- Waiting
- Not Generated

Avoid exposing "paragraph cache" as a primary concept. Paragraph cache belongs under advanced storage management if exposed at all.

---

# 10. Settings

Use AppFoundation patterns where they already exist.

```
┌─────────────────────────────────┐
│ Settings                        │
│                                 │
│ PLAN                            │
│ Pro                         ›   │
│                                 │
│ PLAYBACK                        │
│ Default Voice          Heart ›  │
│ Default Speed           1.0× ›  │
│ Skip Interval            15s ›  │
│ Continue to next chapter     ●  │
│                                 │
│ GENERATION                      │
│ Prefetch upcoming audio      ●  │
│ Generation behavior          ›  │
│                                 │
│ STORAGE                         │
│ Generated Audio          1.8 GB │
│ Cached Content           214 MB │
│ Manage Storage              ›   │
│                                 │
│ APPEARANCE                      │
│ Theme                       ›   │
│                                 │
│ SUPPORT                         │
│ Help                        ›   │
│ Send Feedback               ›   │
│ About                       ›   │
└─────────────────────────────────┘
```

Keep settings grouped by user goal rather than implementation subsystem.

---

# 11. Storage

Storage should be first-class because ReadAloud generates local media.

```
┌─────────────────────────────────┐
│ ‹ Settings      Storage         │
│                                 │
│ Used                      2.0 GB│
│ ████████████░░░░░░░             │
│                                 │
│ PROJECTS                        │
│ The Great Gatsby          640 MB│
│ Atomic Habits             480 MB│
│ Research Paper            210 MB│
│ Notes                      18 MB│
│                                 │
│ CACHE                           │
│ Generated Audio          1.8 GB │
│ Temporary Cache          120 MB │
│ Artwork                    8 MB │
│                                 │
│ [ Clear Temporary Cache ]      │
└─────────────────────────────────┘
```

Actions must distinguish:

- temporary cache: safe to clear
- generated audio: removable but requires regeneration
- source document: required project content
- whole project: destructive delete

Never use one ambiguous "Clear Cache" button for all categories.

---

# 12. Paywall / Pro

Use AppFoundation's paywall rather than designing a ReadAloud-specific purchase stack.

Entry points should occur at meaningful product boundaries, not randomly.

Potential gated actions:

- exceeding free Library limit
- advanced voices
- offline generation
- bulk generation
- advanced per-item customization

If an action is gated:

1. user should understand what they attempted
2. paywall should explain the relevant Pro benefit
3. dismissal should return them to the same context

---

# 13. Error states

Errors should be contextual.

## Import failure

```
Couldn’t Import This EPUB

ReadAloud couldn’t extract readable
chapters from this file.

[ Try Again ]
[ Choose Another File ]
```

## Generation failure

Keep the project usable:

```
Chapter 4 couldn’t be generated.

Your document is safe. You can retry
this chapter without affecting the rest.

[ Retry ]
```

## Corrupt project

Do not silently delete it.

Provide a clear recovery state and preserve source data whenever possible.

---

# 14. Loading and progress

Use the right progress style:

- determinate when real progress exists
- stage-based messaging when percentage is not meaningful
- inline activity for individual chapter generation
- project-level summary for bulk generation

Avoid blocking the whole app for background generation.

---

# 15. Device scope

ReadAloud 1.0 is iPhone-first and uses the same device-family convention as Spokio iOS, MiLove, and Palette.

Design for:

- compact iPhones
- large iPhones
- Dynamic Type
- landscape only where the system naturally allows it

Do not distort the iPhone architecture to anticipate an uncommitted iPad product.

Do not add iPad-specific layout work or `NavigationSplitView` support. ReadAloud's supported device family is iPhone only.

---

# 16. Accessibility

Required design considerations:

- Dynamic Type
- VoiceOver labels for playback/generation state
- sufficient contrast
- status not conveyed by color alone
- large tap targets
- playback actions usable without precision gestures
- reduced motion respected
- progress exposed semantically
- artwork not required to identify a project

---

# 17. Design terminology

Prefer user language:

| Internal concept | User-facing wording |
| --- | --- |
| Project | Book / Document where natural, Project only if needed |
| Item | Chapter / Section |
| Generated audio | Ready Offline / Offline Audio |
| Queue job | Waiting / Queued |
| Paragraph cache | Hide or Advanced Cache |
| Synthesis | Generate Audio |
| Runtime | Never expose |
| Manifest | Never expose |
| Source package | Original Document |

Internal engineering naming can remain precise; UI copy should remain human.

---

# 18. Design acceptance criteria

The design is successful when:

- a new user immediately understands how to add something to listen to
- returning users can resume in one tap
- Library feels like a durable collection, not recent files
- Project Detail makes chapter/offline state understandable
- Reader feels content-first and stable during playback
- playback remains accessible throughout navigation
- advanced generation/storage controls are available without dominating the core experience
- AppFoundation paywall/settings feel native to the product
- iPhone is excellent across supported device sizes
- no normal screen exposes implementation-specific package/cache/runtime jargon
