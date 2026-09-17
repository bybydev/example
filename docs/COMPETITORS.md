# Inkribe — Competitor Research

Research date: **2026-09-17**.

## Market shape

Current Mac speech-to-text products broadly fall into two product shapes:

1. **Transcription workspace** — record/import media, produce a persistent transcript, review/edit it, summarize it, and export it.
2. **System-wide dictation utility** — hold a hotkey, speak, and insert cleaned text directly into the currently focused app.

Inkribe v1 should deliberately optimize for the first shape. Global dictation is a valid later expansion, but mixing both identities into v1 would make the shell, onboarding, feature hierarchy, and marketing less clear.

## Competitor summary

| Product | Primary shape | Local/offline story | Relevant capabilities | Important lesson for Inkribe |
| --- | --- | --- | --- | --- |
| MacWhisper / Whisper Transcription | Transcription workspace | Local transcription by default; optional cloud/AI paths also exist | file/folder transcription, many models, subtitles, speaker features, CLI, summaries/AI prompting | Breadth is powerful, but Inkribe can be simpler and more opinionated: bundled models, no setup, local AI built directly into transcript workflow |
| Aiko | Minimal local transcriber | Whisper runs on device; privacy-first | recording/file transcription, subtitles, word replacement; accuracy-first | Demonstrates demand for a focused offline utility and willingness to ship a multi-GB app; editor/workflow depth is an opening |
| TalkFold | Meeting/transcript workspace | On-device transcription; meeting-oriented | recording, meeting transcription, summaries, custom dictionary/shortcuts | Inkribe should avoid becoming meeting-specific in v1; keep the document model general for interviews, lectures, voice notes, and files |
| Superwhisper | System-wide dictation | Local models available; also supports cloud/model choices | hotkey dictation, context-aware formatting, file transcription, modes, vocabulary, iOS | Do not copy its product identity in v1. Its strength is frictionless global typing; Inkribe's strength should be persistent transcript documents and offline post-processing |
| Sonivo | System-wide dictation | Strong local/privacy positioning, Apple Silicon focused | push-to-talk, system-wide insertion, multiple models, vocabulary, AI polish, history | Shows appetite for one-time-purchase private Mac voice tools; also shows why Inkribe should keep workspace transcription distinct from hotkey dictation |

## Detailed notes

### MacWhisper / Whisper Transcription

Current MacWhisper documentation shows a mature transcription platform with local transcription, multiple model families, file/folder processing, many export formats, speaker-oriented options, command-line support, and optional AI/cloud features.

The product is broad. Local transcription can stay on-device, while optional cloud transcription and external AI providers can transmit audio or transcript data when selected.

What to learn:

- transcript persistence and rich export matter
- users value model choice and serious file workflows
- batch/folder processing becomes important for advanced users
- subtitle formats are table stakes for a dedicated transcription app

What not to copy for v1:

- large model/provider configuration surface
- cloud-provider complexity
- chat-with-transcript as the primary AI metaphor
- CLI and advanced automation before the core Mac workspace is excellent

### Aiko

Aiko is a paid Apple-platform app centered on high-quality on-device Whisper transcription. Its App Store listing emphasizes that nothing leaves the device, supports subtitle export, and explicitly favors accuracy over real-time transcription. The current Mac listing is about **2.8 GB**, which is useful evidence that a premium local-model Mac app does not need to optimize itself around tiny download size.

Aiko currently targets Apple Silicon strongly and warns that Intel performance/support is poor.

What to learn:

- users understand and accept large local-model apps when privacy/quality is the reason
- record-then-transcribe is a credible workflow; v1 does not need live streaming transcription
- a simple privacy story is valuable marketing

Inkribe opportunity:

- stronger persistent library/editor workflow
- integrated local cleanup/summarization rather than transcription only
- documented Intel fallback/support
- custom premium Mac shell and richer post-transcription workflow

### TalkFold

TalkFold positions itself as an offline transcription and meeting-notes app for Mac. Its public material emphasizes on-device transcription, recording, summaries, custom dictionary features, and meeting capture.

What to learn:

- users naturally expect transcript + summary + notes to coexist
- derived outputs should be document modes/tabs rather than destructive replacements
- meeting capture is a large adjacent market

Inkribe decision:

Do **not** make “meeting recorder” the v1 identity. Record/import should create a generic Transcript document that works equally well for meetings, lectures, interviews, podcasts, voice notes, or arbitrary files.

### Superwhisper

Superwhisper's current product is primarily a system-wide voice-to-text utility. It can insert text into any Mac app, applies formatting/cleanup, offers local and cloud/model options, supports file transcription, and has iOS support. Its September 2026 changelog shows active work on local Whisper models, file transcription, vocabulary, modes, and platform compatibility.

What to learn:

- local speech recognition + a second language-model cleanup stage is a proven architecture
- cleanup should feel like a direct workflow tool, not a generic chatbot
- vocabulary/context controls may become valuable later

Inkribe decision:

Global dictation is deferred. Inkribe should not put hotkey configuration, floating dictation overlays, insertion modes, or app-context rules into v1.

### Sonivo

Sonivo markets a one-time-purchase Mac dictation app with strong local/privacy positioning, push-to-talk, system-wide text insertion, multiple transcription models, vocabulary, AI polish, and recording history. Its public page currently lists a **$35 one-time** purchase and requires Apple Silicon.

What to learn:

- privacy + no account + one-time purchase is an understandable Mac proposition
- history is important even for dictation-style apps
- custom vocabulary is a plausible later feature

Inkribe distinction:

Inkribe is not “speak anywhere and paste.” It is “turn audio into a durable transcript document, improve it locally, and export it.”

## Product positioning

Recommended v1 category statement:

> A private, offline transcription workspace for Mac.

Supporting product promise:

> Record or import audio and video, transcribe it locally, clean or summarize it with on-device AI, edit the result, and export it — without an account or cloud processing.

## Differentiation to protect

Inkribe should remain opinionated about these points:

- **Fully offline core workflow.** No cloud fallback hidden behind “best quality”.
- **Bundled models.** Install the app and it is ready; no model marketplace/setup step.
- **Transcript is the central object.** Record and Import are creation methods, not separate product identities.
- **Local AI is a tool, not a chatbot.** Clean, Polish, Summary, Notes, Action Items.
- **Preview destructive transformations.** The user sees original vs cleaned text before replacement.
- **Premium native Mac UI.** Custom shell, strong keyboard behavior, consistent themes.
- **Apple Silicon optimized + Intel supported.** Do not silently abandon Intel in v1.
- **Simple commerce.** Monthly, yearly, or lifetime Pro; no usage credits/API keys.
- **Future iOS-ready architecture.** Shared packages exist from day one even though v1 is Mac-first.

## Features to consider after v1

Competitor research supports these as credible expansions, in roughly this product-family order:

- custom vocabulary / word replacement
- speaker diarization and naming
- word-level timestamps
- system audio / meeting capture
- translation
- watch folders / batch folder transcription
- global dictation hotkey and paste-to-focused-app workflow
- Shortcuts / CLI automation

Do not add these until the v1 Transcript workspace is polished enough to stand on its own.

## Sources

Primary/current sources consulted:

- MacWhisper support: https://docs.macwhisper.com/
- MacWhisper privacy: https://docs.macwhisper.com/article/52-keeping-transcriptions-private
- MacWhisper CLI/export capabilities: https://docs.macwhisper.com/article/57-macwhisper-command-line-tool
- Aiko App Store: https://apps.apple.com/us/app/aiko/id1672085276?platform=mac
- Superwhisper Mac: https://superwhisper.com/voice-to-text-mac
- Superwhisper models: https://superwhisper.com/models
- Superwhisper changelog: https://ai.superwhisper.com/changelog
- Sonivo: https://sonivo.app/
- TalkFold: https://talkfold.app/

Competitor capabilities and pricing change. Re-check the sources before final launch positioning or marketing comparisons.
