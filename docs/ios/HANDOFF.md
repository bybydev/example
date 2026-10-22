# Live Inkribe iOS v1 handoff — 2026-10-22

Scope: current PLAN/FEATURES, 29 V1 items, P0–P7. The historical exhaustive catalog does not authorize features.

P0–P4 (#23–#27) are squash merged. P4 merge: ab677476ce904ea5d87cd8387e0da13a5d60710e. The user requested P5 next, from that latest develop, then explicitly chose **Defer Pro**. Current [PR #28](https://github.com/hoangbkit/Inkribe/pull/28), branch feat/ios-p5-export. **Leave it open for review; no merge/auto-merge until asked.**

P5 source integrates V1.MP4/SRT/DELIVERY/EXPORT_JOB: frozen saved revision/profile/pinned media, one durable JobQueue export, H.264 720p/1080p envelope at 30 fps with the P4 overlay and original AAC audio, audio-only black canvas, edited UTF-8 SRT, progress/cancel/retry, interruption restart and partial cleanup. Inspect finalized output before atomic publication. Native Save to Photos/Files/share holds delivery leases. Current-export access in Projects survives source-project deletion; storage accounts for its retained bytes. No batch renderer/history feature. Project schema stays v4.

V1.PRO is deferred, not complete. No new gates, plans, product IDs, prices, paywall or commercial restrictions. Existing AppFoundation/empty StoreKit scaffolding is unchanged. P6 remains unstarted trim/crop/volume using the shared graph and final output-time map; do not begin automatically.

Read [handoffs/P5.md](handoffs/P5.md) for exact entry points, persistence/lifetime contracts, P6 seams, known limitations and user scenarios. [handoffs/P4.md](handoffs/P4.md) retains style/renderer contracts; its prior PR review hold is historical. [handoffs/P2.md](handoffs/P2.md) retains model setup/hash. Earlier source integration is not runtime proof.

Only iOS source and its add-only Photos description in project.yml change. Mac/shared packages/generated projects/purchases/entitlements are preserved. Source reviewed only: no builds/typechecks/tests, CI, project regeneration, model downloads, deployment, pixel comparison or device validation. User tests afterward.
