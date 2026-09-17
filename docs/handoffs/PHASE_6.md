# Phase 6 Handoff — Offline AI Cleanup and Text Tools

## Status

Phase 6 is implemented on PR #8.

Inkribe now has a fully local transcript-AI workflow using the bundled Qwen/`llama.cpp` stack for Clean, Polish, Summarize, Notes, and Action Items. Generation is preview-first, cancellable, context-safe for long input, and revision-aware before persistence.

## Delivered

### Shared `InkribeAI` layer

- five typed `TranscriptAIAction` values
- action-to-derived-document mapping
- Clean/Polish-only edited-text replacement contract
- versioned prompt templates
- prompt-injection/data-boundary guardrails
- explicit no-invention constraints
- edited-text-first input selection with raw fallback
- empty/short-input rejection before model loading
- deterministic transcript chunking
- adaptive re-splitting when the native runtime reports `promptTooLong`
- ordered Clean/Polish chunk concatenation
- pairwise recursive merge for Summary/Notes/Action Items
- typed progress phases
- cancellation propagation
- explicit model unload path
- result metadata containing source revision and prompt version
- thinking-output sanitation before any result reaches the UI

### Mac transcript workflow

- compact Local AI menu in the existing transcript editor
- Clean
- Polish
- Summarize
- Notes
- Action Items
- dirty transcript text is persisted before generation
- local generation progress
- explicit Cancel action
- selectable result preview before mutation
- Clean/Polish: Replace Edited Text or Save Copy
- Summary/Notes/Action Items: Save to Transcript as derived content
- Saved AI Results browser
- source-revision display
- stale/older derived-result badge
- no GGUF/native-runtime terminology in feature UI

### Persistence safety

- generation does not mutate transcript content
- result application always reloads the latest transcript
- stale generated results are rejected when transcript revision has changed
- Raw Whisper text is never changed by AI apply
- replacing Edited text advances revision once
- saving a derived result does not advance source revision
- duplicate derived saves are idempotent
- JobQueue ownership remains unchanged

### Model/runtime behavior

- one shared app-level AI controller retains the local service/model across transcript screens
- inference path uses bundled `LLMRuntime` only
- no account, API key, remote provider, network request, or cloud fallback
- runtime cancellation reaches the native abort path
- operational logging contains action/ID/revision/timing/error type only, never prompt/transcript/result content

## Tests added

`InkribeAITests` now covers:

- exact chunk order/content preservation
- versioned prompt guardrails
- tokenizer-compatible prompt envelope
- Clean chunk ordering without summarizing merge
- recursive derived-output merge
- adaptive re-splitting after `promptTooLong`
- edited-text preference over raw text
- thinking-output stripping
- empty/very-short input rejection before model load
- preparing/transforming/merging/finishing progress
- cancellation propagation to runtime

Mac app tests cover:

- Clean replacement preserves Raw text and advances revision
- stale AI results cannot overwrite newer edits
- derived result persistence without source-revision change
- duplicate derived saves are idempotent
- Summary cannot replace Edited transcript text

## Important invariants for Phase 7+

1. Raw Whisper text remains recoverable and immutable through AI transforms.
2. `editedText` is the current user/AI working copy.
3. `sourceRevision` is mandatory for generated-result freshness.
4. Clean/Polish are the only Phase 6 actions allowed to replace Edited text.
5. Summary/Notes/Action Items are derived documents, not transcript replacement modes.
6. Generated content must be previewed before persistence.
7. Long-input safety is owned by `InkribeAI` + the runtime's actual context error, not by UI character limits.
8. JobQueue continues to own transcription/import work only.
9. No transcript/prompt/generated content belongs in diagnostics.
10. AI entitlement gating remains undecided until the product Free/Pro matrix is locked.

## Next phase

Phase 7 should implement export and finishing workflows on top of the existing transcript document:

- copy
- TXT
- Markdown
- SRT
- VTT
- edited/raw source selection where appropriate
- timestamped segments for subtitle formats
- optional export of saved derived AI content where product UX calls for it

Phase 7 should reuse `InkribeExport`, transcript segments, Edited/Raw text semantics, and saved `DerivedDocument` values rather than introducing another document representation.
