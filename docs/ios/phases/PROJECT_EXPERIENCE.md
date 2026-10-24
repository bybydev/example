# Expanded Pass 1 — project experience (#41)

Parent #40. The user authorized implementation in one new PR from latest develop,
targeting develop, left open without auto-merge. This supersedes #41's planning-only
status and the old PR #39 work hold. Builds/typechecks/tests/fixtures, CI/generation,
models, native processing/exports and UI/device execution remain prohibited.

## Scope

| ID | Result |
|---|---|
| PROJECT.ONE_CREATION | One file or ordered files produce exactly one project; review/remove/reorder and retry |
| PROJECT.DETAILS | Combined preview, ordered clips, project defaults and retained exports |
| PROJECT.CLIP_EDITOR | Shared session, continuous clock, clip strip, grouped captions and seek |
| PROJECT.CLIP_NAMES | Rename individual clips from details/editor, restore imported names, persist and undo |
| PROJECT.CLIP_SETTINGS | Per-setting caption/framing/audio overrides, reset to current defaults, undo and output integration |
| PROJECT.EXPORTS | Queued/in-place generation, one durable inventory, file preview and native delivery |
| PROJECT.SAVING | Existing atomic single-writer saving integrated across new routes |

No separate-project import option. No post-creation clip ordering, new per-clip trim,
transitions, advanced multitrack or manual missing-caption authoring. No new output
frame-rate options: existing 30fps output remains project-wide. Preserve recognition,
raw/native timing/IDs, allowance, originals, purchases and Mac source/configuration.

## Contracts

Canonical schema 9 adds optional clip settings and reads schemas 1–8. Wrapper 1,
job names/payloads/IDs, checkpoint files and storage roots are unchanged. Clip overrides
are sparse optional values, never whole copied project defaults. Reset removes presence
fields; saved project defaults remain available after expiry. ClipSettings.displayName
is an optional 1–256-character trimmed label keyed by stable clip ID. No label means
the original imported name. Name-only records are retained but do not count as
style/media overrides. Every settings reset preserves the name; explicit original-name
restoration removes only the label. Labels use the same writer/history and duplicate
ID remapping, and do not alter canonical clips/checkpoints or the media key. Applying a clip preset
intentionally overrides its styling, preserving placement unless full reset is chosen.

Preview and MP4 use the same effective per-clip styles, framing and timed audio mix.
Frozen requests retain their complete captured document. Old requests can omit the new
optional creation date. Queue export and Export now use the same durable enqueue/gate;
Export now follows its job in-place and waits if capacity is occupied or the queue paused.

Source integration is not acceptance. See [handoff](../handoffs/PROJECT_EXPERIENCE.md).
