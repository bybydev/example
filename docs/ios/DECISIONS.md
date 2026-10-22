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
| D10 | Latest develop, one PR per phase, all passes together, squash on completion | User / WORKFLOW |
| D11 | This planning PR stays unmerged until explicitly requested | Latest user instruction |
| D12 | No CI setup/triggers or device validation; user tests finished work | User / all |
| D13 | Root AGENTS: no builds/tests unless asked; XcodeGen source of truth | Repository / all |
| D14 | Six design refinements and preserved visual direction | User planning update / DESIGN |
| D15 | Local-first; remote providers/media transfer/publishing need explicit consent | Issue #21 / service owners |

## Open choices — resolve in owning phase

| ID | Choice | Owner / evidence to record |
|---|---|---|
| O01 | iOS bundle/product IDs, deployment support and source layout | P0; compare Mac values and current project configuration, without changing store accounts |
| O02 | Renderer technology and preview/export adapters | P0 feasibility; P4/P5 production; deterministic representative scene results and unrun checks |
| O03 | Project persistence format/schema and command transaction boundary | P0 contract/P1 implementation; migration, atomic write and recovery rationale |
| O04 | Exact iOS models and bundle/download policy | P2; inspect manifests/slices, licensing/size, failure UX; no implicit downloads or measured performance claims |
| O05 | Token-to-word grouping and forced alignment approach | P2; language/grapheme mapping, offsets/provenance and correction contract |
| O06 | Bounded decoding/recognition/diarization strategy | P2; avoid whole-buffer retention throughout pipeline; document unknown device performance |
| O07 | Editor tool labels/grouping and compact/keyboard layout | P3; present focused design for approval |
| O08 | Font resolution/import rights, deterministic fallback and alpha/color handling | P4/P5; capability profiles and actual implementation constraints |
| O09 | Clip time transforms including speed ramp/reverse/freeze semantics | P0 contract/P6 implementation; forward/inverse mappings and caption policy |
| O10 | iOS prices/free limits/plans and AppFoundation version | P5; user decisions required for unspecified commercial policy, no invented production prices |
| O11 | STT/translation/dubbing/generation provider capabilities and costs | P2/P7/P8; verify official APIs/rights when implementation reaches them |
| O12 | Publishing APIs and scheduling model | P11; actual platform rights and execution guarantees; never imply unsupported direct posting |
| O13 | Optional sync/backend, conflict rules and collaboration version model | P12; local workflow must remain functional |
| O14 | AI credit authority, idempotent accounting and team billing | P12; actual provider/server contract, no frontend-only authoritative ledger |

Unresolved is not unsupported, supported or complete. Record evidence and decisions when made. If external service/account selection is necessary, do useful independent work and ask only for the concrete missing choice. Do not deploy or procure services from a planning document.

## Change record format

For each resolved choice, record date, phase/PR, decision, alternatives considered, compatibility/migration impact, evidence collected, evidence not collected and feature IDs affected. Keep prior rationale when it explains a lasting constraint; update contradictory execution instructions rather than layering ambiguous exceptions.
