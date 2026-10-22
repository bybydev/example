# V1 phased delivery and assessment

> Current amendment (2026-10-22): PR #30 is squash merged as eb89f0f. The user has now authorized Pro locking and AF themes; [phases/PRO.md](phases/PRO.md) and [handoffs/PRO.md](handoffs/PRO.md) supersede historical Pro deferral, 28/29 accounting and PR #30 review holds below. The new phase stays open on feat/ios-pro-access-themes → develop. All 29 V1 items are source-integrated; compilation/runtime/user validation is unrun.

This replaces the old P0–P13 roadmap. Difficulty/value are planning judgments for current scope. See PLAN and FEATURES.

| Phase | Result | Difficulty | Value | Status |
|---|---|---|---|---|
| [P0](phases/P0.md) | Target isolation and foundations | High | Essential | Merged #23; source-only evidence |
| [P1](phases/P1.md) | Local projects and import | Medium | Essential | Merged #24; reported source findings corrected, runtime unverified |
| [P2](phases/P2.md) | On-device transcription and word timing | High | Essential | Merged #25 (97d647e); model/native/runtime checks unrun |
| [P3](phases/P3.md) | Caption correction and simple timeline | High | Essential | Merged #26 (11902e6); compilation/runtime unverified |
| [P4](phases/P4.md) | Caption styles and curated animations | High | High | Merged #27 (ab67747); compilation/render/runtime unverified |
| [P5](phases/P5.md) | MP4/SRT export and simple Pro | High | Essential | Merged #28 (3c09e32); Pro deferred by user; compilation/runtime unverified |
| [P6](phases/P6.md) | Basic media editing | Medium–High | High | Merged #29 (e2bb512); compilation/runtime unverified |
| [P7](phases/P7.md) | V1 hardening and release handoff | Medium–High | Essential | Merged #30 (eb89f0f); compilation/runtime/user validation unrun |

Each phase is one PR from latest develop when requested. P1–P6 #24–#29 are merged. The optional-model follow-up and explicitly requested P7 hardening share PR #30; see MODELS.md and handoffs/P7.md. P7 is source-integrated with validation still unrun; P8–P13 retired. No estimated runtime performance or time commitment is implied.

## Authorized Pro follow-up

| Phase | Result | Difficulty | Value | Status |
|---|---|---|---|---|
| [Pro](phases/PRO.md) | Four approved Pro benefits, safe weekly allowance and AF themes/purchases | Medium–High | High | Source-integrated on feat/ios-pro-access-themes; PR held for review, validation unrun |
