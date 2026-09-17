# Inkribe v1 — App Store Metadata

Draft date: **2026-09-17**.

This document is the working Mac App Store metadata set for v1. Final wording should be re-checked against the shipping feature set and App Store Connect fields immediately before submission.

## App identity

- **Product name:** Inkribe
- **Bundle ID:** `com.hoangbkit.inkribe`
- **Working App Store name:** `Inkribe: Offline Voice to Text`
- **Name length:** 30 characters
- **Primary category:** Productivity
- **Secondary category:** Utilities

Apple currently allows up to 30 characters for the app name and 30 characters for the subtitle.

## Subtitle

**Private Offline Transcription**

Length: 29 characters.

This keeps the strongest value proposition in the subtitle without repeating “voice to text” exactly.

## Promotional text

**Record or import audio and video, transcribe fully offline, clean with on-device AI, and export polished text or subtitles. No account. No cloud.**

Length: 145 characters.

Apple currently allows up to 170 characters for promotional text, and it can be changed without submitting a new app version.

## Description

**Private speech-to-text, built for your Mac.**

Inkribe turns recordings, audio files, and videos into editable transcripts without sending your audio to the cloud.

Record directly in the app or import existing media, then transcribe it locally with an on-device speech model. Review the transcript alongside synchronized audio, click timestamps to jump to the right moment, and edit the text like a normal document.

When the raw transcript needs cleanup, Inkribe can use a bundled local language model to improve punctuation, remove filler and repetition, polish spoken language, create a summary, generate notes, or extract action items — all on your Mac.

### TRANSCRIBE OFFLINE

• Record from your microphone
• Import audio and video files
• Process multiple files in a queue
• Automatic language detection
• Manual language selection
• Segment timestamps
• Apple Silicon acceleration
• Intel Mac support

### EDIT WITH THE AUDIO BESIDE YOU

• Editable transcript documents
• Synchronized local audio playback
• Click transcript timestamps to seek
• Search inside a transcript
• Keep your original text recoverable while you edit

### ON-DEVICE AI TOOLS

• Clean transcript
• Polish spoken text
• Summarize
• Generate notes
• Extract action items

AI text processing runs locally with a bundled model. No API key is required.

### EXPORT YOUR WORK

• Copy to clipboard
• Plain text
• Markdown
• SRT subtitles
• WebVTT subtitles

### PRIVATE BY DESIGN

Inkribe is designed around local processing:

• No account required
• No cloud transcription required
• No API key required
• No runtime model download required for the bundled v1 models
• Audio, transcripts, and local AI processing stay on your Mac during the core workflow

Record. Transcribe. Edit. Clean. Export.

## Keywords

Working keyword field:

```text
speech,whisper,audio,recording,subtitle,srt,vtt,meeting,lecture,interview,dictation,local,notes
```

Length: 95 characters/bytes in ASCII.

Notes:

- Do not repeat words already used in app name/subtitle unless there is a deliberate reason.
- Do not use competitor names.
- Re-check search demand before submission; this is a clean initial set, not a permanent ASO decision.

## What's New — v1.0

For a first release, App Store Connect normally does not need a “What’s New” style changelog in the same way later versions do. Keep this draft for release notes/website use:

```text
Meet Inkribe — private, offline speech-to-text for Mac.

• Record or import audio and video
• Transcribe locally with bundled models
• Edit transcripts with synced audio and timestamps
• Clean, polish, summarize, and create notes with on-device AI
• Export TXT, Markdown, SRT, and VTT
```

## App Store screenshot story

The screenshots should tell one simple workflow rather than list every feature.

### Screenshot 1 — Core promise

**Offline transcription for Mac**

Show the Transcript Editor with real-looking transcript content and the local/offline state visible.

Secondary copy:

**Your audio stays on your Mac.**

### Screenshot 2 — Record or import

**Turn any recording into text**

Show the Recorder or Import Queue.

Secondary copy:

**Record directly or drop in audio and video.**

### Screenshot 3 — Transcript editor

**Edit with the audio beside you**

Show timestamps and the persistent player bar.

Secondary copy:

**Click any moment to jump through the recording.**

### Screenshot 4 — Local AI

**Clean it with on-device AI**

Show the Clean preview with Original vs Cleaned.

Secondary copy:

**Polish speech without sending the transcript away.**

### Screenshot 5 — Derived notes

**Summary, notes, and action items**

Show Transcript / Summary / Notes modes.

Secondary copy:

**Turn long audio into something useful.**

### Screenshot 6 — Export

**Export the format you need**

Show TXT / Markdown / SRT / VTT export choices.

Secondary copy:

**From readable notes to timed subtitles.**

## Screenshot design rules

- Use the actual shipping UI, not fake browser/dashboard mockups.
- Keep one primary claim per screenshot.
- Do not overcrowd screenshots with feature badges.
- Prefer readable transcript content over decorative empty states.
- Make privacy/local processing visible early in the sequence.
- Show the custom Mac shell, including the full-height sidebar divider, accurately.
- Never show a status/player bar crossing under the sidebar.
- Avoid showing Debug Developer Tools or Logs in App Store screenshots.

## App preview concept

If an App Preview is produced, keep it under Apple's 30-second limit and demonstrate the real flow quickly:

```text
0–4s    Drop an audio file
4–10s   Local transcription progresses
10–16s  Transcript opens; click timestamp and audio seeks
16–22s  Run Clean and preview changes
22–27s  Open Summary/Notes
27–30s  Export
```

The first seconds must be understandable muted because App Store previews autoplay without sound.

## In-app purchase metadata

### Monthly

- Product ID: `com.hoangbkit.inkribe.pro.monthly`
- Type: Auto-renewable subscription
- Target price: $4.99/month
- Display name: **Inkribe Pro Monthly**
- Description: **Unlock Inkribe Pro with a monthly subscription.**

### Yearly

- Product ID: `com.hoangbkit.inkribe.pro.yearly`
- Type: Auto-renewable subscription
- Target price: $24.99/year
- Display name: **Inkribe Pro Yearly**
- Description: **Unlock Inkribe Pro for one year.**

### Lifetime

- Product ID: `com.hoangbkit.inkribe.pro.lifetime`
- Type: Non-consumable
- Target price: $49.99 once
- Display name: **Inkribe Pro Lifetime**
- Description: **Unlock Inkribe Pro permanently with one purchase.**

User-facing prices in the app must come from StoreKit localized product metadata rather than hard-coded dollar strings.

## Privacy positioning

Do not make broader privacy claims than the actual shipping app can support.

For v1 marketing, the safe product claim is:

> Core transcription and bundled AI processing run locally on the Mac without an account, API key, or cloud service.

Before submission, audit:

- analytics/telemetry dependencies
- crash reporting
- network entitlements/use
- StoreKit traffic versus user-content processing
- any support/update checks

The phrase “100% offline” should only be used if it is clear that it describes the user-content processing workflow rather than literally implying the app never makes any network request for StoreKit or standard platform services.

## Support / privacy URLs

TBD before submission:

- Support URL: `<support URL>`
- Privacy Policy URL: `<privacy URL>`
- Marketing URL: `<marketing URL, optional>`

These should be finalized before App Store Connect submission.

## Review notes draft

```text
Inkribe is a macOS speech-to-text app that performs transcription and optional transcript cleanup locally with bundled models.

No account or API key is required for the core workflow.

Test flow:
1. Launch Inkribe.
2. Complete onboarding.
3. Record from the microphone or import a supported audio/video file.
4. Wait for local transcription to complete.
5. Open the transcript, edit text, click timestamps to seek the source audio, and try the local AI actions.
6. Export as TXT, Markdown, SRT, or VTT.

In-app purchases:
- Monthly Pro: com.hoangbkit.inkribe.pro.monthly
- Yearly Pro: com.hoangbkit.inkribe.pro.yearly
- Lifetime Pro: com.hoangbkit.inkribe.pro.lifetime
```

Add any exact Pro-gated test path once the final Free/Pro matrix is locked.

## Metadata checklist before submission

- [ ] Verify final app name still fits 30 characters.
- [ ] Verify subtitle still fits 30 characters.
- [ ] Verify promotional text fits 170 characters.
- [ ] Verify description fits 4000 characters.
- [ ] Verify keywords fit Apple's 100-byte limit.
- [ ] Remove keyword duplication across name/subtitle where practical.
- [ ] Confirm category selection.
- [ ] Finalize support and privacy URLs.
- [ ] Create real screenshots from shipping UI.
- [ ] Confirm screenshot copy matches shipped features.
- [ ] Confirm all IAP IDs/prices in App Store Connect.
- [ ] Confirm localized StoreKit pricing is used in app UI.
- [ ] Complete App Privacy answers based on actual dependencies/data flows.
- [ ] Add model/open-source license notices where required in the app/About/legal materials.

## Apple references

- Product page guidance: https://developer.apple.com/app-store/product-page/
- App information limits: https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- Platform-version metadata limits: https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
- App Store search/keyword guidance: https://developer.apple.com/app-store/search/
