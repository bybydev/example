# Optional iOS speech models

2026-10-22. Explicit user-requested amendment after P6 #29 was squash merged as e2bb512. This extends V1.LOCAL_STT/JOB; The user subsequently requested P7 in the same PR #30; its source audit/handoff is in handoffs/P7.md. Pro remains deferred. Source integration only, with no agent builds/typechecks/tests, generation, weights, inference, CI or device validation.

## Choose packaging

| Setup | User's generation command | iOS weights | App downloads |
|---|---|---|---|
| Default development | `xcodegen generate --spec project.yml` | None required/copied, even if Mac Models exists | Enabled; choose/download in Speech Models |
| Future bundled production option | `xcodegen generate --spec project-ios-bundled.yml` | Requires `Models/whisper/ggml-small.bin` | Disabled; downloaded cache is not a fallback |

These commands are documentation, not executed work. The same `Inkribe` iOS target/scheme remains. Debug/Release alone do not choose packaging: even Release from the base spec remains download-enabled. Choose the bundled spec explicitly for a bundled release. It includes the base spec, appends the required Small resource and adds `-D INKRIBE_IOS_BUNDLED_MODELS_ONLY` to the iOS target for all configurations. Missing production weights fail generation instead of silently producing a model-less app. It does not modify the Mac target, Mac Models membership or global manifest.

The Small resource still arrives as `ggml-small.bin` in Bundle.main, preserving the existing bundled loader path. A custom hybrid spec can append any catalog `ggml-*.bin` resources to the iOS target while leaving the bundled-only condition off; the loader always prefers a bundle file for that variant. Bundled files cannot be removed by app cleanup. To hard-bundle another supported variant later, change the bundled spec's required resource; no loader rewrite is needed.

## Variants and provenance

All three are multilingual GGML weights, source `ggerganov/whisper.cpp`, MIT, pinned revision **90a64d80ea254cf67575b41a5971f972c79f7b45**. Native binary/version and CPU/thread policy are unchanged. Larger model families/English-only/quantized variants are not introduced by this request.

| Variant / stable ID | Filename | Exact bytes | SHA-256 |
|---|---|---|---|
| Tiny / whisper-tiny-multilingual | ggml-tiny.bin | 77,691,713 | be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21 |
| Base / whisper-base-multilingual | ggml-base.bin | 147,951,465 | 60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe |
| Small / whisper-small-multilingual | ggml-small.bin | 487,601,967 | 1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b |

Metadata source (retrieved without weights): https://huggingface.co/api/models/ggerganov/whisper.cpp/revision/90a64d80ea254cf67575b41a5971f972c79f7b45?blobs=true . Each download URL is `https://huggingface.co/ggerganov/whisper.cpp/resolve/<revision>/<filename>?download=true`. No moving main/latest URLs, credentials, cloud inference or audio upload. Download requests expose normal network metadata to the hosting service.

## Ownership, cache and cancellation

- `SpeechModelCatalog`: iOS-only allowlist/descriptors/build policy/bundle lookup. Mac's single-Whisper global manifest stays unchanged.
- `ModelDownload`: one ephemeral foreground URLSession download streams to disk, accepts HTTPS redirects, requires HTTP 200, bounds reported/written bytes and verifies the staged file size. Delegate state/continuation/cancellation are locked; progress is limited to one callback per percentage. No model-sized Data or URL cache.
- `SpeechModelStore`: sole actor owns `Application Support/InkribeIOSSpeechModels`. The directory is excluded from backup. Final filenames are `<SHA256>.bin`; UUID `.partial` files are staged on the same volume, fully checked with 1 MiB SHA-256 reads/cancellation points, then atomically published. Available-space check reserves weight bytes plus 64 MiB; actual writes can still fail with a clear error. Interrupted staging is discarded on the next store startup. Installed files remain until explicit removal or app uninstall, independent of thumbnail/project/Trash cleanup.
- `SpeechModels`: main-actor observable inventory/download state, reading the one active preference from SpeechEngine. The engine persists it in `com.hoangbkit.inkribe.ios.speech-model`. Fresh development installs select a bundled variant if one exists, otherwise Tiny; an explicitly saved missing variant stays selected until the user downloads/changes it. Bundle-only builds ignore an unsupported/unbundled saved preference and choose a bundled variant. Downloads are explicit, never triggered just by opening a project or changing selection, and do not auto-switch an existing preference.

One download at a time. Closing its sheet leaves it running while the process remains active. Cancellation cleans staging and preserves existing installed files. No background transfer entitlement, byte-range resume or download job/history UI is added. Keep the app open; interrupted downloads restart on explicit retry. Downloads show 0–95%, then verification; only verified final files become eligible. Startup inventory is size-based; full digest verification runs before loading a native context, so a corrupt same-size file cannot create a new context. Remove/re-download repairs them. Inventory generation guards reject stale UI refreshes.

## One shared engine and active model

2026-10-26, PR #44. This supersedes the earlier per-job pinned-model design.

SpeechEngine is the single app-wide active-model and native-runtime owner.
SpeechModels provides Settings inventory/download state and reads the engine's
active preference, using the existing UserDefaults key. Jobs use the shared
engine, retaining its verified loaded context across successful transcriptions.
A failed/cancelled context is unloaded before reuse. Mac callers and package APIs
remain unchanged.

Settings confirms switching to a different installed model. Confirming blocks new
speech admission, invalidates in-flight speech preparations, cancels all queued/
running transcription plus downloads, waits for speech teardown, unloads the old
context and activates/persists the new choice. Export preparation, admission,
queued/running exports and export controls remain unaffected. The shared native
work gate still serializes heavy operations; switching does not wait for exports.
Completed files, accepted captions and edits stay saved. Declining the confirmation changes nothing. A cancellation persistence
failure leaves the old active choice intact. Prior foreground/user-pause intent is
preserved, and cancelled jobs require an explicit retry.

New payloads do not capture modelID. Existing optional payload model fields remain
decodable and are ignored for execution; there is no legacy Small fallback or
original-model requirement. Every new or resumed inference uses the active engine.
Accepted windows are reused across model switches while source, language, runtime
and mapping compatibility stay strict. New work fills unresolved ranges, retaining
raw intervals, stable word IDs, corrections, manual captions and undo history.
Recognition/checkpoint model ID/SHA fields describe the latest attempt, never an
engine selection or a claim that all retained windows used that same model.

The loaded context holds a store lease. A leased model cannot be deleted/replaced;
unloaded downloads can be removed independently of old queue payloads. Digest
verification runs when loading a context, and that verified context is then reused.
Native hashing/initialization can delay cancellation until synchronous stages
return. No model-sized buffers, per-job native context or old-model recovery UI is
added. Saved project/job/checkpoint formats remain unchanged.

## UI and handoff

Settings is the only model-name/selection/management surface. The editor keeps
language, transcription, progress, cancellation and retry, with generic unavailable
messages pointing to Settings. Home setup links to Settings; Storage and job
details do not open model management. The model sheet provides active selection,
installation state, sizes, explicit download/cancel/removal and model-switch
confirmation. Packaging and model files are unchanged by this source update.
