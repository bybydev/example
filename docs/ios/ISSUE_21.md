# Issue #21 — source snapshot

Source: https://github.com/hoangbkit/Inkribe/issues/21

Captured: 2026-10-22. Issue last updated: 2026-10-22T03:07:45Z.

The complete issue body below is preserved verbatim. This is an archival snapshot, not the live execution guide. Read [PLAN.md](PLAN.md), [WORKFLOW.md](WORKFLOW.md) and [BASELINE.md](BASELINE.md) for current instructions. In particular: this planning PR stays open until the user explicitly approves its merge; no CI setup/runs or device validation; root AGENTS.md forbids builds/tests unless asked. Historical references to master and old validation requirements do not override those instructions.

---

## Goal and scope

Build **Inkribe for iOS** as a complete, creator-grade video captioning and editing application in the **existing `hoangbkit/Inkribe` repository**. Keep **Inkribe for Mac** as the existing macOS transcription product. Both apps use the **Inkribe** product name; do **not** use the previous experimental app name in code, product copy, targets, or identifiers.

**This is the full product roadmap, not an MVP or a v1 cut-down.** All catalogued capabilities below remain in scope for planning, even those that require cloud providers, licensing, iPad layouts, account systems, or future macOS integration. Technical feasibility/rights/API constraints must be recorded rather than silently dropping capabilities.

**Planning only:** This issue authorizes no implementation, PRs, target rename, project regeneration, builds, UI tests, model downloads, CI modifications, or deployment. Implement individual phases only following explicit approval.

## Implementation focus and validation ownership

User instruction: **focus on implementation; do not set up or trigger CI; skip device validation because the user will test after completion.**

- Do not create, configure, enable, dispatch, rerun or otherwise trigger CI workflows. Do not undertake CI setup or repair, or require a CI run to finish a phase.
- Do not perform physical-device validation or device benchmarks, including memory, thermal, battery, inference-speed or export-performance measurements. The user will test the finished implementation.
- Device behavior and performance remain design considerations. Implement bounded memory use, cancellation, recovery and appropriate platform handling, but record device-dependent assumptions as awaiting user testing rather than claiming measured results.
- Use focused local compilation, static review or relevant non-device correctness checks where available and appropriate. Do not expand this into CI work or a device-validation project. Existing explicit approval requirements for UI tests still apply.
- A phase can be implementation-complete and squash merged under the agreed workflow while device validation remains pending with the user. Report what was implemented, what checks actually ran, and what remains for user testing. Do not claim device validation or full release readiness.
- This instruction supersedes device-benchmark, manual-device acceptance and CI-configuration requirements elsewhere in this roadmap. The feature inventory remains intact; this changes execution and validation ownership, not feature scope.

## Existing repository baseline (inspected on master, 2026-10-22)

- Current folder: `InkribeMac/`; its **XcodeGen application target is currently named `Inkribe`**, despite being macOS-only. Planned names: existing target → **`InkribeMac`**, new iOS application target → **`Inkribe`**. Preserve the Mac app's existing bundle ID, data locations, purchase IDs, behavior, and upgrade compatibility.
- Existing shared local packages: `InkribeCore`, `InkribeAudio`, `InkribeTranscription`, `InkribeAI`, `InkribePersistence`, `InkribeExport`, `InkribeModelAssets`, `WhisperRuntime`, `LLMRuntime`. They declare macOS 15+ / iOS 26+ where applicable; platform support in a manifest does **not** establish a tested iOS runtime.
- Current Mac document is a `Transcript` with timestamped **segments**, edited/raw text, and source-media path. Caption animation requires **word-level timing** and a separate **video-project/timeline** model. Do not expand Mac `Transcript` into an all-purpose editing schema merely for sharing.
- Existing audio decoder builds an entire mono 16 kHz `[Float]` in memory. Add a bounded-memory streaming/chunking solution appropriate to long iPhone videos; do not regress Mac ingestion.
- Existing transcript exports are TXT/Markdown/SRT/VTT. Animated burned-in video rendering, previews, transparent overlays, and frame/audio synchronization need a new subsystem.
- Keep `JobQueue` as the durable background processing-state owner where suitable, without duplicating state machines. iOS execution limitations must be respected.

## Non-negotiable architecture

1. **One repository, two independent app targets:** `InkribeMac` (macOS) and `Inkribe` (iOS); separate schemes, independent entitlements, StoreKit configs, app assets, privacy metadata, builds, test destinations, archives and release flows.
2. **Mac preservation:** A target rename is an internal project change, not a Mac app rebrand or bundle-ID migration. Verify installed-user app/data/StoreKit compatibility before merging. Mac behavior changes only with separately approved work.
3. **Shared where useful, not shared by force:** reuse portable audio decoding, model/runtime infrastructure, transcription contracts and subtitle formatting; keep separate app/project/editor/commerce code. New shared package boundaries require a real second consumer.
4. **New caption-centric domain:** media assets + non-destructive edit graph/timeline + tracks + captions + word IDs/times + speaker/language + keyframed style/animation + render/export profiles. Use stable identities, versions, source-relative timing, and migration policy.
5. **Separation of raw and edited:** immutable source transcription/media, editable timed captions, translations and derived changes with provenance. Explicit realignment/retranscription; never silently overwrite hand-edited timings or text.
6. **Preview/export consistency:** timebase/frame precision, compositing/font/easing parity, deterministic animation layout, A/V sync; design for bounded memory, thermal pressure and export reliability; device benchmarks and physical-device validation are deferred to the user's testing.
7. **Local-first default:** preserve offline workflows; cloud speech/AI, libraries, publishing and sync only by explicit consent and with documented data flow, cost, rights and graceful offline behavior.
8. **iOS-first UI:** use AppFoundation (not MacAppFoundation) in the new app target; SwiftUI for app/editor surfaces as appropriate; investigate AVFoundation/Core Image/Core Animation/Metal and related rendering strategies without pre-deciding implementation.
9. **Implementation focus:** do not set up or trigger CI, perform device validation, or add deployment work; when implementation begins, follow the per-phase PR workflow below: one new PR per authorized phase, branched from and targeting the latest `develop`; keep all units and passes of that phase in the same PR, then squash merge it when the phase is finished.

## UI design direction and implementation decisions — 2026-10-22

**Visual reference:** user-supplied 12-screen “Inkribe for iOS — Key Screens & User Flow” concept, file `EFF3F314-2413-4A2E-8BFC-846F644A9A78.jpeg`, reviewed in the planning conversation. Retain its dark surfaces, purple/blue accents, prominent video previews, project thumbnails and bold caption styling as the visual direction. The concept illustrates selected workflows; it does not replace the complete feature inventory or specify every interaction. Dark/light appearance remains in scope.

A complete redesign of the reference image is not required before building. The following decisions take precedence over conflicting details in that image; refine and approve individual screen layouts as their implementation phase approaches.

| Area | Design decision | Phase / acceptance guidance |
|---|---|---|
| Launch and projects | Open the Projects library on normal launch. Use the welcome/create screen for onboarding or the empty-library state, with clear create/import actions. | **P1:** existing projects must be reachable without an extra welcome-screen step. |
| Caption correction | Keep a compact video preview visible above the caption list while correcting text and adjusting timing. Synchronize preview, playback position and selected caption/word; adapt the layout when the keyboard opens. | **P3:** settle the preview/list/keyboard interaction before implementing the editor UI. Users must retain video context while checking a correction. |
| Editor navigation | Use one consistent tool hierarchy. Avoid competing or duplicate routes such as separate “Edit / Captions / Style” and “Captions / Style / Animation / Templates” bars with unclear ownership. Caption styling, animation and templates should have clearly related controls; video and audio tools remain discoverable. | **P3** establishes navigation, extended by **P4/P6/P10**. Approve the exact labels, grouping and panel transitions with the editor layout before UI implementation. |
| Small iPhone layouts | Adapt preview, timeline and property panels to smaller supported iPhones. Provide comfortable touch targets and readable labels, reveal additional tracks/advanced controls contextually, and offer precise value entry where sliders alone are insufficient. | **P3 onward; P13 continuous:** review compact-height, keyboard-open and text-size layouts; avoid squeezing every control and track onto one screen. This does not remove advanced editing features. |
| Export captions | Replace ambiguous overlapping “Include Captions” / “Burn In Captions” toggles with a clear video caption mode: no captions, burned-in captions, or an embedded subtitle track where the selected container/format supports it. Provide separate subtitle-file export options such as SRT/VTT. Explain compatibility and any styling limitations. | **P5:** controls must map unambiguously to the actual exported video and separate files. Preserve overlay and other export capabilities in the inventory through their relevant options. |
| Sharing | Use the native iOS share sheet for exported files, alongside explicit Save to Photos / Save to Files actions where appropriate. Do not imply direct social publishing through decorative app buttons. | **P5:** native file delivery. **P11:** add direct publishing only through verified official integrations; those integrations remain in the full roadmap. |

**Design readiness by phase:**

- **P0:** target isolation, domain/renderer planning and feasibility work can begin after explicit implementation approval without redrawing all 12 screens. Any prototype UI remains subject to the existing UI approval gate.
- **P1:** refine the Projects, empty-library and import layouts before their UI implementation.
- **P3:** settle the editor tool hierarchy, persistent caption preview, timeline/list relationship, selection behavior, keyboard handling and small-screen layout before editor UI implementation.
- **P4–P11:** refine each affected tool panel and workflow before implementing its UI; preserve the established navigation and rendering contracts.
- This design update is planning only. It authorizes no code changes, builds, tests or implementation and does not waive existing approval gates.

## Per-phase PR workflow

User instruction: **one new PR per phase, target the latest `develop`, then squash merge when finished.**

1. Begin a phase only when requested. Refresh the remote branch state and create its new branch from the latest `develop`.
2. Open one PR targeting `develop` for that phase. Keep every implementation unit, pass, fix and follow-up needed to finish that phase in the same PR; do not create stacked PRs or a separate PR per pass.
3. Complete the phase's agreed implementation deliverables and applicable local correctness checks. Do not set up/trigger CI or perform device validation; the user will test after completion. Keep the branch current with `develop` and resolve conflicts before merging.
4. Squash merge the completed phase PR into `develop`. This instruction authorizes the squash merge on completion without an additional merge-confirmation request.
5. Start any subsequently requested phase in a new branch and new PR from the latest `develop`, including the preceding merged work. Do not begin another phase without its implementation request.

This workflow supersedes earlier references to targeting `master` or creating separate PRs per implementation unit. References to the repository baseline inspected on `master` describe historical assessment evidence only. Existing UI approval requirements and the implementation-focus/validation-ownership instructions above continue to apply.

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

## Complete feature inventory

All items below are scope requirements, not promises that they currently work. A phase tag denotes the main workstream; dependent subsystems may be introduced earlier. Do not collapse or silently omit items because they seem non-MVP.

### 1. Video import and project creation (P1)

- [ ] Video import — MP4, MOV and supported media formats
- [ ] Photo library — pick videos from Photos
- [ ] Files import — Files, iCloud Drive, document providers
- [ ] Audio import — MP3, WAV, M4A and compatible types
- [ ] Direct recording — create video inside app
- [ ] Multi-video import — combine clips in one project
- [ ] Batch import — multiple files as separate projects
- [ ] Share extension — receive media from compatible apps
- [ ] Cloud import — supported storage integrations
- [ ] URL import — supported direct media URLs, with rights validation
- [ ] Project formats — portrait, square, landscape, custom
- [ ] Project presets — TikTok, Reels, Shorts, Stories and more
- [ ] Automatic metadata — duration, resolution, fps, orientation, tracks
- [ ] Original preservation — non-destructive source media

### 2. AI transcription engine (P2)

- [ ] Automatic transcription — generate captions from video
- [ ] Multilingual recognition — broad supported language catalog
- [ ] Language auto-detection
- [ ] Mixed-language recognition — code-switching
- [ ] Word-level timestamps — word start and end
- [ ] Speaker diarization — distinguish speakers
- [ ] Speaker labeling — custom names/styles
- [ ] Automatic punctuation
- [ ] Capitalization
- [ ] Grammar correction — preserve intended meaning
- [ ] Custom vocabulary — proper nouns and domain terminology
- [ ] Profanity handling — preserve, censor, substitute
- [ ] Confidence detection — flag uncertain text
- [ ] Selective re-transcription — selected ranges only
- [ ] Audio enhancement for recognition — preprocess noisy speech
- [ ] Offline transcription — on-device supported models
- [ ] Cloud transcription — optional opt-in providers
- [ ] Forced alignment — sync edited text to source audio
- [ ] Silence detection
- [ ] Non-speech detection — sound events
- [ ] Transcript import — import existing text or structured transcripts

### 3. Caption editing and synchronization (P3)

- [ ] Full transcript editor
- [ ] Inline preview editing
- [ ] Word-level editing
- [ ] Timeline editor
- [ ] Waveform editor
- [ ] Split captions
- [ ] Merge captions
- [ ] Move captions on timeline
- [ ] Trim caption intervals
- [ ] Word timing adjustment
- [ ] Automatic segmentation — pauses, semantics, phrases
- [ ] Line breaking
- [ ] Maximum words per caption
- [ ] Maximum lines per caption
- [ ] Reading-speed constraints and warnings
- [ ] Minimum display duration
- [ ] Global sync offset
- [ ] Find and replace
- [ ] Bulk formatting
- [ ] Multi-track captions — languages/variants
- [ ] Manual caption insertion
- [ ] Caption deletion without deleting media
- [ ] Undo and redo
- [ ] Re-alignment after transcript changes

### 4. Typography and visual styling (P4)

- [ ] Font library
- [ ] Custom font import
- [ ] Font weight
- [ ] Font size
- [ ] Letter spacing
- [ ] Line spacing
- [ ] Capitalization modes
- [ ] Text alignment
- [ ] Custom text colors/palettes
- [ ] Gradient text
- [ ] Text outline
- [ ] Text shadows
- [ ] Glow effects
- [ ] Background boxes/pills/strips
- [ ] Background blur
- [ ] Transparent caption backgrounds
- [ ] Highlight colors
- [ ] Per-word styles
- [ ] Caption positioning
- [ ] Social safe-area guides
- [ ] Caption rotation
- [ ] Caption scaling
- [ ] Per-speaker colors
- [ ] Saved styles
- [ ] Global versus local styling

### 5. Animated captions (P4)

- [ ] Word-by-word reveal
- [ ] Karaoke highlighting
- [ ] Pop animation
- [ ] Bounce animation
- [ ] Typewriter animation
- [ ] Fade in/out
- [ ] Slide animation
- [ ] Zoom animation
- [ ] Blur reveal
- [ ] Glitch effect
- [ ] Shake effect
- [ ] Rotation animation
- [ ] Elastic/spring animation
- [ ] Wipe reveal
- [ ] Color transitions
- [ ] Highlight sweep
- [ ] Scale emphasis
- [ ] Sequential word entrances
- [ ] Per-word animation
- [ ] Independent entrance/exit
- [ ] Animation duration
- [ ] Animation delay
- [ ] Easing curves — including custom
- [ ] Animation intensity
- [ ] Combined animation properties
- [ ] Custom keyframes
- [ ] Looping effects
- [ ] Animation preset saving

### 6. Smart AI caption styling (P7)

- [ ] Auto-style whole video
- [ ] Content-aware styling
- [ ] Keyword highlighting
- [ ] Emotion-based emphasis
- [ ] Automatic emoji suggestions
- [ ] Animated emojis
- [ ] Emoji customization
- [ ] Smart line breaks
- [ ] Adaptive caption positioning
- [ ] Face-aware captions
- [ ] Speaker-aware placement
- [ ] AI style suggestions
- [ ] Natural-language style instructions
- [ ] Reference-style matching
- [ ] Auto-highlight review
- [ ] AI caption cleanup — verbatim option preserved
- [ ] Verbatim versus readability-optimized modes

### 7. Translation and multilingual subtitles (P7)

- [ ] Subtitle translation
- [ ] Bilingual captions
- [ ] Multiple language tracks
- [ ] AI localization
- [ ] Timing preservation
- [ ] Translation re-alignment
- [ ] Independent language styling
- [ ] Custom translation terminology
- [ ] Translation review
- [ ] Multi-language batch export
- [ ] Right-to-left layout
- [ ] CJK typography
- [ ] Code-switching
- [ ] AI dubbing
- [ ] Consent-based voice-preserving dubbing
- [ ] Dubbing synchronization
- [ ] Original audio mixing

### 8. Video editing (P6)

- [ ] Trim
- [ ] Split
- [ ] Merge
- [ ] Rearrange clips
- [ ] Delete segments
- [ ] Multi-track timeline
- [ ] Text-based video editing
- [ ] Video speed adjustment
- [ ] Speed ramping
- [ ] Crop
- [ ] Rotate and flip
- [ ] Aspect ratio conversion
- [ ] Smart reframing
- [ ] Auto-center subject
- [ ] Picture-in-picture
- [ ] Zoom and pan
- [ ] Video keyframes
- [ ] Video transitions
- [ ] Freeze frame
- [ ] Reverse playback
- [ ] Color adjustments
- [ ] Color filters
- [ ] LUT support
- [ ] Background blur
- [ ] Background replacement
- [ ] Face blur
- [ ] Mosaic and pixelation
- [ ] Video stabilization
- [ ] Clip duplication
- [ ] Snapshot extraction

### 9. AI video enhancement and automatic editing (P8)

- [ ] Remove silence
- [ ] Remove filler words
- [ ] Remove retakes
- [ ] Smart jump cuts
- [ ] Smart pacing
- [ ] Automatic zooms
- [ ] AI scene detection
- [ ] Smart B-roll suggestions
- [ ] Automatic B-roll insertion
- [ ] Licensed stock media search
- [ ] AI-generated B-roll
- [ ] AI highlight detection
- [ ] Long-to-short conversion
- [ ] Hook extraction
- [ ] Hook generation
- [ ] Automatic reframing
- [ ] AI eye-contact correction where supported
- [ ] AI background removal
- [ ] Automatic image/audio enhancement
- [ ] Natural-language AI video editor
- [ ] Preview proposed AI edits
- [ ] Non-destructive AI changes

### 10. Camera and teleprompter (P9)

- [ ] Built-in camera
- [ ] Front/rear cameras
- [ ] Recording resolution and frame-rate presets
- [ ] Teleprompter
- [ ] Adjustable scroll speed
- [ ] Voice-following teleprompter
- [ ] Teleprompter positioning
- [ ] Script editor
- [ ] AI script generation
- [ ] Script rewriting
- [ ] Recording countdown
- [ ] Recording timer
- [ ] Microphone selection
- [ ] Audio monitoring
- [ ] Multiple takes
- [ ] Auto-caption after recording
- [ ] Camera composition/social guides
- [ ] Compatible Bluetooth remotes

### 11. Audio editing and enhancement (P6)

- [ ] Voice enhancement
- [ ] Background noise reduction
- [ ] Echo reduction
- [ ] Automatic volume leveling
- [ ] Loudness normalization
- [ ] Licensed music library
- [ ] Music import
- [ ] Audio trimming
- [ ] Audio fades
- [ ] Volume envelopes
- [ ] Music ducking
- [ ] Voice isolation
- [ ] Audio extraction
- [ ] Audio replacement
- [ ] Voiceovers
- [ ] AI voiceovers
- [ ] Sound effects
- [ ] Speech review playback speed
- [ ] Multi-track mixing
- [ ] Waveform display
- [ ] Audio-only export

### 12. Text overlays, stickers and motion graphics (P10)

- [ ] Text overlays separate from captions
- [ ] Animated titles
- [ ] Hook text
- [ ] Lower thirds
- [ ] Call-to-action overlays
- [ ] Video progress bars
- [ ] Speech bubbles
- [ ] Emoji overlays
- [ ] Sticker library
- [ ] Custom stickers
- [ ] Shapes
- [ ] Background cards
- [ ] Animated gradients
- [ ] Motion tracking
- [ ] Face tracking
- [ ] Object tracking
- [ ] Masking
- [ ] Layer ordering
- [ ] Blend modes
- [ ] Opacity keyframes
- [ ] Graphic animations

### 13. Templates and brand kits (P10)

- [ ] Template gallery
- [ ] Trending styles
- [ ] Minimal styles
- [ ] Bold creator styles
- [ ] Karaoke styles
- [ ] Podcast styles
- [ ] Educational styles
- [ ] Gaming styles
- [ ] Cinematic styles
- [ ] Meme styles
- [ ] Template customization
- [ ] Custom templates
- [ ] Template duplication
- [ ] Template sharing
- [ ] Template import/export
- [ ] Brand kits
- [ ] Multiple brands
- [ ] Brand watermarks
- [ ] Global brand application
- [ ] Style randomizer
- [ ] Template preview using actual footage
- [ ] Favorite templates
- [ ] Recent templates
- [ ] Template collections

### 14. Specialized caption modes (P5)

- [ ] Dynamic captions
- [ ] Traditional subtitles
- [ ] Bilingual mode
- [ ] Karaoke mode
- [ ] Lyrics mode
- [ ] Podcast mode
- [ ] Audiogram mode
- [ ] Quote video mode
- [ ] Educational mode
- [ ] Reaction mode
- [ ] Storytelling mode
- [ ] Silent-first mode
- [ ] Accessibility mode
- [ ] Product demo mode
- [ ] Presentation mode
- [ ] Interview mode

### 15. Video export and delivery (P5)

- [ ] MP4 export
- [ ] MOV export
- [ ] H.264/HEVC encoding
- [ ] 720p/1080p/4K resolution
- [ ] Frame-rate selection
- [ ] Bitrate control
- [ ] Quality presets
- [ ] Aspect ratio presets
- [ ] Burned-in captions
- [ ] Optional soft-subtitle tracks
- [ ] Transparent caption overlays where supported
- [ ] Green-screen overlays
- [ ] SRT export
- [ ] VTT export
- [ ] ASS/SSA export where supported
- [ ] TXT transcript export
- [ ] JSON structured word/speaker/timing export
- [ ] Bilingual exports
- [ ] Separate localized exports
- [ ] Video without captions
- [ ] Preview before export
- [ ] Estimated file size and requirements
- [ ] Export progress/stages
- [ ] Background export subject to iOS execution limits
- [ ] Export queue
- [ ] Batch formats/resolutions/styles
- [ ] Save to Photos
- [ ] Save to Files
- [ ] Share sheet
- [ ] Export history
- [ ] Watermark policy

### 16. Social media creator tools (P11)

- [ ] Platform export presets
- [ ] Social safe zones
- [ ] Multi-platform versions
- [ ] Thumbnail creator
- [ ] Cover frame selection
- [ ] Thumbnail text
- [ ] AI hook suggestions
- [ ] AI title generation
- [ ] AI description generation
- [ ] Hashtag suggestions
- [ ] Social copy variants
- [ ] Caption style A/B versions
- [ ] CTA suggestions
- [ ] Clip repurposing
- [ ] Series naming
- [ ] Direct publishing via official integrations
- [ ] Scheduled publishing where APIs allow
- [ ] Publishing history
- [ ] Creator analytics integrations
- [ ] Export recommendations/warnings

### 17. Batch processing and automation (P11)

- [ ] Batch transcription
- [ ] Batch styling
- [ ] Batch translation
- [ ] Batch rendering
- [ ] Preset pipelines
- [ ] One-click processing workflows
- [ ] Watch folders on supported desktop platform
- [ ] Auto-naming rules
- [ ] Bulk corrections
- [ ] Queue management — pause/resume/cancel/retry
- [ ] Processing priorities
- [ ] Job notifications
- [ ] Failure recovery
- [ ] Duplicate detection
- [ ] Processing profiles
- [ ] Automation API
- [ ] Apple Shortcuts
- [ ] macOS batch workflow where added later

### 18. Project management and collaboration (P1 essentials; P12 advanced)

- [ ] Project dashboard
- [ ] Project thumbnails
- [ ] Project search by title/transcript
- [ ] Sort and filter
- [ ] Folders
- [ ] Collections
- [ ] Tags
- [ ] Favorites
- [ ] Project duplication
- [ ] Project archiving
- [ ] Auto-save
- [ ] Project history
- [ ] Version restoration
- [ ] Cloud synchronization
- [ ] Offline projects
- [ ] Cloud backup
- [ ] Project import/export
- [ ] Shared projects
- [ ] Team workspaces
- [ ] Roles and permissions
- [ ] Timestamped comments
- [ ] Review links
- [ ] Approval workflow
- [ ] Shared brand kits
- [ ] Collaborative conflict handling
- [ ] Storage management

### 19. Editor experience and productivity (P3)

- [ ] Live video/caption preview
- [ ] Frame stepping
- [ ] Timeline zoom
- [ ] Timeline snapping
- [ ] Multi-selection
- [ ] Contextual editing controls
- [ ] Gesture editing
- [ ] Precision numeric controls
- [ ] Property inspector panels
- [ ] Keyboard shortcuts
- [ ] Copy/paste styles
- [ ] Multi-level undo
- [ ] Before/after preview
- [ ] Safe-zone toggle
- [ ] Playback speed
- [ ] Selection looping
- [ ] Full-screen preview
- [ ] Haptic feedback
- [ ] iPad workspace optimization
- [ ] External display preview
- [ ] Dark/light appearance
- [ ] Keyboard navigation
- [ ] Editor panel customization

### 20. Accessibility and professional subtitles (P13)

- [ ] Closed-caption authoring
- [ ] Sound-effect and non-speech labels
- [ ] Speaker identification
- [ ] Readability checks
- [ ] Contrast checks
- [ ] Subtitle overlap detection
- [ ] Platform safety warnings
- [ ] Flashing animation warnings
- [ ] Low-motion/high-contrast style presets
- [ ] Subtitle validation
- [ ] Independent transcript review
- [ ] Multi-language QA
- [ ] VoiceOver
- [ ] Dynamic Type
- [ ] Reduced Motion
- [ ] Color-blind-safe palettes

### 21. Privacy, reliability and rendering quality (P13)

- [ ] Local-first projects
- [ ] Offline private transcription
- [ ] Explicit optional cloud authorization
- [ ] Scoped media permissions
- [ ] Temporary file cleanup
- [ ] Storage dashboard
- [ ] Safe cache management
- [ ] Non-destructive editing
- [ ] Incremental rendering
- [ ] Export recovery
- [ ] Thermal management
- [ ] Memory-aware processing
- [ ] Precise audio/video sync
- [ ] Deterministic preview-to-render parity
- [ ] Font availability/embedding checks
- [ ] Missing-source relinking
- [ ] Project migrations without data loss
- [ ] Data deletion controls
- [ ] Privacy-conscious diagnostics

### 22. Subscription and account features (P5 individual purchases; P12 advanced billing)

- [ ] Free and paid entitlement access
- [ ] Subscription plans — monthly/yearly
- [ ] Optional lifetime entitlement
- [ ] Export-quality entitlements
- [ ] Premium animation catalog
- [ ] Premium brand kits
- [ ] AI processing allowances
- [ ] Optional AI credit purchases
- [ ] Processing usage dashboard
- [ ] Restore purchases
- [ ] Cross-device entitlements
- [ ] Team billing/seats
- [ ] Watermark entitlement rules
- [ ] Export-time entitlement validation
- [ ] Introductory subscription trials
- [ ] Subscription management
## Critical technical spikes and open implementation decisions

- **STT/word timing:** verify whether native Whisper output provides adequate word boundaries for animated captions; evaluate forced alignment and manual correction UX; account for punctuation, multiple speakers, language switching and edited text.
- **Model size/packaging:** inspect native iOS `whisper.cpp` XCFramework/platform compatibility and implement suitable packaging, bounded processing and background handling. Document storage/download/bundling trade-offs and device-dependent assumptions; latency, memory and thermal measurements are deferred to the user's testing. Do not implicitly ship Mac's Qwen 1.7B into iOS.
- **Decoder and media import:** avoid loading whole decoded recordings in memory, prove handling of variable-frame-rate video, slow motion, multiple tracks, silence and hours-long files.
- **Core model:** use stable word/cue/track IDs, source times, transformed timeline times, frame timebases and edit provenance; make transitions from transcript edits to captions explicit.
- **Rendering (P0 feasibility; P4/P5 production):** prototype Core Animation/AVVideoComposition vs Core Image/Metal where useful; prove deterministic matching of in-editor glyph layout, timing, easing and final encoded output before scaling the preset catalog. Include representative word highlighting, animation, font/emoji layout and A/V synchronization fixtures; anticipate P6 multi-track composition.
- **Multilingual fonts and captions:** bidirectional text, CJK line breaks, unicode/emoji graphemes, RTL, speaker labels, accessibility conventions.
- **External integrations:** capabilities such as direct post/schedule, cloud storage, provider analytics, generated media and stock licensing are contingent on real official API rights; document constraints and fallback workflows.
- **Product limits and pricing:** independent Mac/iOS StoreKit product identifiers and plans; no entitlement or library coupling by accident.
- **macOS-only named capabilities:** watch folders and desktop batch behavior are recorded for broader product scope but do **not** authorize modifying the existing Mac app in this issue without separate approval.

## Definition of complete

- All applicable checklist items implemented and validated or individually marked with a documented, accepted platform/API/legal limitation and substitute UX; no blanket 'out of scope for v1' omissions.
- Inkribe iOS delivers complete caption/video creation: import/record, transcription, synchronized word editing, styled/animated subtitles, non-destructive video/audio composition, AI tools, translation, export, batch, project management and user-facing monetization.
- Preview and export timing/appearance implemented against consistent rendering contracts and covered by appropriate local fixtures across codecs, fonts, languages and frame rates where feasible. Device-class and runtime performance validation remain pending the user's testing.
- macOS `InkribeMac` remains install/upgrade-compatible, with preserved storage and purchases, and can be built/tested/released separately.
- Implementation begins only after authorization for the relevant phase. Keep its units and passes in one PR targeting the latest `develop`, complete the phase and applicable checks, then squash merge. No CI setup/runs or device validation are required or authorized; the user tests after completion. Local-check constraints and UI approval gates still apply.

### Reference (existing code)

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/TRANSCRIPTION_PIPELINE.md`
- `docs/FEATURES.md`
- `Packages/InkribeCore/Sources/InkribeCore/Transcript.swift`
- `Packages/InkribeAudio/Sources/InkribeAudio/AudioMediaDecoder.swift`
- `Packages/InkribeTranscription/Sources/InkribeTranscription/DefaultTranscriptionJobExecutor.swift`
- `Packages/InkribeExport/Sources/InkribeExport/TranscriptExporter.swift`
- `project.yml`

**Status: PLANNING ONLY. Do not begin implementation until explicitly requested.**
