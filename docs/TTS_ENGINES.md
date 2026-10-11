# Kokoro ONNX INT8 — ReadAloud's only speech engine

ReadAloud no longer depends on KokoroCoreML, MisakiSwift or MLX. There is no
Core ML implementation, model chooser, optional speech download, or separate
fixture model in shipping or developer release archives.

## Complete offline pipeline

```text
EPUB/PDF/Text -> bounded Reader text chunks
  -> ONNXEnglishTextNormalizer
  -> ONNXG2PPhonemizer:
        Misaki dictionary (bundled JSON)
        CPU ONNX BART fallback for unknown words (bundled ONNX)
  -> KokoroTextProcessor (ReadAloud-owned tokenization)
        Kokoro vocab from the same bundled JSON
  -> KokoroONNXEngine.shared (ONNX Runtime CPU, INT8)
  -> KokoroAudio (ReadAloud-owned 24 kHz mono PCM)
  -> SpeechPlaybackQueue / file-backed offline WAV cache
  -> AVAudioEngine / system remote commands
```

The `SpeechSynthesisEngine` actor protocol is retained as an abstraction
between reader and synthesis, but the factory returns only the shared
`KokoroONNXEngine`. The old `SpeechEngineKind` persisted value is ignored.
Existing project source, bookmarks and finalized audio are retained;
generation compatibility identity remains engine/model/G2P-specific.

## Assets included with every build

| Bundle resource | Approximate size | Purpose |
| --- | ---: | --- |
| `KokoroONNX/model_quantized.onnx` | 92.4 MB | Quantized Kokoro speech |
| `ONNXG2P/misaki-en_us-g2p.onnx` | 3.4 MB | Unknown-word pronunciation |
| `ONNXG2P/misaki-en_us-g2p.json` | 5.7 MB | Lexicon + vocab |
| `KokoroONNX/<voice-id>.bin` | ~14.6 MB total | All 28 English Kokoro v1.0 voice styles (20 US, 8 UK); Heart default |

The app looks up these files inside `Bundle.main.resourceURL/ONNX` and never
uses `URLSession` to fetch speech resources. Missing/invalid bundle assets
produce a reinstall error. Settings -> Kokoro ONNX INT8 can display local
status and test real-text synthesis offline; it cannot download resources.

## Build-time supply and validation

```bash
python3 scripts/onnx-assets.py download
bash scripts/stage-onnx-resources-for-build.sh
xcodegen generate --spec project.yml
```

`scripts/onnx-assets.json` pins all 31 resource paths and source revisions.
The Kokoro INT8 model, Misaki G2P model and dictionary use exact SHA-256
verification. Voice styles are downloaded from the immutable pinned Kokoro
revision and validated against the exact 510 × 256 × 4 byte matrix size.
The build runner validates every downloaded file, stages only complete
resources in `.build-resources/ONNX`, and checks the finished .app bundle
before creating the unsigned mycli release archive. A failed validation
aborts publication.

The manual GitHub Release workflow offers **Debug / Release only**. Both
always bundle production ONNX; there is no fixture/real selector.
Model downloads occur exclusively on the build machine, not user devices.

## Safety and known limitations

- The voice catalog includes only American and British English voices. English G2P is used for every voice.
- The MLX-backed BART fallback is removed from the ONNX runtime path.
- Unknown words use the CPU ONNX BART model, with bounded autoregressive
  decoding and an autorelease pool per synchronous inference step.
- English book quotes, apostrophes, dashes and common formatting are
  normalized; unsupported letters and symbols fail recoverably and include
  an Unicode code point, not the user's text.
- G2P lexical-only disambiguation is weaker than full spaCy-backed Misaki:
  homographs such as “read” may use a common pronunciation.
- A successful short model test does not prove sustained EPUB reading,
  screen-locked synthesis, memory headroom or seamless playback. Validate
  on the iPhone SE 2 before release.

## Provenance

- Speech model and voices:
  https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX
  (Apache-2.0; pinned at `468588286ebb2dd77c25b9771e5d165896538cce`).
- Pronunciation model and dictionary:
  https://huggingface.co/nekwo/misaki-en-us-g2p-onnx
  (Apache-2.0; exact SHA-256 for each bundled artifact).
- Port inspiration:
  https://github.com/ArcadiaLabsLLC/hermes-agent/blob/main/agent_runtime/speech_phonemize.py
  (MIT).
- Bundled attributions: `Resources/ONNX/THIRD_PARTY_NOTICES.txt`.

Further playback prediction/continuous streaming design remains tracked in
issue #35, and real EPUB G2P hardening in issue #38.

## Sentence-first streaming correction (issue #35, PR #37)

The original `SpeechChunkScheduler` cut each utterance after approximately
3 seconds (first chunk) or 7 seconds (later chunks), even inside an English
sentence. This created unnatural stops and loss of sentence-level prosody.

- `SpeechTextSegmentation` uses English `NLTokenizer` to prefer sentence
  boundaries, preserving every source character across contiguous ranges.
- The hard UTF-16 safety ceiling is 300, with a speed-adjusted working ceiling
  of approximately 260 at 1×; only overlong sentences are divided at clauses,
  whole words, and finally a grapheme boundary when unavoidable.
- `KokoroONNXEngine` still checks actual phoneme and model-token limits.
  When over budget, its last-resort split prefers sentence/clause/word
  boundaries rather than arbitrarily halving a passage.
- `ReaderTextLayout` groups complete sentences into bounded Reader
  paragraphs while retaining exact source UTF-16 bookmarks. Hard line wraps
  inside a sentence are not mandatory speech boundaries.
- Streaming and the durable generation queue use the same speech chunk
  scheduler. The synthesis configuration moves to v3 and the ONNX runtime
  identity to v4 so old cached or finalized audio with previous cuts is not
  reused. Previously generated audio remains stored until normal cleanup.

**Not yet implemented:** next-paragraph synthesis/lookahead while the current
paragraph is still playing, reserve-second watermarks, session-scoped prefetch,
and audible-position based progress. The existing paragraph-level drain
remains to avoid advancing bookmarks before speech is heard. Continue this
work in issue #35.

**Manual verification after building on device:**
1. Alice: `‘What is a Caucus-Race?’ asked Alice. ‘I’ll explain,’ replied the Dodo.`
2. A long sentence (250–500 characters) with comma/semicolon clauses.
3. Abbreviations, numbers, curly quotes, apostrophes, em dashes and dialogue.
4. A wrapped source line with no punctuation before `\n`.
5. Long EPUB chapter, seek/stop/resume, cached vs uncached listen, offline WAV.
6. Confirm no missing/duplicated words at chunk boundaries, no memory spike,
   and no mid-sentence interruption except hard model safety overflow.

No build, tests, or workflow run was started during this change. Device
listening and compilation are not yet verified.
