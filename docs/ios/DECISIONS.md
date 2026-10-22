# Decisions and unresolved choices

## Fixed decisions

| ID | Decision | Source / owner |
|---|---|---|
| D01 | One repo; macOS target InkribeMac, iOS target Inkribe; product name Inkribe | User / P0 |
| D02 | Preserve Mac identifiers, purchases, data roots and behavior | Issue #21 / P0 onward |
| D03 | New iOS video-project domain; do not turn Mac Transcript into the editor graph | Issue #21 / P0/P1 |
| D04 | Reuse portable existing code; new package boundaries need a real second consumer | Issue #21 / all |
| D05 | Durable originals, immutable raw recognition and explicit editable/derived layers | Issue #21 / P1–P3 |
| D06 | Stable IDs, explicit revisions, source/project timing separation, deterministic scene evaluation | Issue #21 / P0–P6 |
| D07 | AppFoundation for iOS; MacAppFoundation stays Mac-only | Issue #21 / P0/P5 |
| D08 | JobQueue is processing state owner; project repository owns document content | Issue #21 / P1 onward |
| D09 | Full inventory remains; no silent MVP/v1 cuts | User / all |
| D10 | Latest develop, one PR per phase/all passes; latest explicit merge hold supersedes standing squash instruction | User / WORKFLOW |
| D11 | Planning PR #22 was squash merged; P0 PR #23 stays open for explicit review, no merge/auto-merge | User / 2026-10-22 |
| D12 | No CI setup/triggers or device validation; user tests finished work | User / all |
| D13 | Root AGENTS: no builds/tests unless asked; XcodeGen source of truth | Repository / all |
| D14 | Six design refinements and preserved visual direction | User planning update / DESIGN |
| D15 | Local-first; remote providers/media transfer/publishing need explicit consent | Issue #21 / service owners |

## Open choices — resolve in owning phase

| ID | Choice | Owner / evidence to record |
|---|---|---|
| O01 | **P0 source decision:** iOS IDs `com.hoangbkit.inkribe.ios[.debug]`, iOS 26, `InkribeIOS/`; product/display Inkribe. Store accounts/signing validation outstanding | P0/#23, source-only |
| O02 | **P0 spike decision:** CoreText/CoreGraphics for bounded text bitmap plus Core Image frame compositing shared between future preview and writer. AVFoundation adapters unresolved | P0/#23 source-only; P4/P5 integration, no runtime result |
| O03 | P0 tokens for version/revision/expected command added; actual format, migration/recovery, repository and transaction engine remain open | P0 contract / P1 implementation |
| O04 | Exact iOS models and bundle/download policy | P2; inspect manifests/slices, licensing/size, failure UX; no implicit downloads or measured performance claims |
| O05 | Token-to-word grouping and forced alignment approach | P2; language/grapheme mapping, offsets/provenance and correction contract |
| O06 | Bounded decoding/recognition/diarization strategy | P2; avoid whole-buffer retention throughout pipeline; document unknown device performance |
| O07 | Editor tool labels/grouping and compact/keyboard layout | P3; present focused design for approval |
| O08 | Font resolution/import rights, deterministic fallback and alpha/color handling | P4/P5; capability profiles and actual implementation constraints |
| O09 | P0 uses identity-speed source→project mapping only; speed ramp/reverse/freeze and caption mapping remain unresolved | P0/#23 seam, P6 implementation |
| O10 | iOS prices/free limits/plans and AppFoundation version | P5; user decisions required for unspecified commercial policy, no invented production prices |
| O11 | STT/translation/dubbing/generation provider capabilities and costs | P2/P7/P8; verify official APIs/rights when implementation reaches them |
| O12 | Publishing APIs and scheduling model | P11; actual platform rights and execution guarantees; never imply unsupported direct posting |
| O13 | Optional sync/backend, conflict rules and collaboration version model | P12; local workflow must remain functional |
| O14 | AI credit authority, idempotent accounting and team billing | P12; actual provider/server contract, no frontend-only authoritative ledger |

Unresolved is not unsupported, supported or complete. Record evidence and decisions when made. If external service/account selection is necessary, do useful independent work and ask only for the concrete missing choice. Do not deploy or procure services from a planning document.

## Change record format

For each resolved choice, record date, phase/PR, decision, alternatives considered, compatibility/migration impact, evidence collected, evidence not collected and feature IDs affected. Keep prior rationale when it explains a lasting constraint; update contradictory execution instructions rather than layering ambiguous exceptions.

## P0 decision record — 2026-10-22, PR #23

- **Targets / identity (O01):** Existing Mac target/scheme renamed to `InkribeMac` without changing bundle/product/display identifiers, storage, StoreKit IDs or entitlements. Test host/imports updated. New iOS `Inkribe` uses `InkribeIOS/` and distinct `.ios` bundle IDs; an iOS-only StoreKit test configuration with **zero products**, an empty entitlement dictionary and empty asset catalog; no iOS paid products or purchase simulation created. XcodeGen remains source of truth and generated project remains untouched.
- **App foundation:** AppFoundation tag `0.1.8` was read from its package manifest/source and pinned in project.yml for iOS only. Theme state has an iOS-owned key. No P5 commerce decision was made; no customer-visible UI was approved/implemented.
- **Renderer (O02):** Compared (a) SwiftUI/CA animation tied to wall/preview time (poor deterministic writer parity), (b) AVVideoCompositionCoreAnimationTool with CALayers (integration requires export timing/animation bake), (c) CoreText layout + Core Image compositing of one decoded clip frame at a rational timestamp (chosen for a shared pure evaluator and reusable pixel-buffer output), and (d) direct Metal rendering (too much shader/font work for P0). This is a source-level choice, **not** a measured winner or verified device outcome.
- **Schema/edit seam (O03):** Stable UUIDs + revision tokens + optimistic operation expectations exist as types. P1 still must own actual versioned JSON/package format, single repository, atomic adoption, migration fixtures/backup, unsupported future-version rejection and recovery of original content on failure. P3 owns actual command application, undo/redo and source/selection synchronization.
- **Time (O09):** Rational timestamps/half-open intervals with strict decoding and identity clip mapping; P6 will extend to non-identity transforms and specify overlaps/gaps/transitions. No client should assume independent per-frame floating point rounding.
- **Evidence:** Read `project.yml`, Mac app/storage/commerce/entitlements/StoreKit, Mac test modules, AppFoundation 0.1.8 source, native runtime manifests and selected runtime/decoder source. **Not performed:** build, runtime prototype run, pixel comparisons, native binary slice inspection, model download, iOS device validation or CI.
- **Feature inventory:** P0 owns zero feature IDs; nothing was checked off. Later owners are preserved.
