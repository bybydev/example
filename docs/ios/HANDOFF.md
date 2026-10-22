# Live Inkribe iOS v1 handoff — 2026-10-22

Current PLAN/FEATURES defines 29 V1 items, P0–P7. The historical exhaustive catalog does not authorize features.

P0–P5 (#23–#28) are squash merged. P5 merge: 3c09e320bfef26c59c7b19bb7140f29015a07b73. The user requested P6 next. Current [PR #29](https://github.com/hoangbkit/Inkribe/pull/29), branch feat/ios-p6-media-editing, starts at that latest develop. **Leave it open for review; no merge/auto-merge until asked.** Pro remains explicitly deferred by the user's P5 choice.

P6 source integrates V1.TRIM/CROP/VOLUME: whole-project non-destructive trim; Original/9:16/1:1/16:9 aspect, source-oriented fit/fill/zoom/pan; and original-audio volume with live preview and shared export mix. Atomic media/canvas commands participate in bounded undo/redo and the same latest-draft save drain. Actual media rebuilds use debounce/generation guards and preserve original source playhead; volume-only edits do not rebuild the player.

Schema v5 adds optional media values and reads v1–v4 without eager writes. Original clips, raw recognition and native/manual caption intervals remain canonical and unchanged by media edits. One retained-range map clips/maps the output view to zero-based preview/list/timeline/MP4/SRT. Fully excluded units stay canonical for reset/undo; boundary text stays complete and effects keep original timing phase. Original cue priority survives clipped-start ties. Caption timing correction disclosures remain explicitly labeled original project seconds. Export manifests still use version 1; older requests preserve identity mapping and new requests freeze media values/retained assets. MP4 validates retained duration.

Read [handoffs/P6.md](handoffs/P6.md) for exact entry points, storage/mapping/undo/preview/mix contracts, limits and pending user checks. [handoffs/P5.md](handoffs/P5.md) records exports; its former hold is resolved. [handoffs/P2.md](handoffs/P2.md) retains model setup/native limitations. Pro stays deferred; P7 is not started automatically.

Only iOS source and phase documentation change. Mac/shared packages/project.yml/generated projects/purchases/entitlements are untouched. Source review only: no builds/typechecks/tests, CI, project generation, model downloads, native media exports/clock-seed generation, deployment, pixel comparison or device validation. User tests afterward; compilation, rendering/audio fidelity, UI and performance remain unverified.
