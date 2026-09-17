# Phase 7 Handoff — Export and Finishing Workflows

## Status

Phase 7 is implemented on PR #9.

Inkribe now supports local clipboard, TXT, Markdown, SRT, and WebVTT finishing workflows directly from the durable transcript document.

## Delivered

### Shared `InkribeExport` layer

- typed TXT / Markdown / SRT / VTT format contract
- explicit `TranscriptTextSource.edited` and `.raw`
- exact source selection without silent Raw/Edited fallback
- UTF-8 export document representation
- safe deterministic filename generation from transcript title + creation date
- TXT formatting
- Markdown formatting
- SRT formatting from timestamped segments
- WebVTT formatting from timestamped segments
- stable timestamp formatting
- negative/non-finite timestamp normalization
- invalid-duration repair to a minimum 1 ms cue
- valid overlapping subtitle timing preserved
- empty subtitle segment text skipped
- actionable failure when no usable timestamped segments exist

### Mac finishing workflow

- transcript titlebar export menu
- app-level **Transcript** command menu
- Copy Edited Transcript
- Copy Raw Transcript
- TXT → Edited / Raw
- Markdown → Edited / Raw
- SRT
- VTT
- `⌘⇧C` for Copy Edited Transcript
- `⌘⇧E` for Export Edited Plain Text
- native save panel with enforced selected content type
- safe default filename
- atomic file write
- user cancellation treated as a normal no-op rather than an error
- export actions enabled only while a transcript route is active

### Ownership and privacy

- export reads the existing durable `Transcript`; it creates no second persisted content model
- Raw Whisper text remains immutable
- Edited text is exported exactly as stored
- SRT/VTT remain segment-based because Edited prose has no timing-alignment contract
- JobQueue remains transcription/import-only
- AI/runtime packages are not involved in export
- diagnostic logging records only operation/format/source/error type, never transcript/exported content

## Tests added/updated

`InkribeExportTests` covers:

- explicit Edited vs Raw selection
- Unicode/UTF-8 preservation
- stored-whitespace preservation
- deterministic safe filename generation
- SRT cue ordering
- preservation of valid overlapping timestamps
- invalid start/end repair
- WebVTT header and millisecond syntax
- subtitle failure without usable timestamped text

Mac shell tests also cover active-transcript routing for command enablement.

## Important invariants for Phase 8+

1. `Transcript.editedText` and `Transcript.rawText` are separate explicit export sources; do not add hidden fallback between them.
2. SRT/VTT use `Transcript.segments`, not Edited prose.
3. Valid segment timestamps must not be rewritten merely to remove overlaps.
4. Export formatting belongs in cross-platform `InkribeExport`; AppKit clipboard/save-panel behavior belongs in `InkribeMac`.
5. Export never mutates transcript persistence.
6. Export remains a foreground local workflow; do not route it through JobQueue or model runtimes.
7. Export diagnostics must never contain transcript or exported text.

## Next phase

Phase 8 should focus on Settings, performance, and compatibility polish while preserving the existing shell, transcript, AI, and export contracts.
