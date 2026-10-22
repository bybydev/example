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

## P0 observations (PR #23, 2026-10-22)

| Finding | Assessment / remaining action |
|---|---|
| Mac target rename | Source diff confines change to target/scheme/test host/Makefile, while preserving Mac bundle IDs, product/display name, store IDs/StoreKit, entitlements, data folder and source/model memberships. **Actual update/migration regression untested.** |
| Native iOS binaries | Whisper b5130, llama b10964 and sherpa-onnx 1.13.8 exist only as declared package dependencies/native references; iOS architectures/slices, codesigning/link and simulator/device launch remain unknown. Do not link them to iOS blindly. |
| Bounded STT | `InkribeAudio.AudioMediaDecoder` accumulates whole `[Float]` buffers and native STT/diarization consumes arrays; P2 must implement a genuine bounded pipeline before large-media claims. |
| Renderer feasibility | CoreText/Core Image source prototype composites a caller-provided oriented video frame and does not read/write playable clips. Real preview/export parity, color management/HDR, fonts, multilingual shaping and AVFoundation lifecycle must be validated/implemented in P4/P5. |
| iOS app surface | Intentionally `EmptyView` until P1 UI approval. This is not a functional project library or editor; no placeholder controls were shown. |
| Generated project | `project.yml` changed but `.xcodeproj` not regenerated per request. User must generate before compilation and inspect scheme memberships. |

Do not convert these into resolved risks based solely on source code. User-run checks are enumerated in [handoffs/P0.md](handoffs/P0.md).

- The iOS resource separation is explicit: `InkribeIOS/Resources/Inkribe.entitlements` grants no capabilities, `Assets.xcassets` contains no app icon, and `Inkribe.storekit` defines zero products. These are independent configuration containers, **not** implemented permissions, design assets or purchases. Their Xcode behavior remains unverified.
