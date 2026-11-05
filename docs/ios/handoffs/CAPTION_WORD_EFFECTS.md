# Issue #63 — caption word effects

2026-11-05. User-authorized stacked PR on #62 at
`8119966e71db23222a635c6e32316cd682c6635e`. Branch
`fix/ios-caption-highlighting` targets `fix/ios-improvements`. Keep the parent
unchanged and both PRs open without auto-merge.

## Delivered source

- [x] Highlight, Active color, Underline and Karaoke animate only eligible
  word-timed units in live iOS previews and newly created exports. Phrase/manual
  text remains visible in its base style. Mixed captions retain timed-word
  effects without whole-phrase emphasis or invented word sweeps.
- [x] Eligibility requires native word timing (or the presentation-only authored
  sample) and one lexical word. A multiword edit does not become word-timed merely
  because its original stable ID/provenance came from a native word. Existing
  Phrase timing notices cover these replacements as well as segment fallback.
- [x] Cache word eligibility with the renderer's existing cue layout; do not
  tokenize text at frame rate. Fonts, colors, layout and cue-level Pop/Fade/Rise
  effects stay unchanged.
- [x] Caption correction aligns unchanged lexical words, reuses existing slots
  for equal-count word replacements and retains the former character correction
  for phrase units. Insertions without a corresponding timing slot share an
  existing slot and are treated as phrases. No IDs, intervals or raw data change.
- [x] Keep one retained-word baseline throughout a typing interaction, including
  intermediate empty/partial fields. Reset on end-typing, changed scope or a
  non-append document reload. Coalesce multiword text patches with continuity
  checks so Undo restores the initial text and Redo the final correction.
- [x] Preserve #62's ordered retained-word scope validation. Only those word IDs
  are assigned corrected text; hidden trim words are untouched. Word-field and
  manual-caption storage paths remain intact.
- [x] Authored Style samples now qualify for the real word sweep; the native
  recognition provenance of user projects is never changed for this demo.
- [x] New frozen requests record optional `wordEffectVersion: 1`. Absent metadata
  keeps previous renderer behavior when old requests resume/retry. Unknown policy
  versions are rejected at frozen-request loading. Manifest wrapper version and
  project schema stay unchanged; completed files and frozen documents are intact.
- [x] Shared motion callers keep their old behavior unless explicitly opting in.
  Existing legacy motion regression sources remain unchanged; no Mac source,
  model, engine, queue policy, commerce or generated project changes are included.

## Verification and limits

Added `CaptionWordEffectTests` regression source for full/partial replacements,
unchanged interior words, insert/delete/clear, reuse of a typing baseline, retained
scope, phrase text, punctuation/Unicode, all four word effects, legacy policies
and unaffected cue animations. Tests are intentionally unexecuted under the
repository rules. Source review also traces sample provenance, render caching,
Undo patch continuity, save/reload and old/new export policy paths.

Validation consists of source/call-site/diff/whitespace review and verification of
remote base blobs, changed-file tree and stacked PR base/head. No builds,
typechecks, tests/fixtures, CI, project generation, native processing, playback,
exports or device/UI execution were run. Compilation and runtime acceptance are
unverified.

This is the proposed v1.0 rendering/edit correction. Recognition's phrase fallback
and already-collapsed saved edits do not gain missing word timestamps. Deeper
native timing recovery/realignment remains separate work; issue #63 should not
be automatically closed solely by this source change.
