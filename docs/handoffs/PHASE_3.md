# Phase 3 Handoff — Native Inference Runtimes

## Status

Phase 3 establishes the native Whisper and local-language-model execution layer used by later transcription and AI feature phases.

## Delivered

### Whisper runtime

- Pinned upstream `whisper.cpp` native artifact and source revision.
- Added actor-owned native context lifecycle with explicit load/unload.
- Added one-time model integrity checking against the Phase 2 manifest before native load.
- Added architecture-aware thread/GPU defaults.
- Added normalized audio-buffer transcription.
- Added normalized WAV convenience decoding for 16 kHz PCM16/Float32 mono/stereo input.
- Added requested-language handling and automatic language detection.
- Added segment timestamps/text extraction.
- Added progress callbacks and native abort-backed cancellation.
- Added privacy-safe runtime logging.
- Added focused runtime/config/WAV contract tests.

### Local LLM runtime

- Pinned upstream `llama.cpp` native artifact and source revision.
- Added actor-owned native generation lifecycle with explicit load/unload.
- Added one-time model integrity checking against the Phase 2 manifest before native load.
- Added Apple Silicon GPU offload and Intel/simulator CPU defaults.
- Added conservative context/output limits.
- Added prompt tokenization and context-capacity rejection before evaluation.
- Added logical context-sized batching with conservative physical micro-batching.
- Added deterministic temperature/seed sampling.
- Added incremental token-piece delivery with UTF-8 boundary handling.
- Added cooperative cancellation through native abort state plus decode-step checks.
- Added reference-counted process-level llama backend ownership.
- Added RAII model/context ownership.
- Added privacy-safe runtime logging.
- Added focused runtime/config contract tests.

## Native dependency contract

Whisper:

- stable version `1.9.4`
- binary tag `b5130`
- source revision `927cfce34f31707e17f2bff35c349632fb9e2c3a`
- archive SHA-256 `033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a`

llama.cpp:

- stable version `0.4.1`
- binary tag `b10964`
- source revision `b29c606e28a01b1bc8c1351026a0fa6e616bf6c4`
- archive SHA-256 `b342a31c3160095d02777cbf1719013d4e6ff7556a1d46ab9eb5df0a93d13c47`

`docs/NATIVE_RUNTIMES.md` is authoritative for the detailed native runtime contract.

## Important implementation decisions

### Actor-owned inference lanes

Each native runtime instance serializes access to its mutable native context. Feature layers should not add a second concurrency mechanism around the same context.

### Native state uses deterministic ownership

Whisper context and llama model/context state live in private RAII owners. Explicit unload drops those owners immediately; releasing the runtime also releases its native state without exposing C pointers outside the package.

### Media normalization remains outside WhisperRuntime

The runtime accepts normalized 16 kHz samples and provides a narrow normalized-WAV convenience path. Phase 4 owns M4A/MP3/audio extraction/video extraction and durable media normalization.

### Prompt semantics remain outside LLMRuntime

The native LLM runtime evaluates the prompt supplied to it. Phase 6 `InkribeAI` owns prompt versions, instruction/chat formatting, long-transcript chunking, action semantics, and preservation rules.

### Privacy-safe diagnostics

Runtime logs contain operational metadata only. They do not contain audio samples, transcript text, prompt text, or generated text.

### Cancellation behavior

Whisper uses its native abort callback. llama generation uses native context abort state and checks cancellation between decode steps; CPU execution can abort inside native decode while accelerated generation remains cooperatively cancellable between calls.

## Deferred to Phase 4

- microphone capture;
- imported media normalization/extraction;
- durable source-media ownership;
- JobQueue transcription execution;
- queue progress mapping and restoration;
- persisted transcript creation from Whisper results.

## Deferred to Phase 6

- Clean / Polish / Summarize / Notes / Action Items behavior;
- product prompt versions;
- transcript chunking/reassembly;
- model-specific instruction formatting;
- derived-document persistence and feature UI.

## Next phase

Phase 4 should consume `WhisperRuntimeProtocol` from the durable transcription job. It should normalize media before calling the runtime and map runtime progress/cancellation into JobQueue rather than adding another processing state machine.
