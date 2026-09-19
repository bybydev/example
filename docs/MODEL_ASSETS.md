# Inkribe Model Asset Contract

Phase 2 establishes one stable contract for the bundled model files consumed by the transcription and local-AI runtimes.

## Authoritative manifest

The single source of truth is:

`Packages/InkribeModelAssets/Sources/InkribeModelAssets/Resources/ModelAssets.json`

It owns each asset's stable identifier, runtime owner, display name, relative path under `Models/`, upstream repository, immutable revision, immutable download URL, SHA-256 digest, exact byte count, and upstream license identifier.

Scripts and runtime-facing Swift APIs consume this manifest rather than duplicating model metadata.

## v1 production assets

### Whisper

- ID: `whisper-small-multilingual`
- Model: Whisper Small multilingual
- Upstream: `ggerganov/whisper.cpp`
- Revision: `90a64d80ea254cf67575b41a5971f972c79f7b45`
- File: `Models/whisper/ggml-small.bin`
- Bytes: `487601967`
- SHA-256: `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`
- License: MIT

### Local text models

Default:

- ID: `qwen3-0.6b-q4-k-m`
- Model: Qwen3 0.6B Q4_K_M
- Upstream: `Qwen/Qwen3-0.6B-GGUF`
- Revision: `1208e45d782fe18602c5eaf10e5758d5b0f24c03`
- File: `Models/qwen/Qwen3-0.6B-Q4_K_M.gguf`
- Bytes: `396704416`
- SHA-256: `b0638f08417a2d3c8652760462eb5407c6e30173cf9608ad0820757a281eea0e`
- License: Apache-2.0

Higher-quality option:

- ID: `qwen3-1.7b-q4-k-m`
- Model: Qwen3 1.7B Q4_K_M
- Upstream: `ggml-org/Qwen3-1.7B-GGUF`
- Revision: `daeb8e2d528a760970442092f6bf1e55c3b659eb`
- File: `Models/qwen/Qwen3-1.7B-Q4_K_M.gguf`
- Bytes: `1282439264`
- SHA-256: `d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5`
- License: Apache-2.0

### Speaker diarization models

- ID: `pyannote-segmentation-3-onnx`
- Model: Pyannote Segmentation 3.0 ONNX
- File: `Models/diarization/pyannote-segmentation-3.0.onnx`
- Bytes: `5992778`
- SHA-256: `fed22097bca974bad329a930b60865703766ff89f05fa09060bf6fd44e92e319`
- License: MIT

- ID: `3dspeaker-eres2net-base-3dspeaker-16k`
- Model: 3D-Speaker ERes2Net Base 16 kHz
- File: `Models/diarization/3dspeaker-eres2net-base.onnx`
- Bytes: `39593761`
- SHA-256: `1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b`
- License: Apache-2.0

## Stable bundle layout

Production and path fixtures use the same public layout:

```text
Models/
├── whisper/
│   └── ggml-small.bin
├── qwen/
│   ├── Qwen3-0.6B-Q4_K_M.gguf
│   └── Qwen3-1.7B-Q4_K_M.gguf
└── diarization/
    ├── pyannote-segmentation-3.0.onnx
    └── 3dspeaker-eres2net-base.onnx
```

Runtime code must not look in alternate production/test directories. Tests that only need path semantics can populate `Models/` from `testfixtures/Models/`.

## Shared package

`InkribeModelAssets` is reusable on macOS 15+ and iOS 26+ and has no AppKit or MacAppFoundation dependency.

It provides typed manifest decoding, manifest-shape checks, stable `Models/` URL construction, explicit missing-model errors, streaming SHA-256 and byte-count inspection, and integrity comparison against the manifest.

`WhisperRuntime` exposes its single model descriptor through this shared package. `LLMRuntime` maps user-selectable model IDs to descriptors from the same manifest, with Qwen3 0.6B as the default. `DiarizationRuntime` resolves its segmentation and speaker-embedding models through the same manifest.

## Download behavior

`scripts/download-models.sh` delegates to the `ModelAssetTool` executable in the package. For each asset it keeps an existing file only when its exact byte count and SHA-256 match, downloads from the immutable revision URL, retries failed transfers, stages the download beside the final destination, checks size and digest, and publishes the file only after those checks succeed.

A partial or mismatched download is never published under the production filename.

## Developer commands

```text
make download-models
make verify-models
make install-model-fixtures
```

`Models/` remains ignored by Git. Production weights are restorable from the manifest but are never stored in the repository.

## Tiny fixtures

`testfixtures/Models/` contains tiny marker files with the exact production relative paths and names. They are intentionally not inference-capable weights. Their purpose is model-discovery, missing-file, corrupt-file, and path-contract behavior without bloating the repository. Native inference fixtures are a Phase 3 concern.

## Runtime rule

Runtime implementations must resolve model locations through `InkribeModelAssets` and check integrity before handing the file to native inference code. They must not silently fall back to a different model filename, floating upstream revision, runtime download, or user-specific cache path.
