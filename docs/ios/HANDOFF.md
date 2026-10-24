# Inkribe iOS — current handoff

2026-10-24. Expanded Pass 1 (#41, parent #40) is source-integrated in
feat/ios-pass1-project-experience → develop, based on 4a9780f. Leave the new PR open
without auto-merge. #39 is already merged in that base; its old open-PR holds are historical.

See [the complete marked handoff](handoffs/PROJECT_EXPERIENCE.md) for source ownership,
six implemented areas, compatibility limits, six authored/unrun specifications and
the pending build/device/output acceptance checklist.

- One creation makes one project with one/multiple ordered clips. Failed selection
  items require retry/removal; no separate-project option or silent subset publication.
- Project details and the scrolling editor share one app-owned session/writer. Clip
  entry points and caption groups use stable identities and the existing output clock.
- Schema 9 adds sparse clip overrides and reads 1–8. Reset restores live inheritance,
  preserving text/timing/trim. Duplicate remaps clip IDs. Caption-only changes do not
  invalidate media composition. Preview/MP4 resolve the same effective clip settings.
- Both export entry points use the existing durable worker/gate. Export now follows
  progress in-place. Project exports show retained results, actual-file preview and
  native delivery; immutable requests include their saved defaults and clip overrides.
- Existing atomic saves retain failed changes in memory across navigation, with one
  friendly failure/retry. Unwritten changes are not guaranteed across process death.
- No Mac source/config, purchases, model policy, native recognition or allowance rules
  are changed. No legacy conversion job, editor sidecar or advanced sequencing is added.

Source/call-site/diff/whitespace/publication review only. No builds/typechecks/tests/
fixtures, CI/generation/models/native inference/exports/UI/device/accessibility/deployment
ran. Compilation, strict concurrency, real media/output parity, provider/delivery,
save-failure, entitlement and supported-phone behavior remain unverified.

[Production readiness](PRODUCTION_READINESS.md) still owns release gates. Parent
passes 2–5 remain separate; no next pass or merge is authorized automatically.
Historical source evidence remains in CONSOLIDATION, earlier phase handoffs and archive.
