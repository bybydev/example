# Inkribe v1 — Feature Catalog

## Product promise

Inkribe is a premium, fully offline macOS speech-to-text workspace. The core workflow is:

```text
Record or Import → Transcribe → Review/Edit → Clean/Polish/Summarize → Export
```

The app is intentionally document/workspace-oriented in v1. System-wide dictation, meeting bots, cloud AI, and account features are outside the initial release.

## V1 feature list

| Area | Feature | V1 | Notes |
| --- | --- | :---: | --- |
| App shell | Custom macOS window shell | ✅ | Native `NSWindow` underneath; custom titlebar/sidebar/content chrome |
| App shell | Full-height sidebar divider | ✅ | Divider runs from top edge to bottom edge |
| App shell | Animated divider-attached sidebar toggle | ✅ | Toggle moves with sidebar width; state persists |
| App shell | MacAppFoundation themes | ✅ | Shared `MacAppThemeStore` |
| Recording | Microphone recording | ✅ | Local only |
| Recording | Pause / resume / stop | ✅ | Preserve one recording session |
| Recording | Input device selection | ✅ | macOS-specific adapter |
| Recording | Audio level meter | ✅ | Live input feedback |
| Import | Drag and drop | ✅ | Audio/video files |
| Import | File picker | ✅ | Native macOS picker |
| Import | WAV / M4A / MP3 | ✅ | Decode locally |
| Import | MP4 / MOV audio extraction | ✅ | Local media decoding |
| Import | Multi-file queue | ✅ | Queued/running/completed/failed/cancelled states |
| STT | `whisper.cpp` runtime | ✅ | Shared local package |
| STT | Bundled Whisper model | ✅ | No first-run model download |
| STT | Fully offline transcription | ✅ | No cloud fallback |
| STT | Apple Silicon acceleration | ✅ | Metal where supported |
| STT | Intel fallback | ✅ | CPU path supported |
| STT | Auto language detection | ✅ | Default behavior |
| STT | Manual language selection | ✅ | Optional override |
| STT | Segment timestamps | ✅ | Required for seeking/subtitle export |
| Library | Local transcript history | ✅ | No account/cloud dependency |
| Library | Search by title/content | ✅ | Local index/search |
| Library | Rename | ✅ | Transcript/document title |
| Library | Delete | ✅ | Clear ownership rules for associated source media |
| Editor | Editable transcript | ✅ | Preserve timestamp/source metadata |
| Editor | Synced audio playback | ✅ | Persistent player bar inside main column |
| Editor | Click timestamp/segment to seek | ✅ | Transcript ↔ audio navigation |
| Editor | Transcript search | ✅ | In-document search |
| Editor | Raw/original recoverability | ✅ | AI operations never silently destroy source text |
| Local AI | `llama.cpp` runtime | ✅ | Shared local package |
| Local AI | Bundled Qwen-class ~1.7B GGUF | ✅ | Exact model/revision pinned later |
| Local AI | Clean | ✅ | Punctuation, filler/repetition, obvious contextual corrections |
| Local AI | Polish | ✅ | Spoken-to-written cleanup while preserving meaning |
| Local AI | Summarize | ✅ | Derived document mode, not destructive overwrite |
| Local AI | Notes | ✅ | Structured derived output |
| Local AI | Action Items | ✅ | Structured derived output |
| Local AI | Preview before replacement | ✅ | Original vs transformed preview for destructive actions |
| Export | Copy to clipboard | ✅ | Current transcript/derived content |
| Export | TXT | ✅ | Unicode-safe |
| Export | Markdown | ✅ | Useful for notes/summary workflows |
| Export | SRT | ✅ | Segment timestamp based |
| Export | VTT | ✅ | Segment timestamp based |
| Settings | MacAppFoundation Settings scene | ✅ | Separate native Settings window |
| Settings | Appearance | ✅ | MAF built-in |
| Settings | Plan | ✅ | MAF built-in |
| Settings | Recording/transcription/AI/storage panes | ✅ | Inkribe-owned panes |
| Onboarding | MacAppFoundation onboarding shell | ✅ | Inkribe-owned page content |
| Commerce | Monthly Pro | ✅ | `com.hoangbkit.inkribe.pro.monthly` |
| Commerce | Yearly Pro | ✅ | `com.hoangbkit.inkribe.pro.yearly` |
| Commerce | Lifetime Pro | ✅ | `com.hoangbkit.inkribe.pro.lifetime` |
| Commerce | Pro plan button | ✅ | Main titlebar only |
| Commerce | Paywall / upsell / Pro badge | ✅ | MAF paywall + contextual upsells + badges + gate primitive wired to the centralized Pro policy |
| Developer | MAF Developer Tools window | ✅ Debug | Developer menu only |
| Developer | Spokio-style Logs window | ✅ Debug | Bounded in-memory logs, copy/clear, auto-scroll |
| CI | XcodeGen project | ✅ | Generated project committed |
| CI | Xcode Cloud fixture-model tests | ✅ | Never download production weights during test workflows |
| CI | Release model checksum validation | ✅ | Archive fails on missing/invalid production models |
| Architecture | Shared local Swift packages | ✅ | macOS 15+ and iOS 26+ from day one |

## V1 primary screens

1. **Library** — recent transcripts, search, Record and Import entry points.
2. **Recorder** — recording state, waveform/level meter, input device, language.
3. **Import Queue** — local processing queue for one or many files.
4. **Transcript Editor** — the primary working surface: transcript, timestamps, player, AI actions, export.
5. **Settings** — separate MacAppFoundation Settings scene.
6. **Paywall / Upsell** — MAF Pro paywall plus contextual upsells for Local AI, batch import, and subtitle export.
7. **Developer Tools / Logs** — Debug-only separate windows.

## Free vs Pro

The Free/Pro matrix is centralized in `InkribeProCapability`.

**Free**
- recording;
- single-file import/transcription;
- Library and transcript editing;
- Raw/Edited modes, search, synchronized playback, and timestamp seeking;
- copy, TXT, and Markdown export;
- access to existing transcripts and previously saved derived AI results.

**Pro**
- Local AI tools: Clean, Polish, Summarize, Notes, Action Items;
- multi-file batch import through the persistent transcription queue;
- SRT and WebVTT subtitle export.

The MAF paywall currently uses explicit placeholder Terms and Privacy URLs under `example.com`. Replace both with production legal URLs before App Store submission.

Rules:

- Existing recordings/transcripts must not become unreadable because entitlement changes.
- Verified StoreKit entitlement state is authoritative.
- Do not scatter `hasPro` checks through feature code; use centralized policy/gating.
- Local privacy behavior never changes based on plan. Free and Pro processing remain local.

## Explicitly deferred beyond v1

- system-wide global dictation hotkey
- automatic typing/pasting into the focused app
- system audio capture
- meeting-specific capture workflow
- speaker diarization / speaker naming
- word-level timestamp editor
- translation workflow
- watch folders
- Shortcuts / AppleScript / CLI automation
- cloud transcription
- cloud AI providers
- account/login system
- sync between Mac and future iOS app
- live collaborative editing
- full subtitle authoring/burn-in

## V1 product quality bar

A feature is not considered complete simply because the control exists. V1 must satisfy these product-level behaviors:

- all core transcription and AI workflows function with networking disabled
- long-running inference never blocks the main actor
- cancellation is supported where work is expensive
- errors are actionable and recoverable
- source audio and original transcript are not silently destroyed
- the transcript editor remains useful with dozens or hundreds of library items
- UI follows the same custom shell geometry and MacAppFoundation theme system everywhere
- Apple Silicon is first-class while the documented Intel baseline remains functional
- no runtime model download is required in a production install
