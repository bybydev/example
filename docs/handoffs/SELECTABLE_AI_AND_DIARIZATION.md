# Selectable Local AI + Speaker Diarization Handoff

This PR adds two related local-model capabilities without introducing network dependencies or a second asset pipeline.

## Local AI model selection

- Adds pinned Qwen3 0.6B Q4_K_M alongside the existing Qwen3 1.7B Q4_K_M.
- Qwen3 0.6B is the default.
- Settings persists the selected model and unloads the retained runtime when selection changes.
- Both Qwen models use the existing model manifest, download, verification, diagnostics, fixture, and notice paths.

## Speaker diarization

- Adds sherpa-onnx 1.13.8 through the new `DiarizationRuntime` package.
- Adds pinned Pyannote Segmentation 3.0 and 3D-Speaker ERes2Net ONNX assets to the existing model manifest.
- Enables Whisper token timestamps.
- Aligns Whisper tokens to diarization turns by maximum temporal overlap, with nearest-turn fallback and short-island smoothing.
- Persists speaker-aware transcript segments and durable speaker names without breaking legacy transcript decoding.
- On retranscription, remaps new clustering IDs to previous speaker identities by timeline overlap before carrying user-renamed labels forward; raw clustering IDs are not assumed stable.
- Shows speaker labels in the transcript segment pane and supports speaker renaming.
- SRT/WebVTT include speaker names when available.
- Diarization models stay warm across an active queue batch and unload when the queue drains.

## Ownership

- `WhisperRuntime` owns speech recognition and token timestamps.
- `DiarizationRuntime` owns sherpa-onnx/model lifetime and raw speaker turns.
- `InkribeTranscription` owns token-to-speaker alignment and durable transcript commit.
- `InkribeCore` owns durable speaker metadata.
- `InkribeMac` owns speaker rename presentation.
- `InkribeExport` owns speaker-aware subtitle formatting.

## Coverage

Added or updated tests for:

- multi-model manifest behavior and stable asset paths/licenses;
- Qwen default/selection persistence;
- diarization runtime configuration/model pins;
- token-to-speaker alignment, split boundaries, fallback, and short-island smoothing;
- transcription-job persistence of speaker-aware segments;
- legacy transcript decoding without speaker metadata;
- speaker-aware subtitle export.

No GitHub Actions were added, modified, or manually run.
