# Phase 5 Handoff — Local Library and Transcript Editor

## Status

Phase 5 is implemented on PR #7.

The app now has a durable local transcript workspace on top of the Phase 4 repository/media pipeline: Library browse/search/sort/rename/delete plus a real transcript editor with raw-vs-edited text, timestamped segments, synchronized media playback, seeking, current-segment highlighting, and transcript-local search.

## Delivered

### Library

- durable transcript list from `JSONTranscriptRepository`
- newest-first default ordering
- oldest-first and title sorting
- local search across title, raw text, and edited text
- transcript excerpt/date/duration/language metadata
- rename with trimmed non-empty titles
- delete confirmation
- active-transcription protection before delete
- terminal queue-record cleanup before content deletion
- app-owned source media cleanup after content deletion
- Record and Import entry points
- direct transcript navigation
- explicit load/error/empty/search-empty states

### Transcript editor

- real primary detail surface replacing the Phase 1 placeholder
- editable user text
- read-only Raw transcription mode
- visible distinction between Raw and Edited text
- debounced continuous persistence
- explicit Save fallback while dirty
- final best-effort save on editor dismissal/navigation
- persisted revision increments only when edited text changes
- latest-document fetch before edit mutation, preserving raw text/segments/metadata
- transcript-local search and match count
- retained Whisper timestamped segments
- segment filtering
- click segment to seek
- current playback segment highlighting
- current-segment auto-scroll when search is inactive

### Playback

- `AVPlayer`-backed Mac playback controller
- playback from the existing app-owned source media reference
- audio and imported video sources use the same path
- play/pause
- ±10 second skip
- scrubbing/seek
- current time/duration display
- deterministic periodic-observer cleanup
- missing/unplayable media reported separately from transcript persistence errors
- transcript remains editable/searchable if source media is unavailable

### Shared logic

- `TranscriptLibraryQuery` in `InkribeCore`
- deterministic search/sort behavior
- UI labels remain in the Mac presentation layer
- no AppKit/MacAppFoundation dependency introduced into shared packages

## Tests added

- Library search across title/raw/edited content
- deterministic newest/oldest/title sorting
- rename normalization without revision change
- edited-text persistence with revision increment
- no revision change for identical saves
- delete removes transcript + app-owned source media
- active queue record blocks deletion
- edited transcript survives app-state relaunch
- reloaded edited content remains searchable
- playback rejects missing source media instead of entering a false prepared state

## Important invariants for Phase 6+

1. `JSONTranscriptRepository` remains transcript-content truth.
2. JobQueue remains processing-state truth; Library/editor do not create a second scheduler.
3. Raw Whisper text is preserved separately from user/AI-edited text.
4. Manual text edits advance transcript revision; rename does not.
5. Later AI actions should fetch the latest transcript before mutation, matching Phase 5 edit behavior.
6. Derived AI content should use `sourceRevision` so stale results can be identified.
7. Transcript deletion is blocked while related transcription is active.
8. Source playback uses the existing durable media reference; no duplicate media copy is created for the editor.
9. Missing media must not make transcript content unavailable.
10. The Library/editor remain inside the permanent Phase 1 main-column geometry.

## Next phase

Phase 6 should implement the bundled local AI text tools on top of this editor/document contract:

- clean transcript
- polish transcript
- summarize
- notes
- action items
- local Qwen/llama.cpp execution
- revision-aware derived output
- clear apply/replace behavior that never destroys Raw transcription

It should reuse `LLMRuntime`, `InkribeAI`, `Transcript.revision`, and `DerivedDocument.sourceRevision` rather than introducing a parallel content model.
