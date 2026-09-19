# Export and Finishing Workflows

## Scope

Phase 7 adds deterministic, fully local finishing actions for durable `Transcript` documents:

- copy Edited transcript text
- copy Raw Whisper transcript text
- export Edited or Raw text as UTF-8 TXT
- export Edited or Raw text as UTF-8 Markdown
- export timestamped transcript segments as SRT
- export timestamped transcript segments as WebVTT

Formatting logic belongs to the cross-platform `InkribeExport` package. AppKit-only clipboard and save-panel behavior stays in the macOS app layer.

## Source semantics

`TranscriptTextSource` has two explicit values:

- `edited` — the exact current `Transcript.editedText` value
- `raw` — the exact immutable `Transcript.rawText` value

No implicit fallback occurs between them. If Edited text is intentionally empty, exporting Edited text produces an empty body rather than silently substituting Raw text.

Text-source selection applies only to clipboard, TXT, and Markdown.

SRT and WebVTT are generated from `Transcript.segments`. Edited prose is not substituted into subtitle cues because the edited document has no segment-level timing alignment contract. When a segment has a diarized `speakerID`, export prefixes its persisted display name (for example, `Alice: Hello`). Speakerless/legacy segments export exactly as before.

## Text formats

### Clipboard

Copy writes the selected Edited or Raw string to the system pasteboard without modifying transcript persistence.

### TXT

TXT is the selected transcript source encoded as UTF-8 without normalization or content rewriting.

### Markdown

Markdown contains a level-one heading from the transcript title followed by the selected source text. Newlines in the title are collapsed for the heading. Transcript body content is preserved rather than rewritten as Markdown structure.

## Subtitle formats

Subtitle export uses non-empty timestamped transcript segments.

Behavior:

- cues are ordered by normalized start time, preserving original order when starts are equal
- negative or non-finite timestamps are clamped to zero
- an end time that is not later than its start is repaired to `start + 1 ms`
- valid overlapping cues keep their original timestamps; export does not shift them to remove overlap
- SRT uses `HH:MM:SS,mmm`
- WebVTT uses `HH:MM:SS.mmm` and begins with `WEBVTT`
- empty segment text is skipped
- persisted speaker names are prefixed when a segment has a speaker assignment
- subtitle export fails with an actionable error when no usable timestamped segments exist

The formatter does not mutate persisted segment data.

## Filenames

`TranscriptExporter` generates a default filename from:

```text
<safe transcript title> - YYYY-MM-DD.<extension>
```

The date is the transcript creation date interpreted with the exporter's calendar. Filename-invalid/control characters are replaced, whitespace is collapsed, leading/trailing dots/spaces are removed, and an unusable title falls back to `Transcript`.

The Mac save panel enforces the selected format's content type and extension while still allowing the user to choose the destination directory and base name.

## Mac UI

Export is available only while a transcript route is active.

The transcript titlebar export menu and the app-level **Transcript** menu expose the same semantics:

- Copy Edited Transcript
- Copy Raw Transcript
- Export Plain Text → Edited / Raw
- Export Markdown → Edited / Raw
- Export SRT
- Export VTT

Keyboard shortcuts:

- `⌘⇧C` — Copy Edited Transcript
- `⌘⇧E` — Export Edited Plain Text

SRT/VTT commands do not present a misleading Edited/Raw choice.

## Privacy and ownership

Export is an explicit foreground user action. It does not use JobQueue, model runtimes, analytics, accounts, or network services.

Export diagnostics may record operation/format/source/error type, but never transcript/exported content.

`Transcript` remains the only content source of truth; export creates a transient formatted document and never introduces a second persisted representation.
