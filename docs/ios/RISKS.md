# Risk register

These are implementation risks, not measured failures. Device validation belongs to the user. Do not turn this register into an unsolicited benchmark/CI project.

| Risk | Owner | Required handling / evidence |
|---|---|---|
| Mac target rename changes identity/data/purchases | P0 | Audit settings, source memberships, bundle/product/storage roots; preserve values and document changed references |
| Manifest iOS declaration hides native binary/platform incompatibility | P0/P2 | Inspect package/native interfaces and available artifacts; report unresolved compatibility without claiming a device pass |
| Whole PCM arrays survive a nominal streaming redesign | P2 | Trace ownership through decode, model input, overlap and diarization; bound each retained stage |
| Token timestamps treated as accurate editable words | P2 | Explicit token-to-word/alignment contract; preserve uncertainty/provenance and manual repair |
| Retries or async AI overwrite manual changes | P2/P3/P7 | Stable operation IDs, revision check, proposal application and undo |
| Clip edits break caption/audio synchronization | P6 | Source vs project mapping; defined trim/reorder/speed/reverse policies and representative fixtures |
| Preview typography/animation differs from output | P0/P4/P5 | Shared deterministic scene evaluator, font resolution and same-time layout/easing |
| Cache deletion removes authoritative content | P1/P13 | Separate originals/documents/caches, explicit ownership and safe delete/recovery |
| Multiple cached repositories revive stale content | P1/P3 | One store owner; serialized writes and consistent invalidation/publication |
| Project migration corrupts or resets data | P1/P12 | Versioning, staged migration, backup/recovery and unsupported-version handling |
| Large output/storage shortage leaves fake completed exports | P5 | Staged output, final adopt/commit, actionable errors, temp cleanup and retry identity |
| iOS suspension invalidates durable-job expectations | P2/P5/P9/P11 | Persist state, handle interruption, resume/retry safely; no unlimited-background promise |
| Fonts/emoji/RTL/CJK produce unstable layout | P4/P7 | Grapheme-aware shaping/layout and explicit font availability/fallback policy |
| Provider/API/license capabilities cannot deliver catalog item | P2/P7/P8/P11 | Document specific evidence and substitute UX; retain unchecked item until limitation is accepted |
| Credits double-charge on retry/failure | P12 | Request idempotency, usage settlement/refund policy and authoritative service contract |
| Shared media and offline edits conflict destructively | P12 | Defined version/conflict model, original preservation and recoverable user choices |
| Reference image makes tiny or competing controls | P3 | Approved adaptive hierarchy, compact preview, contextual tracks and precise input |
| Agents confuse Mac v1 phase records with new iOS work | All | Keep docs/ios namespace and explicit phase status in HANDOFF |
| Agents run CI/build/device work from historical docs | All | Follow WORKFLOW and root AGENTS; source snapshot is not execution authorization |
| A phase is claimed complete through placeholders | All | Trace every checked feature to integrated behavior; separate dependency-pending and blocked items |

Update this register with actual findings and resolution links in phase PRs. No risk is marked resolved merely because documentation describes a mitigation.
