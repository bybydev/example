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
- `SpeechModels`: main-actor observable UI preference/inventory/download state. Selection persists in `com.hoangbkit.inkribe.ios.speech-model`. Fresh development installs select a bundled variant if one exists, otherwise Tiny; an explicitly saved missing variant stays selected until the user downloads/changes it. Bundle-only builds ignore an unsupported/unbundled saved preference and choose a bundled variant. Downloads are explicit, never triggered just by opening a project or changing selection, and do not auto-switch an existing preference.

One download at a time. Closing its sheet leaves it running while the process remains active. Cancellation cleans staging and preserves existing installed files. No background transfer entitlement, byte-range resume or download job/history UI is added. Keep the app open; interrupted downloads restart on explicit retry. Downloads show 0–95%, then verification; only verified final files become eligible. Startup inventory is size-based; full digest verification runs again before every native job, so corrupt same-size files never reach inference. Remove/re-download repairs them. Inventory generation guards reject stale UI refreshes.

## Transcription jobs and compatibility

New `SpeechJob.Payload.modelID` pins the selected variant at enqueue/retry. Old durable payloads lacking it still decode and resolve Small, preserving their old meaning. Automatic queue restoration retains the saved choice; an explicit retry captures the current choice only before any result exists. A changed preference never changes a queued/running job or saved recognition. Missing pinned models fail clearly instead of silently choosing another model.

Removal is blocked for nonterminal jobs using that model, including pending jobs; UI removal blocks concurrent enqueue through its final availability recheck. Execution additionally takes a store lease, released after native unload on success/error/cancellation. A download cannot replace a leased file. Each iOS execution constructs a fresh native runtime with its explicit ModelAssetDescriptor, so integrity state cannot carry across variants. The shared NativeWhisperRuntime parameter defaults to nil: existing Mac callers still use the original global Small descriptor and behavior. No Mac manifest/catalog or call site is changed.

Recognition persists the actual descriptor ID/SHA-256. Existing schema-v5 documents and raw/source timing are unchanged; no project migration/retranscription occurs. Loading a missing/corrupt model preserves the project. Bounded audio windows/native timing/editor/export behavior stay as before. Native hashing and initialization can delay cancellation until those synchronous stages return; download verification has per-chunk cancellation.

## UI and handoff

Projects' settings menu offers Speech Models and existing Storage. The transcription card shows the selected model and opens the same sheet; active work displays its captured variant. Storage shows separate downloaded-model bytes and a Manage entry. The sheet provides variant selection, bundled/downloaded/missing status, size, Download/Cancel, verification, explicit Remove confirmation, usage and error/refresh actions. No changes to saved captions when choosing/removing a model.

Source review covered descriptor matching, old job decode defaults, selection capture, bundle/cache precedence, removal/lease checks, bounded transfer/hash, cancellation/publication ordering and packaging inheritance. Compilation, Swift/API strict concurrency, native Tiny/Base compatibility, actual CDN download/error/cancel/relaunch behavior, file publication, bundle-only generation, Mac preservation, UI/accessibility and device memory/latency still need user verification. See VALIDATION.md. Keep this change in one PR targeting develop and leave it open until the user asks to merge.
