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
