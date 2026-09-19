# Inkribe Native Runtime Contract

The native runtime boundary covers transcription, speaker diarization, and local text generation.

The runtime packages remain reusable on macOS 15+ and iOS 26+. They do not depend on AppKit or MacAppFoundation, and all direct C API access stays internal to the runtime packages.

## Native dependency pins

### whisper.cpp

- Upstream: `ggml-org/whisper.cpp`
- Stable version: `1.9.4`
- Source revision: `927cfce34f31707e17f2bff35c349632fb9e2c3a`
- Binary release tag: `b5130`
- Archive SHA-256: `033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a`
- Swift module: `whisper`

### sherpa-onnx

- Upstream: `k2-fsa/sherpa-onnx`
- Stable version: `1.13.8`
- Source revision: `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`
- Swift product: `sherpa-onnx`
- Used only for local speaker segmentation, embedding extraction, and clustering.

### llama.cpp

- Upstream: `ggml-org/llama.cpp`
- Stable version: `0.4.1`
- Source revision: `b29c606e28a01b1bc8c1351026a0fa6e616bf6c4`
- Binary release tag: `b10964`
- Archive SHA-256: `b342a31c3160095d02777cbf1719013d4e6ff7556a1d46ab9eb5df0a93d13c47`
- Swift module: `llama`

The native dependencies use pinned Apple artifacts/packages rather than floating branches. Runtime code does not follow floating branches or download native engines at application runtime.

## Model ownership

Model identity, bundle path, model revision, byte count, and model SHA-256 remain owned by `InkribeModelAssets`.

The native runtimes:

1. resolve the configured model file;
2. check it against the Phase 2 model manifest before first load;
3. load the native model/context;
4. retain that state only while the runtime owner needs it;
5. release native state on explicit unload or when the native-state owner is released.

No runtime silently falls back to another model, cache location, or remote download.

## Concurrency model

`NativeWhisperRuntime`, `NativeSpeakerDiarizationRuntime`, and `NativeLLMRuntime` isolate native mutable state behind actor/package boundaries.

That is intentional because both native engines expose mutable context state that should not be used concurrently from multiple feature tasks. One runtime instance therefore represents one serialized inference lane.

Feature code should share an intentional runtime owner rather than creating competing schedulers around a single native context.

## Hardware policy

Recommended configuration is architecture-aware:

- Apple Silicon: Metal-enabled native inference with conservative CPU thread counts;
- Intel Mac: CPU inference;
- simulator environments: CPU inference.

Whisper enables flash attention with the recommended Apple Silicon configuration. llama.cpp offloads all supported model layers with `n_gpu_layers = -1` when GPU acceleration is selected.

Explicit configuration remains available for focused diagnostics and future tuning without changing feature APIs.

## Whisper runtime

`WhisperRuntimeProtocol` supports:

- explicit model load and unload;
- transcription from normalized audio buffers;
- transcription from normalized WAV files;
- requested language or automatic language detection;
- segment start/end timestamps and text;
- token-level timestamps/text for speaker alignment;
- progress callbacks;
- cooperative cancellation.

### Audio boundary

The native Whisper boundary accepts 16 kHz mono-equivalent Float samples.

The file convenience path intentionally supports normalized WAV only:

- PCM 16-bit or IEEE Float32;
- mono or stereo;
- exactly 16 kHz;
- stereo is downmixed to mono.

This is not the general Inkribe import decoder. Phase 4 owns user-facing audio/video normalization, extraction, and durable media preparation before the runtime is invoked.

Keeping that distinction prevents `WhisperRuntime` from accumulating App-platform media concerns.

### Cancellation

whisper.cpp receives both its native progress callback and abort callback through a thread-safe callback state. Cancelling the Swift task marks that state immediately; native work observes it through the abort callback.

### Diagnostics

Runtime diagnostics may include model identifier, backend, thread count, sample count, segment count, elapsed time, and error type.

They must not contain audio samples or recognized transcript text.

## Speaker diarization runtime

`SpeakerDiarizationRuntimeProtocol` accepts the same normalized 16 kHz mono Float samples produced for Whisper and returns sorted speaker turns.

`NativeSpeakerDiarizationRuntime` combines:

- Pyannote Segmentation 3.0 ONNX for speaker activity/segmentation;
- 3D-Speaker ERes2Net Base for speaker embeddings;
- sherpa-onnx fast clustering for automatic speaker grouping.

The runtime supports an optional known speaker count at its API boundary, while the current app flow uses automatic clustering. Models remain loaded across an active transcription queue batch and are explicitly released when the queue drains.

`InkribeTranscription`, not the runtime, owns mapping those speaker turns onto Whisper token timestamps and smoothing very short speaker islands.

## LLM runtime

`LLMRuntimeProtocol` supports:

- explicit model load and unload;
- prompt evaluation;
- bounded output token generation;
- deterministic sampling configuration;
- incremental token-piece delivery;
- cooperative cancellation;
- conservative context sizing.

The default runtime context is 4096 tokens and the default runtime output ceiling is 1024 tokens. A request is rejected before native evaluation when prompt tokens plus requested output exceed the configured context.

The llama logical batch capacity follows the configured context while physical micro-batching remains capped at 512 tokens. This allows long prompt prefill without forcing equally large physical batches.

### Sampling

The runtime currently exposes temperature and seed:

- temperature `0` uses greedy sampling;
- positive temperature uses temperature sampling followed by seeded distribution sampling.

Phase 6 may define product-level defaults per AI action without changing native sampler ownership.

### Prompt formatting boundary

`LLMRuntime` evaluates the prompt string it receives. It does not own Inkribe product prompts, transcript chunking, chat/instruction formatting policy, or Clean/Polish/Summarize semantics.

Those belong to `InkribeAI` in Phase 6. That layer may format model-specific instruction text before calling the runtime while the runtime remains a general local generation engine.

### Cancellation

The runtime stores cancellation state in native context callback data and also checks it between decode steps. CPU execution can abort through llama.cpp's context abort callback; accelerated generation remains cooperatively cancellable between native decode calls.

### Native backend lifetime

llama.cpp has process-level backend initialization/finalization. `LLMRuntime` therefore uses a locked reference-counted backend owner. The first native model acquires the backend and the last released model releases it.

Each loaded model/context pair is wrapped in a private RAII native-state owner so cleanup is deterministic without exposing pointers to feature code.

### Diagnostics

Runtime diagnostics may include model identifier, backend, thread count, prompt byte count, output byte count, token limits, and elapsed time.

They must not log prompt text or generated text.

## LLM prompt formatting

`LLMRuntime` receives a structured optional system prompt plus user prompt. Before tokenization it reads the default chat template embedded in the loaded GGUF with `llama_model_chat_template` and applies it with `llama_chat_apply_template`, requesting the assistant-generation prefix.

This keeps Qwen control tokens and role formatting owned by the model/runtime layer rather than by feature prompt strings. Missing or unsupported chat-template formatting fails explicitly instead of silently falling back to an ad-hoc prompt envelope.

## Error contract

The runtimes surface typed, user-actionable Swift errors for malformed input, missing/corrupt model state, invalid limits, native loading failures, and native inference failures.

Native pointers and raw engine return types are not part of the public feature contract.

## Later phase boundaries

Phase 4 consumes `WhisperRuntime` after it has normalized durable source media.

Phase 6 consumes `LLMRuntime` through `InkribeAI`, which owns prompt versions, chunking, meaning-preservation rules, product actions, and derived document behavior.
