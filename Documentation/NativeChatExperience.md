# Native Chat Experience

BYOKchat's provider-backed conversation runtime is presented as a native iPhone chat experience with linear history editing, regeneration, drafts, search, and lifecycle-safe streaming.

## Linear history operations

### Edit and resend

Editing a user message replaces that message, deletes every later message, creates a fresh assistant placeholder, and sends the edited context through the conversation's current provider account and model.

BYOKchat keeps one explicit linear history rather than creating hidden branches.

### Regenerate

Regeneration keeps the latest user message and replaces all later assistant state with one new assistant request. It never duplicates the user message.

A failed transport can mark completion as uncertain. Regeneration then requires explicit confirmation because the provider may already have completed and billed the previous request.

## Drafts and search

Each conversation stores an optional local draft. Draft writes are debounced and the draft is cleared atomically when a new turn begins.

Local search covers:

- Conversation titles
- Complete user messages
- Complete assistant messages

Search results preserve the matching conversation and message identifiers so the UI can open and scroll to the relevant message.

## Rendering and actions

Assistant content supports native Markdown plus fenced code blocks with:

- Monospaced rendering
- Horizontal scrolling
- Selectable text
- Explicit copy action

Messages expose copy and share actions. User messages expose Edit and Resend. The latest assistant message exposes Regenerate.

## Provider and model controls

Each conversation retains its own provider account, model, system prompt, temperature override, maximum output tokens, and reasoning settings.

The model chooser is searchable and favorites-first. Unsupported model parameters are hidden. Unavailable models remain visible for recovery but cannot be selected for new requests.

## Scrolling

Streaming follows the newest output only while the reader is near the bottom. Manual upward scrolling disables forced following and reveals a Jump to Latest control.

Interactive keyboard dismissal is enabled and the composer remains in a safe-area inset.

## Lifecycle safety

Partial messages are persisted on a debounce during normal streaming. When the app becomes inactive, the runtime immediately flushes every active generation's newest answer, reasoning, and usage state.

Pending or streaming messages found after relaunch are repaired to an interrupted state.
