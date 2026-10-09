# ReadAloud 1.0 Persistence and Runtime Contract

## Purpose

This document defines the durable contracts that Phase 1 and later phases must preserve.

The Swift type layout may evolve, but on-disk semantics must remain compatible through explicit migrations.

---

## Package layout

```
<project-id>.readaloud/
├── project.json
├── source/
│   └── <source-id>.<ext>
├── content/
│   ├── manifest.json
│   └── items/
│       └── <item-id>.json
├── queue/
│   └── jobs.json
├── cache/
│   ├── paragraphs/
│   └── artwork/
├── audio/
│   ├── <item-id>.wav
│   └── <item-id>.metadata.json
├── assets/
└── temp/
```

Project and item filenames use stable lowercase UUID strings.

All persisted timestamps use an unambiguous ISO-8601 representation in UTC.

---

## project.json

Responsibilities:

- project identity
- package schema
- display metadata
- source reference
- project-level narration settings
- playback/resume state
- creation/update timestamps

Conceptual v1 shape:

```json
{
  "schemaVersion": 1,
  "id": "<uuid>",
  "title": "The Great Gatsby",
  "author": "F. Scott Fitzgerald",
  "source": {
    "id": "<uuid>",
    "type": "epub",
    "originalFileName": "gatsby.epub",
    "relativePath": "source/<source-id>.epub",
    "sourceRevision": "<sha256>"
  },
  "artwork": {
    "relativePath": "cache/artwork/cover.jpg"
  },
  "settings": {
    "voiceID": "af_heart",
    "speed": 1.0
  },
  "playback": {
    "currentItemID": "<uuid>",
    "contentBookmark": {
      "contentRevision": "<item-content-sha256>",
      "textOffsetUTF16": 240
    },
    "audioPosition": {
      "generationKey": "<sha256>",
      "audioRevision": "<wav-sha256>",
      "positionSeconds": 42.5
    },
    "projectProgress": 0.42,
    "lastPlayedAt": "..."
  },
  "createdAt": "...",
  "updatedAt": "..."
}
```

Rules:

- `id` never changes.
- rename changes `title`, not package filename or ID.
- source replacement is not a 1.0 feature.
- `sourceRevision` identifies the retained original source bytes.
- project playback state may be absent before first playback.
- project settings are defaults; they do not overwrite item overrides.

---

## content/manifest.json

Responsibilities:

- content schema
- ordered item list
- optional structural hierarchy
- project content revision

Conceptual shape:

```json
{
  "schemaVersion": 1,
  "contentRevision": "<sha256>",
  "items": [
    {
      "id": "<uuid>",
      "order": 0,
      "relativePath": "content/items/<item-id>.json",
      "parentID": null
    }
  ]
}
```

Rules:

- order is explicit; directory enumeration is never content ordering.
- IDs are generated at import and persisted.
- hierarchy may use `parentID` or an equivalent explicit representation.
- `contentRevision` changes when normalized playable/readable content changes.

---

## content/items/<item-id>.json

Responsibilities:

- chapter/section identity
- normalized text
- source locator
- metadata
- narration overrides
- item content revision

Conceptual shape:

```json
{
  "schemaVersion": 1,
  "id": "<uuid>",
  "title": "Chapter 1",
  "order": 0,
  "text": "...",
  "contentRevision": "<sha256>",
  "sourceLocator": {
    "kind": "epub",
    "value": "chapter1.xhtml#start"
  },
  "settings": {
    "voice": {
      "mode": "inherit",
      "customValue": null
    },
    "speed": {
      "mode": "inherit",
      "customValue": null
    }
  }
}
```

Rules:

- `id` is identity.
- `contentRevision` is compatibility.
- changing title alone does not invalidate generated audio.
- changing normalized spoken text does invalidate generated audio.
- absent item settings mean "inherit", not "copy current project value".
- voice and speed each store an independent selection mode and remembered custom value.
- selecting "inherit" must not clear the remembered custom value.

---

## Source locators

Source locators are descriptive/recovery metadata, not primary IDs.

Examples:

```
EPUB
kind: epub
value: <href + fragment / structural locator>

PDF
kind: pdf
value: <section + page range>

Document
kind: document
value: <extractor section locator>

Paste
kind: paste
value: <logical block index>
```

A parser upgrade may improve source locator metadata without changing the persisted item ID.

---

## Content revision

Use a deterministic SHA-256 over the canonical normalized spoken content.

For an item:

```
normalize text
   ↓
UTF-8 bytes
   ↓
SHA-256
   ↓
item.contentRevision
```

Canonical normalization rules must be owned by the content normalizer and versioned if semantics change materially.

The project-level content revision may hash the ordered item IDs + item revisions + relevant structural data.

---

## Voice and speed resolution

Project defaults remain nullable `voiceID` / `speed` values. Each item setting instead stores:

- `mode`: `inherit` or `custom`
- `customValue`: the last explicitly chosen custom voice ID or canonical synthesis speed; nullable before first selection

Resolve each field independently:

```
item.mode == custom → item.customValue
item.mode == inherit → project default ?? app default
```

Rules:

- a custom mode must have a valid custom value; reject an invalid saved setting with a recoverable error rather than silently changing narration.
- switching to Default changes only the mode to `inherit`.
- switching back to Custom restores the remembered custom value, including after relaunch.
- if there is no remembered value, entering Custom may seed it from the current effective value as part of that explicit user action.
- project/app default changes never overwrite remembered item values.
- generation keys use the resolved values, not the mode or inactive remembered values.
- resolving inherited values for generation must not persist them as custom values.

The UI label "Default" maps to the durable mode `inherit`. Speed here is Kokoro synthesis speed and affects the generation key; a separate playback-rate feature would need its own semantics.

---

## Playback bookmark and audio timeline

Persist both a content bookmark and an optional audio position for the current item:

- `contentBookmark.contentRevision`: revision of the normalized item text
- `contentBookmark.textOffsetUTF16`: zero-based UTF-16 offset at the start of the currently audible source segment
- `audioPosition.generationKey`: synthesis compatibility identity
- `audioPosition.audioRevision`: SHA-256 of the finalized WAV bytes identifying the actual saved timeline; absent until finalization
- `audioPosition.positionSeconds`: elapsed time on that timeline

Offsets are measured in the exact normalized item text persisted in `content/items/<id>.json`, not the original EPUB/PDF source. Segment boundaries must be valid text boundaries.

Restore policy:

1. If compatible finalized audio matches both the saved generation key and audio revision, resume at the saved seconds, clamped to its duration.
2. If compatible audio was regenerated with a different audio revision, even under the same generation key, locate the bookmark in its new segment map and resume at that segment's start.
3. If final audio is absent, synthesize/stream from the bookmarked segment; never interpret old seconds as an offset into a new stream.
4. A voice/synthesis-speed change or clearing generated audio preserves the content bookmark and invalidates the old audio position.
5. If the item content revision changed and no explicit migration maps the bookmark, reset that item's bookmark to its beginning and clear the old audio position. Never guess from an old text offset.
6. If the saved item is missing, select the first remaining playable item and reset its position; if none remain, expose an unavailable state.

Track the currently audible segment, not the furthest synthesized/prefetched segment. A generation key proves compatible synthesis inputs, not byte-identical output; the audio revision ties exact seconds to a specific finalized timeline. A saved stream without a finalized audio revision restores from its bookmark. Preserve exact seconds only for the same audio identity. Across regeneration, 1.0 promises segment-level resume and may replay the beginning of that segment; it does not promise word-level alignment.

Persist `projectProgress` as a derived display snapshot. Recompute it from the current content/bookmark rather than trusting a stale percentage as a resume locator.

---

## Generation key

A generated asset is compatible only when its generation key matches the current request.

Conceptual input:

```
GenerationKeyInput
├── item.contentRevision
├── resolvedVoiceID
├── canonicalSpeed
├── kokoroRuntimeRevision
└── synthesisConfigVersion
```

Serialize canonically and hash with SHA-256.

The exact encoded representation must be deterministic and covered by unit-level contract tests when testing is requested.

---

## audio/<item-id>.metadata.json

Responsibilities:

- generation compatibility
- audio characteristics
- provenance
- completion state

Conceptual shape:

```json
{
  "schemaVersion": 1,
  "itemID": "<uuid>",
  "generationKey": "<sha256>",
  "audioRevision": "<wav-sha256>",
  "contentRevision": "<sha256>",
  "voiceID": "af_heart",
  "speed": 1.0,
  "runtimeRevision": "<kokoro contract revision>",
  "synthesisConfigVersion": 1,
  "format": {
    "container": "wav",
    "sampleRate": 24000,
    "channels": 1
  },
  "durationSeconds": 123.4,
  "segments": [
    {
      "sourceRange": { "startUTF16": 0, "endUTF16": 120 },
      "startSeconds": 0.0,
      "endSeconds": 6.2
    }
  ],
  "createdAt": "..."
}
```

Rules:

- audio without valid matching metadata is not Ready Offline.
- matching metadata without a valid audio file is not Ready Offline.
- write final audio/metadata transactionally, including the source-segment timeline and SHA-256 of the finalized WAV bytes.
- each segment maps a source range in the normalized item text to its final audio interval.
- source ranges are half-open; times must be finite, ordered, non-overlapping, and within the final duration.
- capture actual emitted sample offsets during streaming/assembly and convert them to seconds at the stored sample rate; do not estimate timing from text length.
- segment mappings support regeneration resume and reliable chunk/paragraph highlighting; word-level alignment is not required.
- paragraph-cache reuse must preserve or reconstruct each reused segment's timing/source mapping.
- do not replace a known-good compatible asset until a replacement generation commits successfully.

---

## Paragraph cache

Suggested key inputs:

```
itemID
+ paragraph locator/index
+ normalized paragraph text revision
+ resolved voice
+ canonical speed
+ runtime revision
+ synthesis config version
```

The cache implementation may choose a hashed filename.

Cache entries are derived data and may always be deleted/rebuilt without affecting source/project correctness.

---

## queue/jobs.json

The queue is durable intent plus recovery state, not a serialization of live Tasks.

Conceptual shape:

```json
{
  "schemaVersion": 1,
  "jobs": [
    {
      "id": "<uuid>",
      "projectID": "<uuid>",
      "itemID": "<uuid>",
      "operation": "generate",
      "generationKey": "<sha256>",
      "state": "queued",
      "createdAt": "...",
      "updatedAt": "...",
      "attempt": 0,
      "lastError": null
    }
  ]
}
```

Durable states should stay simple:

- queued
- failed
- completed if history is retained

`generating` is primarily runtime state. If persisted for observability, startup recovery must never assume the process is still doing that work.

On cold launch, stale in-progress state becomes queued/retryable according to policy.

---

## Background execution contract

Playback and generation have different guarantees.

### Playback

Playback may continue under iOS background audio mode.

Persist position periodically and on meaningful lifecycle transitions.

### Generation

Generation:

- may continue while execution time is available
- may be suspended or terminated by iOS
- must persist enough intent/state to recover
- must not depend on indefinite background runtime

A generation operation is complete only after durable audio + matching metadata are committed.

---

## Atomic write rules

Use temporary files/directories and replace/rename on successful completion where practical.

Atomicity is especially important for:

- project.json
- manifest.json
- item JSON
- queue/jobs.json
- final audio metadata
- final audio replacement
- migrations

Temporary/intermediate work belongs under `temp/`.

---

## Migration contract

Each durable JSON file has a schema version.

Migration rules:

1. decode version explicitly.
2. migrate in ordered steps.
3. never silently reinterpret a field.
4. preserve source files.
5. preserve known-good audio unless migration explicitly proves incompatibility.
6. derived caches can be discarded/rebuilt.
7. reject unsupported future schemas safely.

---

## 1.0 re-import rule

ReadAloud 1.0 does not reconcile a changed external source into an existing project.

Importing the same source again creates a new project.

This avoids hidden item-ID remapping and cache invalidation semantics in 1.0.

A future "Replace Source" or "Re-import" feature must define reconciliation as a separate contract.


## Bounded Listen processing (configuration 2)

The source text and source bookmark remain authoritative when oversized paragraphs
are split for Reader/synthesis. New ranges are measured in the original UTF-16
text; stored content revisions and item IDs do not change. Configuration 2 makes
old derived paragraph/final audio incompatible rather than accepting audio with
an outdated source timeline. Existing source bookmarks fall back to the new
containing slice; exact seconds require matching generation/audio revisions.

Final WAV assembly is temporary and file-backed. Failed or cancelled assembly
removes its own temporary file, and the existing pair transaction remains
responsible for commit/rollback. Safe admission failures never delete a project,
its source, or its previous final-audio pair.
