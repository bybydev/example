# Inkribe Settings, Performance, and Compatibility Contract

Phase 8 finalizes the user-facing Settings surface and the runtime/resource policies that sit behind it.

The guiding rule is that Settings should expose durable product choices, not low-level inference knobs. Inkribe chooses safe runtime defaults for the current Mac and keeps model/resource ownership inside the existing transcription and AI layers.

## Settings ownership

The macOS Settings scene remains `MacAppFoundation`'s `MacAppSettingsView`.

Inkribe contributes these product panes:

- **General** — privacy and reset of workflow defaults
- **Transcription** — default language and microphone
- **AI Cleanup** — local AI model selection and retention behavior
- **Storage** — local data usage and source-media cleanup
- **Diagnostics** — architecture, runtime policy, model presence, and queue health
- **About** — product and build information

The built-in MacAppFoundation **Appearance** and **Plan** panes remain part of the same Settings scene.

## Persisted workflow preferences

`InkribePreferences` is the single app-level preference owner. It uses `UserDefaults` for small durable choices only.

Current persisted values:

- default transcription language
- default microphone device ID, or `nil` for the current macOS system default
- selected local AI model, defaulting to Qwen3 0.6B
- whether the local AI model should remain loaded between actions

The shared `TranscriptionLanguageCatalog` owns supported language codes and normalization. Record, Import, and Settings consume the same catalog so `Auto` and explicit language codes cannot drift between screens.

### Transcription language

The default is **Automatic**.

Record and Import start with the persisted default, but the user can override the language for the current job without changing the global default.

Unsupported or stale stored language values normalize back to Automatic.

### Microphone

`nil` means **System Default**. In that mode the recorder follows the input currently selected by macOS.

A specifically selected microphone is stored by Core Audio device ID. If the saved device is temporarily unavailable, Settings preserves the saved ID and shows it as unavailable while recording falls back to the system input. If the device returns, the saved selection can be used again.

## Runtime policy

Low-level GPU/thread/context controls are intentionally not exposed as user settings.

The native runtime packages remain authoritative:

- `WhisperRuntimeConfiguration.recommended`
- `LLMRuntimeConfiguration.recommended`

Current policy:

- Apple Silicon uses the native Metal path where configured by the runtime.
- Intel uses the CPU path.
- Worker counts are bounded from the current processor count.
- LLM context size remains owned by `LLMRuntime`, while long-input fallback remains owned by `InkribeAI`.

Diagnostics reports the effective recommended backend/thread/context policy; it does not mutate it.

## Model memory lifecycle

Model lifetime is owned by the subsystem doing the work. No Settings pane directly manipulates native pointers or contexts.

### Whisper

`DefaultTranscriptionJobExecutor` conforms to `TranscriptionRuntimeManaging` and can release its Whisper model through the runtime's existing unload path.

`TranscriptionQueueController` keeps the model warm while a JobQueue batch is active. When JobQueue emits `queueDrained`, the controller releases idle transcription runtime resources.

This keeps multi-file throughput efficient while avoiding an indefinitely resident Whisper model after the queue is finished.

### Qwen / local AI

The AI pane lets the user choose between bundled Qwen3 0.6B and Qwen3 1.7B. Qwen3 0.6B is the default. Changing the selected model unloads any idle retained AI service so the next action uses the new model; the picker is disabled during active generation.

The default preference is **do not keep the AI model loaded between actions**.

After a successful, cancelled, or failed local-AI action, `TranscriptLocalAIController` unloads Qwen and drops the retained service when that preference is off.

When **Keep local AI model loaded between actions** is enabled, the service/model remains available for faster repeated Clean, Polish, Summary, Notes, and Action Items operations at the cost of higher idle memory use.

### Speaker diarization

The Pyannote segmentation and 3D-Speaker embedding models are owned by `DiarizationRuntime`. They stay warm while the transcription queue is processing a batch, including multi-file Pro imports, and are released together with Whisper when the queue drains. Speaker-count clustering remains automatic in the current UI.

Turning retention off requests an unload only when generation is idle. If generation is currently active, its completion path observes the new preference and releases the model afterward. A Settings change therefore never tears a runtime out from under active generation.

If STT and local AI are both actively doing useful work at the same time, both runtimes may legitimately be resident. Resource cleanup targets idle residency, not active work.

## Storage accounting

The Storage pane reports app-owned mutable data under `Application Support/Inkribe`:

- source media under `Media/`
- transcript store
- queue store
- transcript count
- combined mutable app-data size

Bundled model weights live in the application resources and are reported in Diagnostics rather than counted as mutable app data.

Directory-size calculation runs off the main actor so traversing media files does not block Settings interaction.

## Source-media cleanup

**Remove Finished Source Media** is intentionally narrower than transcript deletion.

For each transcript with app-owned source media:

- media is removable when there are no related queue records, or every related record is Complete;
- pending, transcribing, pausing, cancelling, failed, cancelled, and Needs Attention records keep their media so recovery/retry data is not destroyed;
- transcript text, raw text, edited text, timestamps, revisions, and saved AI results remain intact;
- `sourceMediaRelativePath` is cleared before cleanup completes, so later playback does not point at deleted bytes;
- if file deletion fails, the previous transcript media reference is restored best-effort;
- an already-missing file is treated as stale metadata and its transcript media reference is cleaned up safely.

After cleanup, that transcript remains usable for reading/search/export but no longer has source playback.

## Diagnostics

The Diagnostics pane is local and content-minimal. It reports:

- current CPU architecture
- processor count and physical memory
- default Metal device presence/name
- effective Whisper backend/thread policy
- effective LLM backend/thread/context policy
- bundled Whisper, diarization, and all selectable Qwen model identities, runtime version/build, pinned model revisions, expected sizes, licenses, and lightweight presence status
- JobQueue pause/activity/record counts
- queue persistence issue and app startup issue when present

Model presence is only a lightweight path check. Native runtimes still perform the authoritative pinned size/SHA-256 integrity check before first model load.

Diagnostics must never include transcript text, raw audio, prompt text, generated AI content, or exported content.

## Compatibility boundary

Shared packages continue to target macOS 15+ and iOS 26+. Mac-specific settings, Core Audio device selection, AppKit storage reveal, and Metal presentation stay in `InkribeMac`.

The runtime configuration remains architecture-aware inside `WhisperRuntime` and `LLMRuntime`; feature UI does not branch on Apple Silicon vs Intel.

## Phase 9 boundary

Phase 9 may harden edge cases and broaden coverage, but it should preserve these ownership rules:

1. one persisted preferences owner;
2. no user-facing native thread/GPU/model-management panel;
3. JobQueue remains the sole transcription scheduler;
4. Whisper resource lifetime remains queue-owned;
5. Qwen resource lifetime remains AI-controller-owned;
6. storage cleanup never destroys content needed by unfinished/retryable queue work;
7. diagnostics remain local and content-minimal.
