# Playback ownership and listening behavior

`ProjectRuntimeManager` coordinates one explicit playback owner. Book runtimes
retain content, cache, bookmarks, and playback state. `ProjectGlobalPlayerHost`
is the only player-card host and lives at the root navigation stack.

## Behavior matrix

| Action or state | Expected behavior | Implementation path |
| --- | --- | --- |
| Detail: Start Listening | Start the selected book and open its Reader. | Detail CTA calls `listen` before navigation. |
| Detail: Continue Listening | Resume the saved chapter/position and open its Reader. | Same operation; runtime applies its bookmark/audio compatibility policy. |
| Same book/chapter already playing or preparing | Keep the current operation; do not pause, restart, or duplicate preparation. | `listen` reuses active states. |
| Same chapter paused | Resume the existing operation. | `listen` calls `resumePlayback`. |
| A playing/paused/preparing, then explicitly listen to B | Stop A's output, cancel its pending playback work, retain A's bookmark, and transfer the player to B before B prepares audio. | `startReaderPlayback` calls coordinator `claimPlayback` synchronously. |
| Browse another book or choose a chapter to read | Current audio continues and the same global player remains visible. | Browsing changes `activeRuntime`/Reader selection, never playback ownership. |
| Reader: Listen to this chapter | Start/resume the displayed chapter, including handoff from another book. | Reader toolbar calls `listen`. |
| Reader: Listen from here | Play from the selected passage, including handoff from another book. | Explicit-offset `play` uses the same claim path. |
| Library hero or player transport | Perform the labelled start, pause, resume, cancel, retry, or replay action. | Hero presentation plus `togglePlayer`/`listen`; terminal states do not pause a retiring task. |
| Player: Previous/Next chapter | Switch within the owner book; preserve user pause. | `changePlayerChapter` uses `play`, then reapplies pause. |
| Player: Seek or skip | Seek in the owner book and ask its visible Reader to follow the new passage. | Existing runtime seek path plus coordinator follow request. |
| Rapid A → B → C | Latest accepted request owns playback. Old tasks cannot reclaim ownership or publish a new active state after stop. | Synchronous ownership plus runtime/pipeline operation and cancellation guards. |
| Invalid request before handoff | Report the error and keep the current book playing. | Runtime validates availability/resource state before claiming. |
| Cold PDF with saved custom filters | Claim a loading session, prepare/validate its projection, then load audio. Pause/close and replacement requests remain available. | Projection loading runs inside the owned operation; known mismatches still fail preflight. |
| New owner's preparation fails | Keep that owner's error/retry card. Previous books do not resume automatically. | Failure stays in owner runtime; retry starts a replacement operation. |
| Close during playing, pause, or preparation | Stop/cancel, persist the current bookmark through the existing stop path, detach system controls, and remove ownership/card. | Coordinator `closePlayer`, runtime `closePlayer`, then `releasePlayback`. |
| Listen again after close | Start/resume the requested book, clear dismissal, and show one card. | Explicit listening creates a new claimed operation. |
| Expand/collapse or navigate between app screens | Keep the same playback operation and one shared presentation state. | Root host with coordinator expansion binding. |
| Tap expanded player book details | Collapse and open its Reader on the root stack; if already there, follow playback without another push. | Coordinator `openPlayerReader`. |
| Lock Screen or headphones | Operate on the attached owner only. | System media adapter forwards to runtime listening/transport operations. |
| Audio interruption ends | Resume only the same interrupted operation when permitted; an explicit pause or replacement cancels automatic resume. | Interrupted operation ID and owner checks. |
| Memory pressure | Stop work and retain the owner's retry target; retry waits until speech-memory release completes. | Runtime suspension plus manager memory-release lifecycle. |
| Owner forgotten/deleted/shut down | Stop/drain through existing lifecycle and release ownership; no fallback player appears. | Runtime shutdown notifies coordinator. |

## Validation status

The implementation and this matrix have been reviewed statically. The focused
regression tests use fake audio output and cover explicit listening/repeated
taps, browsing independence, paused preparation handoff, late activity, rapid
switch/close/reopen, invalid requests, retry during failure cleanup,
interruption resume, cold custom-PDF request admission, player Reader routing,
and owner removal. They have not
been run. Tests live in the existing test source file so no generated Xcode
project edits are required.

Device checks remain necessary for audible output, saved-audio/live-synthesis
handoff, navigation/back gestures, compact/expanded layout, background listening,
Lock Screen/headphones, and interruption/route-change behavior. Build and test
execution require owner approval under `AGENTS.md`.
