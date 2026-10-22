# V1 risks and open findings

| Risk | Owner | Required response |
|---|---|---|
| Older autosave reload overwrites newer typing | P1/#24 | Corrected in source: one save drain, latest draft retained, returned revisions, no post-save reload; runtime unverified |
| URL size cap only after download | Existing P1 extra | Corrected in source: response-header and actual-byte cap, 64 KiB write buffer, session cancellation and partial-file cleanup; runtime unverified |
| Native iOS compatibility/model packaging unverified | P2 | Document source evidence/choice; no implicit downloads/builds |
| Whole-file PCM in Mac-oriented path | P2 | Bounded iOS decode/inference, preserve Mac |
| Token timings mistaken for real word boundaries | P2 | Genuine Unicode-aware mapping/offsets, no fabricated timing |
| Stale jobs/saves/player callbacks | P1–P3 | Project/session/revision guards |
| Preview/export layout/time/audio divergence | P4–P6 | One evaluator and frozen snapshot |
| Trim leaves incorrect caption output timing | P6 | Explicit mapping/boundary clipping and matching SRT |
| Low storage/cancel/corrupt/future schema | P1/P5/P7 | Preserve originals/valid document; recover or explain |
| Arbitrary Pro limits/pricing | P5 | User choice, centralized verified policy |
| Old catalog reintroduces scope | All | Only current PLAN/V1 IDs define work |
| Runtime correctness unverified | All | Honest source evidence; user tests afterward |

No cloud/team/publishing service risks need engineering because these features are outside v1.

## P2 residual limitations — source integration only

- Whisper Small is ~488 MB on disk, with unmeasured native inference memory/latency. CPU policy and bounded PCM do not prove SE2 runtime suitability.
- The pinned XCFramework's iOS slices, native links, Swift/API compilation and bundle resource copying have not been executed/verified.
- Model integrity hashing and native model initialization are synchronous; cancellation requested during initialization is observed after that stage returns. Native inference itself uses the existing abort callback; window decode checks cancellation.
- Word timing is approximate token-union timing, not forced alignment. Unicode/window seams, repeated speech and native timing availability need real samples/user testing.
- Recognition/raw text storage scales with transcript length; only decoded PCM/model execution concurrency is window-bounded.
- Jobs interrupted by process death restart from the beginning. A result already published under that job ID is reused. No uninterrupted background-processing guarantee or checkpointed partial caption results.
- Project revision changes during recognition cause explicit failure/retry; existing results/manual edits are preserved, not automatically rebased.

## P3 residual limitations — source integration only

- Editor/AVFoundation/SwiftUI APIs, schema migration, composition orientation/offsets and SE2 keyboard/accessibility remain uncompiled and unverified on device.
- Text fields correspond to retained timed units. A corrected phrase shares that unit's interval; no fresh word alignment is inferred. Hidden text retains IDs/timing; overlapping native intervals remain and use a deterministic preview tie-break.
- Undo is session-only, up to 50 changed-value patches and an estimated 8 MiB budget; one oversized command remains undoable. No persistent history feature. Validation/snapshot metadata still scales with transcript length.
- Autosave is debounced; abrupt termination/suspension before commit can leave the previous saved revision. Atomic writes protect it, not unsaved keystrokes. Conflicts keep the draft and require retry or explicit discard/reload, with no blind rebase.
- P3's former plain text overlay is replaced in P4 by a shared Core Text preview/bitmap/composition path. Actual P5 file output/profile integration and pixel parity remain unverified.

## P4 residual limitations — source integration only

- Core Text/Core Graphics/SwiftUI API compilation and native glyph output were not executed. Installed font availability/fallback, Vietnamese combining marks, CJK, RTL, ligatures and color/ZWJ emoji require user validation. Intrinsically colored emoji keep their font colors; karaoke does not promise to recolor bitmap glyphs.
- Word geometry/timing is inherited from P2/P3. A corrected phrase remains one timed unit; karaoke progression within that interval is a visual reveal, not new forced-alignment timestamps. Overlapping native intervals can highlight/reveal multiple words.
- Text above 16,384 UTF-16 units or not fitting eight lines/the canvas reports a split/reduce-size error. Metadata still scales with transcript length; only active layout/cache and pixel output are bounded. One renderer instance belongs to one render owner/queue.
- Actual memory/latency at the 20 Hz preview clock and future export frame rates are unmeasured. Bitmap allocation/per-frame integration needs P5 device assessment; no exported-file result is claimed.
- The same draw/layout/effect path exists for preview and output, but real 720p/1080p wrapping, antialiasing/color, orientation, output-aspect letterboxing and native preview geometry still need pixel/device validation.
- Caption styles are global for the project. Per-cue styles, imported fonts/brand libraries and custom effects remain outside v1.

## P5 residual limitations — source integration only

- AVFoundation/Core Image/SwiftUI/Photos APIs and Swift concurrency integration remain uncompiled. No exported file, media playback, pixel comparison, permission/provider/share operation or performance measurement was executed here.
- The shared media graph explicitly targets SDR Rec.709; Core Image output is sRGB. Actual HDR-to-SDR appearance, range/gamma/antialiasing, rotation, VFR cadence, gaps, source offsets and AAC sync/priming require user media/device validation. Stereo 48 kHz AAC uses the existing first-track policy, not surround/multi-track mastering.
- Six output buffers/two reader samples/one audio buffer bound app-owned references, not native decoder/encoder/GPU memory. Pool backpressure and the 30-second no-progress watchdog need real devices, especially SE2. Export overlays still allocate one bitmap per visible frame; throughput/thermal/memory behavior is unmeasured.
- Foreground interruption restarts from the frozen request. No continuous background export or partial-frame checkpointing. Large fallback media copies and native synchronous reader calls may delay cancellation until they return. Queue persistence failure can prevent a requested transition; it surfaces an error rather than claiming cancellation succeeded.
- Failed/cancelled requests retain pinned input for retry until discard/replacement; storage accounting counts logical bytes, so hard links can be counted in both project and export totals. The MP4 free-space check is an estimate, not a guarantee; writer/storage errors remain possible.
- SRT retains overlapping edited cues; player-specific overlap/markup rendering may differ from the preview's latest-active-cue rule. Plain SRT does not retain typography or animation. Millisecond outward rounding may extend boundaries by less than 1 ms.
- Pro is deferred by explicit user choice. No products/limits/pricing/gates/paywall purchase claims. It remains a separate user decision and incomplete V1 item.

## P6 residual limitations — source integration only

- No Swift/API compilation, native crop/mix/media export, playback, clock-frame generation, UI or device validation. Rotation/mirroring, clean-aperture/non-square pixels, SDR/HDR appearance, VFR boundaries, exact output duration, crop pan direction and AAC sync/gain still need user samples. The deprecated-but-existing mutable AV composition APIs were not migrated as unrelated work.
- Media settings are global and trim retains one contiguous project range. No per-clip trim/framing, reordering, ripple editing, keyframes, amplification, music or advanced production UI is claimed.
- Trim cannot infer partial text or new word alignment. A cut-through timed unit retains its text during the retained interval, while motion keeps original word phase. Caption timing fields use original project seconds, explicitly labeled; transport/list/SRT/video use retained output seconds. External SRT players may render overlaps/markup differently.
- Recognition still processes canonical original clips so later reset/expansion can reveal them. Trimming does not reduce the P2 model's source work. Editing revisions during recognition may require the existing explicit retry. P2 model/native compatibility and memory limitations remain.
- Actual live audio-mix updates, generation cancellation/rebuild timing, simultaneous save/undo and empty-gap black-clock playback are unmeasured. Native load/decode/writer calls can delay cancellation. Metadata dictionaries scale with transcript length; native model/GPU/decoder/encoder memory is not proven by app-owned buffer bounds.
- The tiny clock seed is process-cached temporary media, used only when no source samples remain. Native encoding failure must surface a useful error; it must never substitute for missing/corrupt expected sources. Source thumbnails remain source thumbnails; output duration is updated independently.
