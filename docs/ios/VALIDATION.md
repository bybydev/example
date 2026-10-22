# V1 review and user testing

Agent work is source/document review only. No builds/tests, CI, Xcode generation, model downloads or device checks. Do not execute fixtures or call source inspection a test pass. User tests afterward.

Review identities, ownership, persistence, cancellation, stale-result guards, genuine time/Unicode, preview/export parity and Mac preservation. Record actual findings and incomplete V1 items separately from unrun checks.

User acceptance scenarios: P1 Photos/Files/offline reopen/rapid rename/duplicate/delete/cleanup/recovery; P2 local languages/word timing/chunk boundaries/long clips/cancel/errors; P3 correction/timing/split/merge/undo/keyboard/reopen; P4 real-footage styles/animations/Unicode; P5 MP4/audio/SRT/Save/Share/cancel/approved Pro/restore; P6 trim/caption boundaries/crop/volume parity; P7 complete import-to-export and interrupted/low-storage recovery.

Compilation, media compatibility, runtime fidelity, purchase behavior and device performance remain unverified until user results. Missing required functionality stays incomplete. Do not build testing/deployment infrastructure to satisfy this document.

## P1 follow-up user scenarios

Rapidly change a name during an in-flight save, submit/dismiss during debounce/write, relink while typing, and reopen the final draft. For the existing extra URL path, cover oversized declared length, absent/misreported length, exact-limit EOF and one byte over, cancellation, disk/network errors and temporary cleanup. These are pending user checks; no scenario was executed by the agent.
