# Inkribe — Offline Local AI Contract

## Purpose

Inkribe provides constrained transcript transformation using selectable bundled local Qwen models through `LLMRuntime`. Qwen3 0.6B is the default; Qwen3 1.7B is available when the user prefers higher-quality output over speed and memory use. This is a document tool, not a generic chat surface.

The five v1 actions are:

- **Clean** — fix punctuation/capitalization, remove obvious filler/repetition, and conservatively correct clear speech-to-text mistakes.
- **Polish** — turn spoken phrasing into clearer written prose while preserving meaning and substantive detail.
- **Summarize** — produce a concise factual summary.
- **Notes** — produce structured headings/bullets.
- **Action Items** — extract explicit tasks or next steps without inventing commitments.

All Phase 6 inference is local. No network provider, API key, account, cloud queue, or remote fallback is part of this path.

## Ownership

`InkribeAI` owns:

- AI action semantics
- versioned prompt construction
- transcript input selection
- long-input chunking
- context-limit fallback
- ordered chunk processing
- derived-output merging
- progress and cancellation contracts
- generated-result metadata

`LLMRuntime` remains a generic actor-isolated local generation engine and owns native model/context lifetime.

`JSONTranscriptRepository` remains transcript-content truth.

JobQueue remains transcription/import processing truth. Phase 6 does not send AI transforms through JobQueue and does not introduce a second persisted scheduler.

## Input selection

AI generation operates on the current working document:

1. use `editedText` when it is non-empty after trimming;
2. otherwise fall back to `rawText`.

The editor saves any dirty `editedText` before starting generation so the source revision and generated result refer to durable content.

Empty input is rejected before model loading. Very short input is also rejected before inference.

## Prompt contract

`TranscriptAIPromptTemplates.version` identifies the checked-in prompt contract. The current implementation uses version 2.

Prompts:

- strongly describe transcript/partial-output blocks as untrusted data rather than instructions;
- instruct the model not to follow commands embedded in transcript text;
- forbid invented names, facts, commitments, dates, numbers, and conclusions;
- preserve source language;
- request only the transformed result, without prefaces or analysis;
- request no thinking output;
- keep the system policy separate from the user transformation request;
- let `LLMRuntime` apply the bundled GGUF model's native chat template through llama.cpp before tokenization;
- never hand-build ChatML/control tokens in `InkribeAI`;
- defensively remove exact standalone accidental result-wrapper lines before a result reaches the UI.

Prompt text and transcript contents are not written to diagnostic logs.

## Long transcripts and context limits

The first pass divides input into deterministic character-bounded chunks while preferring paragraph, newline, sentence, punctuation, and whitespace boundaries.

Character count is only an initial heuristic because tokenizer density varies by language/content. If `LLMRuntime` reports `promptTooLong`, `TranscriptAIService` recursively divides that source chunk again and retries the pieces in source order.

This makes the runtime's actual token/context check authoritative while avoiding unnecessary small chunks for ordinary text.

### Clean and Polish

Clean and Polish transform chunks independently and concatenate the transformed pieces in source order. They do not use a summarizing merge pass, because their job is to preserve substantive transcript content.

### Summary, Notes, and Action Items

Derived actions transform source chunks, then recursively merge partial outputs in pairs until one result remains.

Pairwise merging keeps merge prompts bounded and preserves ordering while allowing arbitrarily long source transcripts to reduce into one derived result.

## Progress and cancellation

`TranscriptAIProgress` exposes:

- preparing
- transforming
- merging
- finishing

The Mac editor presents local progress and an explicit Cancel action.

Cancellation propagates through `TranscriptAIService` to the actor-isolated `LLMRuntime`, which already owns native abort behavior. Cancelling never persists a partial result.

## Preview-before-mutation

Generation itself does not mutate a transcript.

Every result is first shown in a selectable preview. The user then chooses what to persist.

### Clean / Polish

Clean and Polish offer:

- **Replace Edited Text** — updates only `editedText` and advances transcript revision.
- **Save Copy** — stores the result as a `DerivedDocument` without replacing the working text.

Raw Whisper transcription remains untouched in either case.

### Summary / Notes / Action Items

These actions save as `DerivedDocument` values and cannot replace `editedText` through the Phase 6 apply API.

Derived documents retain `sourceRevision`, making older results visibly stale after later transcript edits.

## Revision safety

Every `TranscriptAIResult` records the transcript revision used for generation.

Applying a result fetches the latest transcript from the repository. If its current revision differs from the generated result's `sourceRevision`, application fails and the user must generate a fresh result.

This prevents a slow AI operation from overwriting edits made while generation was running.

Replacing edited text advances transcript revision once. Saving a derived result does not advance revision because it does not change the source transcript text.

Duplicate derived saves with the same kind, source revision, and content are ignored.

## Saved AI results

The transcript editor exposes saved derived results with:

- kind
- generated content
- creation date
- source revision
- an **Older revision** badge when the transcript has since changed

Missing or stale derived output never makes the transcript itself unavailable.

## Model lifetime and diagnostics

The Mac app keeps one shared local-AI controller so the selected bundled language model can remain loaded across transcript screens instead of being repeatedly recreated.

Settings persists the selected model. Changing that selection unloads the idle model/service so the next AI action constructs the newly selected runtime. The model picker is disabled while generation is active, so switching never tears a native runtime out from under an in-flight action.

The default retention policy releases the model after each completed, cancelled, or failed action. Users can opt to keep it loaded for faster repeated actions.

Diagnostics may record:

- action name
- transcript ID
- source revision
- progress/lifecycle state
- generation duration
- error type

Diagnostics must not record transcript text, prompts, partial outputs, or generated result content.

## Entitlements

Phase 6 does not invent Free/Pro gating. The repository's Free/Pro feature matrix is still intentionally unlocked.

If one or more AI actions are later selected as Pro features, the Mac presentation layer should add the appropriate MacAppFoundation gate/upsell while keeping the inference implementation and offline behavior unchanged.

## Phase 7 boundary

Phase 7 export should consume the existing document model:

- edited transcript text for normal text export;
- raw text only when explicitly selected;
- timestamped segments for subtitle formats;
- derived AI documents where a saved Summary/Notes/Action Items export path is appropriate.

Export should not duplicate AI generation, revision logic, or result persistence.
