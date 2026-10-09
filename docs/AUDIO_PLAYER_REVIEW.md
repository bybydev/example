# Audio player review

Scope: production Reader, root mini-player, runtime transport, and system media.
Based on develop plus the Listen-safety implementation in PR #34. This is a
source review and implementation, not a simulator/device visual sign-off.

## Findings addressed

| Finding | Resulting behavior |
| --- | --- |
| Controls used the browsed chapter even while another chapter played | The player follows the listening chapter; browsing has an explicit Listen action |
| Static progress with no scrub or elapsed time | Saved audio shows time and exact seeking; live speech shows source progress and passage seeking |
| Whole-book timeline built for every streaming skip | Skip uses the cached current chapter layout and stays in that chapter |
| Generic material surfaces and a small mini-player target | Shared theme surfaces, cover thumbnail, prominent accent play button, 44-point transport targets |
| Mini-player disappeared on failure/completion | Loaded sessions retain Retry/Replay until stopped or pruned |
| Reader sheet resolved a potentially different runtime at presentation | The sheet captures the selected runtime and offers Done |
| Resume could overwrite a failed audio-session restart | Failure remains visible and stale playback work is cancelled |
| Pause during asynchronous paragraph cache load could start audio anyway | Scheduling waits until the Reader is resumed |
| Pause flags could be lost between continuous operations | Pause state persists across the pipeline and queue until explicit resume/stop |
| Chapter switching resumed a paused session | Reader and remote chapter transport preserve pause |
| No sleep controls | Runtime-owned duration/end-of-chapter sleep timer |
| Cover rendering loaded full source image data | ImageIO thumbnail decode, 16 MiB file admission, 512-pixel output cap, low-memory fallback |

## Interaction contract

- Play pauses/resumes the current session; a completed chapter replays from its
  beginning. Retry uses its preserved source bookmark.
- During preparation, the main button can pause. A spinner and preparation text
  explain the state; seeking and skipping wait until preparation is ready.
- Scrub gestures update only temporary UI state and seek once on release.
  Chapter/mode changes discard stale gestures. VoiceOver adjusts by 5%.
- Exact seconds are shown only for compatible saved audio. Live speech has no
  fabricated elapsed/remaining time; approximate skips jump to passage boundaries.
- The previous/next chapter controls have explicit boundary availability.
- Voice/speed remain subject to the existing Free/Pro narration policy. Changing
  narration preserves source and follows existing derived-audio invalidation.
- Stop closes the player and clears its sleep timer. Done/swipe closes the Reader
  while playback and its timer remain runtime-owned.
- Sleep at chapter end overrides automatic continuation without marking the whole
  book complete. Timed sleep pauses and leaves the session available to resume.
- No persistence schema, source text, IDs, analytics, or CI behavior changes.

## Pending validation

Repository AGENTS.md prohibits tests/builds/UI validation without explicit
approval. None were run. Static review covers source call sites, actor ownership,
state transitions, bounds, drag identity, and cancellation paths.

Before release, review on an iPhone with real Kokoro resources:

1. ReadAloud Light/Dark and each premium theme, smallest supported iPhone width,
   maximum Dynamic Type, VoiceOver, and long project/chapter titles.
2. Short text and a long EPUB: first Listen, preparation pause/resume, repeated
   taps, cached/live transitions, and seek/skip near both chapter boundaries.
3. Saved audio: elapsed/remaining time, drag commit, paused seeks, seek to chapter
   end, exact resume, and Lock Screen/Control Center command availability.
4. Browse a different chapter while playing, edit narration, switch chapters while
   paused, open/close the mini-player Reader, retry a failure, and replay completion.
5. Calls/interruption, headphone disconnection, media-services reset, memory
   pressure, background listening, and project deletion during presentation.
6. Duration and end-of-chapter sleep; Stop/shutdown/retry; confirm no stale timer
   pauses a subsequent session and chapter sleep does not complete the whole book.

The implementation is not a claim of perfection or a guarantee against OS process
termination. Visual quality and real audio behavior require this device review.


## Compact / expanded player (PR #40 follow-up)

Reader and Library use `ProjectPlayerExpandableCard` with the same player
content. Compact is the initial state and takes approximately 65–70 pt,
depending on the active theme, system font scaling and safe-area inset.

- **Compact:** cover artwork has one overlaid Play/Pause button (or an in-place
  loading spinner). One-line book title, chapter subtitle, passive thin progress
  line. No skips, stop, voice/speed/sleep row, or miniature scrubber.
- **Tap anywhere else inside the player:** expand in place. Tap a
  non-actionable region in the expanded card to collapse it. Progress indicator
  in compact mode is passive and taps expand; expanded slider owns scrubbing.
- **Expanded:** keeps the complete seek slider, 15-second skip,
  previous/next chapter, central Play/Pause, voice, speed and sleep timer.
  Stop is under the player's actions menu; outside Reader, the same menu
  includes Open Reader.
- **Gesture ownership:** the expand/collapse control is a transparent button
  *behind* the contents, not an `.onTapGesture` on an ancestor. Transport
  buttons, menus and the slider are independent foreground controls; their
  actions never also expand/collapse. A second transparent surface covers card
  margins inside the safe-area inset so taps are consumed instead of leaking
  to content beneath the player.
- Player starts compact when opening Reader. Expansion state persists during
  chapter changes in the same presentation. No audio-runtime or persistence
  semantics were altered by this UI follow-up.

**Device verification still required:** hit-test the artwork, title, progress,
rounded corners, transparent card margin, slider and every action at compact
widths; verify tapping expanded empty space collapses without activating
Reader text behind it, including while scrolling Reader content. Verify
loading/failure/paused states, VoiceOver, Dynamic Type, and both themes.
