# Original phase plan and assessment

Copied from issue #21 on 2026-10-22, preserving its full phase descriptions, difficulty/value assessment and internal work units. [PLAN.md](PLAN.md) and [phase briefs](phases/P0.md) provide current execution detail. [WORKFLOW.md](WORKFLOW.md) and root AGENTS.md override historical permissions: no CI setup/runs, device validation, or build/test execution unless explicitly asked; the planning PR stays unmerged until the user requests merge. Internal units stay in one PR per phase.

## Phased implementation plan — complete roadmap

Phases are dependency-ordered workstreams, **not release cuts or permission to implement**. Features are detailed and individually tracked in the inventory below. Each phase includes appropriate correctness checks and documented user acceptance criteria. CI setup/runs and device validation are excluded from the agent's phase work; the user will test after implementation.

| Phase | Area | Deliverables / exit criteria |
|---|---|---|
| **P0** | Target isolation, feasibility, architecture | Audit Mac target migration and signing; rename its XcodeGen target/scheme to `InkribeMac` while preserving bundle ID and data; add iOS target `Inkribe`, separate schemes and StoreKit configuration without CI setup; document model/renderer constraints, schema, focused local checks and risk register, with device-dependent assumptions deferred to user testing. Include a small renderer feasibility spike proving shared preview/export layout and animation timing before building the P4 preset catalog; anticipate P6 multi-track composition. No Mac regression. |
| **P1** | Media import and project foundation | Ingest videos/audio from Photos, Files, share/URLs/providers; immutable app-owned originals, media metadata, compositional project documents, multi-clip sources, stable project IDs, safe caches, recovery, migration fixtures; basic local project dashboard, browsing, autosave and offline reopening. |
| **P2** | Speech transcription and timing | Adapt iOS Whisper/model packaging, bounded audio decode, language selection, optional cloud STT, diarization, word timestamps/forced alignment, confidence, punctuation, incremental/retry/cancel. Implement timing correctness and bounded-memory handling; document unmeasured iPhone accuracy/performance assumptions for the user's testing. |
| **P3** | Caption/text/timeline editing UX | Two-way transcript/timeline editing, word+cue timing, waveform, split/merge, multi-track, search, undo, gestures, snapping, precision, iPad and keyboard interaction. No accidental source edit; state survives relaunch. |
| **P4** | Typography and animated caption engine | Fonts/styles/positioning/safe areas; word-level karaoke, entrances/exits, keyframes/easing, per-word emphasis, motion presets, deterministic timed preview. |
| **P5** | Renderer, caption modes, delivery | Frame-accurate composition, video + alpha/chroma overlays, caption modes, local subtitle/transcript output, video codecs/resolutions, render queue, cancellation/retry, render fidelity tests; individual-user purchase, restore and entitlement enforcement integrated before any paid release. |
| **P6** | Full non-destructive video and audio editor | Multi-track media editing, trimming/reordering/speed/keyframes/transitions/crop/color, voice/music/noise tools, voiceover and sync correctness. Rendering and document schema remain coherent. |
| **P7** | AI captions and localization | Smart styling, keyword/emoji/emotion emphasis, natural-language styling, translation, bilingual/RTL/CJK, dubbing and consent safeguards; preview and opt-in for destructive/remote changes. |
| **P8** | AI video editing and enhancement | Silence/retake/filler cuts, reframing, hooks, highlights, B-roll, generation, gaze/face effects where feasible; suggested edit plans, licenses/consent, reversible edits. |
| **P9** | Recording and teleprompter | Native camera, microphones, recording presets, prompter scripts/voice follow, multiple takes, direct caption workflow, recovery from interruptions. |
| **P10** | Motion overlays, reusable templates and brands | Titles, stickers, graphics, tracking, masking, preset library, custom imported fonts/styles, template sharing, multi-brand kits, design consistency. |
| **P11** | Creator publishing, automation and batch | Social presets, thumbnails, hook copy, multiple aspect outputs, permitted integrations/publishing, comprehensive batch pipelines, processing profiles/Shortcuts/queue, desktop-only automation only if Mac scope separately approved. |
| **P12** | Library, cloud collaboration and monetization | Advanced organization/history/backup, optional cloud sync, shared teams/comments/approval/version conflicts, AI credits and team billing. Basic library/autosave arrive in P1; individual-user purchases/restoration arrive with P5 before any paid release. Keep local-only usage functional. |
| **P13** | Accessibility, professional QA, performance and release hardening | Verify the entire feature inventory; closed caption QA, VoiceOver, reduced motion, contrast/flash safety, reliability, thermal/memory/storage/export failure/relaunch tests, migration and privacy audits. Cross-cutting criteria also apply to every earlier phase. |

**Important sequencing details:**

- P13 criteria are **continuous quality gates**, not work deferred until after features are complete.
- Renderer feasibility belongs in P0. P4/P5 must share a proven layout, animation and timing approach before the full preset catalog is built, and anticipate P6's multi-track editing. The P0 spike is limited feasibility work, not completion of the production renderer.
- P2–P5 establish the core captioning workflow: accurate word timing → comfortable correction → attractive animation → matching export. This identifies the first end-to-end proof, not a reduction of the complete feature inventory.
- Basic local library, autosave and offline reopening belong in P1. Individual-user purchases, restoration and export-time entitlement validation must be integrated by P5 before any paid release. P12 retains advanced organization, sync, collaboration, credits and team billing.
- Phase numbers denote primary ownership, not a strict waterfall. Deliver dependent features only when their prerequisites exist: for example, P5 bilingual/localized delivery depends on P7 translation, and P7 dubbing synchronization depends on the relevant P6 audio composition capabilities.
- Collaboration/cloud remains optional to using the fully featured local editor. External integrations remain subject to verified official API capabilities.

### Phase difficulty and product value assessment — 2026-10-22

Assessment covers each phase's **complete scope**, including its advanced capabilities. Difficulty uses **10 = hardest**; value uses **10 = strongest benefit to creators**, with foundational value identified separately. Scores are relative engineering/product judgments, not time estimates or validated market demand. They assume prerequisite capabilities exist.

Basis: issue inventory and a read-only inspection of current master `project.yml`, `Transcript.swift`, `AudioMediaDecoder.swift` and `docs/ARCHITECTURE.md`. No builds, tests, benchmarks or implementation were performed for this assessment. Mac transcription infrastructure provides reuse, but the existing segment-based transcript and whole-file decoder do not establish readiness for an iPhone video editor.

| Phase | Area | Difficulty | Value | Assessment |
|---|---|---:|---:|---|
| **P0** | Target isolation and architecture | **4/10** | **8/10 — foundational** | Target setup is manageable; preserving Mac identity, purchases and build flows needs care. Early timing and renderer experiments can prevent expensive redesigns. |
| **P1** | Import and project foundation | **6/10** | **9/10** | Basic import is straightforward; durable originals, multi-clip projects, interrupted imports, storage and recovery make the full phase substantial. Essential groundwork. |
| **P2** | Transcription and word timing | **8/10** | **10/10** | Existing Whisper infrastructure helps. Accurate word boundaries, alignment after edits, diarization, mixed languages and bounded iPhone memory are the difficult parts. Caption quality depends on this. |
| **P3** | Caption and timeline editing | **8/10** | **10/10** | Keeping transcript, words, selection, playback, timeline and undo synchronized is difficult. Excellent correction tools make imperfect recognition usable. |
| **P4** | Typography and animated captions | **9/10** | **10/10** | A few effects are manageable; a complete engine with per-word styling, keyframes, stable layout, fonts, emoji and predictable animation is much harder. Strongest visual differentiation. |
| **P5** | Renderer and export | **9/10** | **10/10** | Matching preview and export across timing, fonts, codecs, orientation and resolutions is a major engineering challenge. Reliable exported video is essential to delivering value. |
| **P6** | Full video and audio editor | **10/10** | **8/10** | Multi-track composition, speed ramps, transitions, effects and audio processing amount to a major product inside the product. Convenient for creators, with a large maintenance burden. |
| **P7** | AI captions and localization | **9/10** | **8/10** | Keyword emphasis and style suggestions are comparatively accessible. Translation quality, RTL/CJK layout, synchronized dubbing and voice preservation make the complete phase much harder. |
| **P8** | AI video editing and enhancement | **10/10** | **8/10** | Silence removal is tractable; reliable retake selection, highlights, generated B-roll, gaze effects and natural-language editing are separate complex systems. High potential, highest uncertainty. |
| **P9** | Camera and teleprompter | **7/10** | **7/10** | Basic recording and scrolling scripts are manageable. Voice following, microphone routing, interruptions, monitoring and take recovery need deeper work. Most valuable to talking-head creators. |
| **P10** | Overlays, templates and brands | **8/10** | **9/10** | Saved styles and brand kits offer strong repeat-use value. Tracking, masking, blend modes and portable templates greatly expand implementation. Benefits heavily from P4–P6. |
| **P11** | Publishing, automation and batch | **8/10** | **8/10** | Batch workflows and multiple output versions save recurring effort. Publishing integrations add external dependencies and ongoing maintenance; feasibility is not yet verified. |
| **P12** | Library, collaboration and monetization | **9/10** | **8/10** | Basic organization and purchases are manageable. Shared media, offline sync, version conflicts, permissions and team billing dominate difficulty. Value varies greatly between individuals and teams. |
| **P13** | Accessibility, QA and hardening | **8/10** | **10/10** | The challenge is the interaction matrix: edits, languages, media types, devices, storage failures and exports. Protects users' work and confidence; effort grows with every earlier phase. |

**Priority implications:** Reusable caption styles/templates, fast text correction and dependable export offer particularly strong value relative to effort. P6's complete general video editor and P8's advanced AI effects are the largest scope commitments. The complete roadmap remains in scope.

### Implementation units within large phases

These units are internal planning steps within their parent phase, not separate PRs. Before implementation, map affected inventory items to units and define dependencies and exit criteria. Keep all units and passes of an authorized phase in its single PR targeting `develop`; further subdivision for planning does not create additional or stacked PRs.

| Phase | Proposed units | Dependency / completion guidance |
|---|---|---|
| **P6** | **P6a:** clip editing, multi-track composition and source/timeline mapping. **P6b:** speed, keyframes, transitions and visual effects. **P6c:** audio editing, mixing, voiceover and enhancement. | Prove caption/audio timing after clip and speed changes. Implement advanced effects against the same document and rendering contracts. Record model and music licensing constraints individually. |
| **P7** | **P7a:** smart styling and reviewed caption cleanup. **P7b:** translation, localization and multilingual typography. **P7c:** dubbing, voice preservation and audio synchronization. | Preserve editable originals and timing provenance. P7b enables localized exports; P7c requires relevant audio composition support and explicit consent/provider feasibility. |
| **P8** | **P8a:** silence/filler/retake detection and suggested cuts. **P8b:** highlights, hooks, reframing and repurposing. **P8c:** B-roll search/insertion/generation and advanced face/background/enhancement effects. **P8d:** natural-language orchestration of supported edit operations. | Build on P6's reversible edits; preview proposed changes. Evaluate accuracy, device/provider constraints and media rights per capability. P8d must operate on implemented, validated editing primitives. |
| **P12** | **Early essentials:** P1 owns basic library/autosave; P5 owns individual-user purchases/restoration and entitlement validation. **P12a:** advanced local organization, history and project portability. **P12b:** optional backup/sync and offline conflict handling. **P12c:** teams, roles, comments, review and approval. **P12d:** AI credits, allowances and team billing. | Local projects remain usable without accounts or cloud. Establish version/conflict and media transfer contracts before team workflows; connect credit accounting to actual provider usage and failure/retry semantics. |

P10 and P11 should likewise separate reusable templates/batch processing from advanced tracking/publishing integrations when defining their implementation units.

### Acceptance gates for each approved phase

- Document exact affected targets/packages and whether any existing Mac behavior changes.
- Define model/persistence migrations, rollback/recovery and tests before modifying persisted data.
- Prove new features through focused unit/integration/render fixtures, including failure/cancel/retry paths.
- Show user-visible behavior and obtain explicit approval before UI alterations or manual UI tests.
- Keep local tests/builds scoped to target and change. Do not set up or trigger CI, perform device validation, or download models without authorization.
- No implicit paid cloud use or uploading of media; respect licensing and consent for stock media, voice cloning and publishing.
- Close/check off a feature only when implemented and integrated with applicable local correctness checks, not when a placeholder exists. Record device validation as pending user testing; it is not an agent phase-completion or merge gate.

