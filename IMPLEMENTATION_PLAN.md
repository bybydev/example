# BYOKchat Implementation Plan

## Product Definition

BYOKchat is an iOS-only, BYOK-only AI chat client. It connects directly from the device to user-configured AI providers through AppFoundation.

### Fixed scope

- Product name: **BYOKchat**
- iOS 26+
- SwiftUI, SwiftData, XcodeGen
- AppFoundation onboarding, theme, and AI provider configuration
- English-only UI
- BYOK only
- Local conversation storage
- API keys stored through AppFoundation Keychain storage
- Direct provider communication from the device
- Supported providers: OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek, NVIDIA
- No app account
- No app backend
- No managed AI credits
- No StoreKit or paywall in the initial build
- No CloudKit or iCloud sync in version 1.0
- No image input, file attachments, voice, web search, tool calling, agents, or prompt marketplace in version 1.0

## Repository Workflow

### AppFoundation

AppFoundation work must be isolated in a feature branch and delivered through a pull request:

```text
AppFoundation/develop
    -> feature/direct-ai-text-streaming
    -> PR into develop
    -> review and validation
    -> merge
    -> tag 1.2.1
```

Do not push AppFoundation changes directly to `develop` or `master`.

### BYOKchat

The BYOKchat repository is developed directly on:

```text
hoangbkit/BYOKchat:master
```

Each phase should be committed as one coherent commit or a small set of tightly related commits. Do not force-push. Do not run GitHub Actions.

---

# Phase 1 — Patch AppFoundation for Text Streaming

## Goal

Add reusable, provider-neutral text streaming to AppFoundation while preserving the existing one-shot `generate(_:)` API.

## Public API

Keep `AppAIDirectProviderClient` source-compatible. Introduce a separate streaming protocol:

```swift
public protocol AppAIStreamingProviderClient: AppAIDirectProviderClient {
    func stream(
        _ request: AppAIDirectRequest
    ) -> AsyncThrowingStream<AppAIStreamEvent, Error>
}
```

Initial normalized event model:

```swift
public enum AppAIStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case completed(AppAIDirectResponse)
}
```

The completed response must contain:

- Full normalized text
- Provider ID
- Actual model ID
- Finish reason
- Input token usage
- Output token usage
- Cached input token usage where available

Add backend-manager lookup:

```swift
public func streamingDirectClient(
    for provider: AppAIProviderID
) throws -> any AppAIStreamingProviderClient
```

## Streaming transport

Add a separate streaming transport abstraction rather than changing the required methods of `AppAITransport`.

Responsibilities:

- Open the HTTP response before consuming the full body
- Expose incremental bytes or lines
- Validate HTTP status before parsing events
- Cancel the underlying URLSession task when the consumer task is cancelled
- Preserve normalized AppFoundation provider errors
- Never automatically retry a generation stream

## Shared SSE parser

Implement a reusable parser that supports:

```text
event: optional-name
data: JSON payload

data: [DONE]
```

It must handle:

- Events split across network chunks
- Multiple events in one chunk
- UTF-8 boundaries
- Empty lines as event delimiters
- `data:` with or without a following space
- Provider error events
- Stream completion without an explicit `[DONE]`
- Consumer cancellation
- Premature connection close

## Provider support

### OpenAI Responses

Parse:

- Text output deltas
- Response completed events
- Response failed events
- Final usage and model metadata

### Anthropic Messages

Parse:

- `content_block_delta`
- Text deltas
- `message_delta`
- `message_stop`
- Input, output, and cache usage
- Stop reason

### Gemini GenerateContent

Use the streaming GenerateContent endpoint and parse:

- Candidate text parts
- Finish reason
- Model metadata where available
- `usageMetadata`

### OpenAI-compatible Chat Completions

Use the existing compatible client for OpenRouter, DeepSeek, and NVIDIA:

- Set `stream: true`
- Parse `choices[].delta.content`
- Recognize `[DONE]`
- Capture finish reason
- Capture usage when supplied

## Scope restriction

Streaming initially supports text responses only:

```swift
responseFormat == .text
```

Structured JSON requests continue using `generate(_:)`.

## Cancellation and partial output

- Cancellation throws `CancellationError`
- The underlying request must stop immediately
- No automatic retry
- Partial text received before cancellation remains available to the caller
- AppFoundation does not decide whether partial output is persisted
- A transport failure after partial output is still surfaced as a failure

## Tests

Add deterministic fixture-based tests for:

- Normal streaming for every provider family
- Chunk-boundary splitting
- Multiple deltas
- Empty deltas
- Usage decoding
- Finish-reason decoding
- Provider-generated errors
- HTTP authentication failures
- Rate limits
- Insufficient credits
- Cancellation
- Premature connection close
- Missing explicit completion event
- Existing one-shot generation remaining unchanged
- Existing mock transports continuing to compile

No live keys are required for unit tests.

## Delivery

1. Create `feature/direct-ai-text-streaming` from AppFoundation `develop`.
2. Implement the public contracts, transport, parsers, provider support, and tests.
3. Add a minimal streaming screen to AppFoundation Demo.
4. Run `swift test` locally.
5. Build AppFoundation Demo for supported Apple targets.
6. Open a PR into `develop`.
7. Document API design, provider coverage, cancellation behavior, and validation evidence in the PR.
8. Merge after review.
9. Tag AppFoundation `1.2.1`.
10. BYOKchat must depend on the released tag, not the temporary feature branch.

## Exit criteria

All supported providers emit normalized text deltas through one public API, existing one-shot generation is unaffected, and the AppFoundation PR is ready to merge.

---

# Phase 2 — Bootstrap BYOKchat and Provider Setup

## Goal

Create the iOS project and let a new user configure at least one provider before entering the chat experience.

## Project structure

```text
BYOKchat/
├── project.yml
├── BYOKchat/
│   ├── App/
│   ├── Features/
│   ├── Domain/
│   ├── Data/
│   ├── Services/
│   ├── UI/
│   ├── Resources/
│   └── Supporting/
├── BYOKchatTests/
└── README.md
```

## Project settings

- Deployment target: iOS 26
- Bundle identifier: `com.hoangbkit.byokchat`
- Swift 6 strict concurrency
- SwiftData local store
- XcodeGen project generation
- AppFoundation `1.2.1`
- No CloudKit entitlement
- No backend configuration
- No StoreKit configuration

## AppFoundation composition

Create one shared `AppAIBackendManager` with direct providers only:

```swift
AppAIBackendCatalog(
    backends: [
        .openAI(),
        .anthropic(),
        .gemini(),
        .openRouter(),
        .deepSeek(),
        .nvidia()
    ]
)
```

Do not register `AppAIManagedBackend`.

## Onboarding

Use AppFoundation onboarding style:

1. Welcome
2. Privacy explanation
3. Choose provider
4. Enter API key
5. Discover or enter model
6. Test connection
7. Confirm default provider and model
8. Finish

The user cannot finish onboarding until at least one provider has:

- A saved credential
- A selected model
- A successful connection test

## Main navigation

```text
TabView
├── Chats
└── Settings
```

Chats initially shows an empty state and New Chat action.

Settings contains:

- Default provider
- Provider configuration
- Default model per provider
- Default system prompt
- Privacy explanation
- App information

Reuse AppFoundation provider configuration components. Do not duplicate Keychain or model-discovery UI.

## Recovery behavior

If the active provider key is removed and no configured provider remains, route the user back to provider setup rather than leaving the app in a broken state.

## Tests

- Clean-install onboarding
- Provider selection persistence
- Model selection persistence
- Invalid key handling
- Failed connection test
- Removing the active credential
- Returning to setup with no configured provider
- Confirming no managed backend is exposed

## Commit

```text
Bootstrap BYOKchat with BYOK provider setup
```

Push directly to `master`.

## Exit criteria

A clean installation can configure a provider, test it, finish onboarding, and reach the empty chat list.

---

# Phase 3 — Conversation Domain, Persistence, and Navigation

## Goal

Build the local conversation system independently of provider-specific networking.

## SwiftData models

### Conversation

Store:

- UUID
- Title
- Created date
- Updated date
- Provider ID
- Model ID
- System prompt
- Ordered messages

The provider and model are snapshots owned by the conversation. Changing global defaults affects only newly created chats.

### Message

Store:

- UUID
- Role
- Content
- Created date
- Status
- Provider ID
- Model ID
- Finish reason
- Input tokens
- Output tokens
- Cached input tokens
- Error description

Statuses:

```swift
enum ChatMessageStatus: String, Codable {
    case pending
    case streaming
    case complete
    case failed
    case cancelled
    case interrupted
}
```

Do not store credentials, provider clients, or `AppAIMessage` directly in SwiftData.

## Domain services

### ConversationStore

Responsible for:

- Creating conversations
- Loading conversations
- Updating titles
- Deleting conversations
- Deleting all conversation data
- Fetching ordered messages
- Persisting message status and metadata

### ChatContextBuilder

Responsible for converting stored messages into `[AppAIMessage]`.

Rules:

- System prompt first
- Include valid user messages
- Include only completed assistant messages
- Exclude failed, cancelled, interrupted, and empty placeholders
- Preserve chronological order
- Never include internal error descriptions
- Build an immutable context snapshot when a request begins

### ChatSession

Use `@MainActor @Observable` for transient chat UI state:

- Draft text
- Active stream task
- Partial assistant output
- Send availability
- Cancellation
- Selected conversation
- Error presentation

The data layer must not depend on SwiftUI.

## Conversation list

Implement:

- Create chat
- Open chat
- Delete chat
- Rename chat
- Sort by most recently updated
- Provider/model badge
- Last-message preview
- Empty state
- New Chat action

Use the first meaningful user message as the local title. Do not spend an extra provider request on title generation in version 1.0.

## New-chat behavior

1. Copy the current default provider.
2. Copy its current model.
3. Copy the default system prompt.
4. Persist the new conversation.
5. Open it immediately.

## Tests

- Conversation CRUD
- Cascade message deletion
- Stable ordering
- Provider/model snapshots
- Context conversion
- Exclusion of incomplete messages
- Local title generation
- Clean SwiftData store behavior

## Commit

```text
Add local conversation domain and persistence
```

Push directly to `master`.

## Exit criteria

Users can create, rename, browse, and delete persisted conversations, and the app can construct a correct provider-neutral request context.

---

# Phase 4 — Streaming Chat Experience

## Goal

Deliver the complete core chat experience through AppFoundation streaming.

## Send pipeline

```text
User presses Send
    -> validate provider, credential, and model
    -> persist user message
    -> create assistant placeholder
    -> build immutable request context
    -> resolve AppAIStreamingProviderClient
    -> consume text deltas
    -> update visible assistant response
    -> persist final response and metadata
```

## Streaming persistence

Do not write to SwiftData for every token.

Use:

- Immediate in-memory rendering
- Debounced partial persistence every 250–500 ms
- Immediate persistence on completion
- Immediate persistence on cancellation
- Immediate persistence on error
- Immediate persistence during app lifecycle transitions

## Cancellation

While generating, replace Send with Stop.

On stop:

- Cancel the stream task
- Preserve partial text
- Mark the assistant message as cancelled
- Show a subtle Stopped state
- Never retry automatically
- Allow explicit manual retry

## Error handling

Normalize UI for:

- Missing key
- Rejected key
- Insufficient provider credit
- Rate limit
- Invalid model
- Model unavailable
- Provider error
- Network failure before output
- Network failure after partial output
- Empty output
- Background interruption

Never automatically resend after uncertain transport completion because the provider may already have charged for the request.

## Message rendering

Assistant messages support:

- Native Markdown
- Selectable text
- Code blocks
- Horizontal scrolling for long code
- Copy full response
- Share response
- Provider/model metadata
- Error, cancellation, or interrupted footer

User messages support:

- Copy
- Select text
- Edit and resend

## Edit and resend

1. Open the selected user message in an editor.
2. On confirmation, delete all later messages.
3. Save the edited user content.
4. Generate a new assistant response.

Version 1.0 uses linear history only. Do not implement hidden response branches.

## Regenerate

- Keep the latest user message
- Replace the latest assistant result
- Use the conversation’s current provider and model
- Require explicit user action after uncertain completion

## Provider switching

The chat header exposes provider and model selection.

Before switching, warn:

```text
Future messages and the existing conversation context
will be sent to the newly selected provider.
```

Existing message metadata remains unchanged. The new provider/model applies to future generations only.

## Scrolling and keyboard

- Auto-scroll only when the user is near the bottom
- Do not force-scroll after the user moves upward
- Show Jump to Latest
- Keep the composer stable during keyboard transitions
- Preserve unsent draft text per conversation
- Disable duplicate sends

## Tests

- Delta accumulation
- Debounced persistence
- Successful completion metadata
- Cancellation
- Partial-output failure
- Duplicate-send prevention
- Edit and resend
- Regenerate
- Provider switching
- Background/foreground interruption
- View dismissal while streaming

## Commit

```text
Implement streaming AI conversations
```

Push directly to `master`.

## Exit criteria

A configured user can hold a stable multi-turn streaming conversation with every supported provider, cancel safely, and recover from common failures.

---

# Phase 5 — Product Completion and Release Features

## Goal

Turn the functioning chat engine into a complete version 1.0 product.

## Search

Add local search across:

- Conversation titles
- User messages
- Assistant messages

Selecting a result opens the conversation and scrolls to the matching message where practical.

## System prompts

Support:

- Global default system prompt
- Per-conversation override
- Clear override and return to default
- Empty system prompt

Do not add a prompt library or marketplace.

## Context management

Use a conservative context-budget strategy:

1. Preserve the system prompt.
2. Preserve the latest user message.
3. Keep the newest complete turns.
4. Remove whole oldest turns when needed.
5. Reserve capacity for expected output.
6. Never silently cut a message in half.

Use discovered model context metadata when available. Otherwise use conservative provider defaults.

When older messages are omitted, show:

```text
Some earlier messages were not included in this request.
```

Do not implement automatic conversation summarization in version 1.0.

## Export and import

### Single conversation export

Export Markdown containing:

- Title
- Date
- Provider and model
- System prompt when present
- User and assistant messages

### Full backup

Export all conversations as versioned JSON.

Requirements:

- Include a schema version
- Never export API keys
- Preserve message metadata needed for restoration

### Import

- Import only BYOKchat versioned JSON
- Validate the complete file before mutating the database
- Report invalid or skipped records
- Handle duplicate IDs safely

## Data controls

Settings includes:

- Export all data
- Import backup
- Delete all conversations
- Remove individual provider keys
- Reset onboarding
- Clear default system prompt

Destructive actions require confirmation.

## Privacy and accessibility

Complete:

- Plain-language privacy screen
- Privacy manifest review
- Dynamic Type
- VoiceOver labels
- Appropriate hit targets
- Reduce Motion behavior
- High-contrast validation
- Keyboard dismissal
- Text selection and copy accessibility
- No API-key logging
- Redacted diagnostics
- No analytics containing chat text

## Performance

Validate:

- Long conversations
- Large Markdown responses
- Large code blocks
- Rapid streaming
- Conversation-list fetch performance
- SwiftData write frequency
- Memory use when navigating between long chats

## UI polish

Complete:

- Exact brand casing: BYOKchat
- Empty states
- Loading and streaming indicators
- Provider icons
- Haptics
- Error alerts
- Confirmation sheets
- Provider setup recovery
- App icon
- Launch appearance
- AppFoundation-consistent theme

## Documentation

README must explain:

- What BYOKchat is
- Supported providers
- Local conversation storage
- Keychain credential handling
- No included AI usage
- No app-operated server
- Basic development setup
- AppFoundation dependency

## Commits

```text
Add search, system prompts, and data portability
Polish BYOKchat for release
```

Push directly to `master`.

## Exit criteria

The app has a complete onboarding-to-chat-to-export lifecycle and no version 1.0 screen depends on placeholder behavior.

---

# Phase 6 — Consolidation

## Goal

Stop adding features and review the entire product as one system. This phase is for simplification, correction, hardening, and release readiness only.

## Architecture consolidation

Remove:

- Provider-specific protocol code from BYOKchat
- Duplicate credential handling
- Duplicate model discovery
- Duplicate AppFoundation provider UI
- Dead abstractions
- Premature protocols with one implementation
- Unused fields and settings
- Debug bypasses
- Temporary provider fixtures
- Temporary AppFoundation branch dependencies

Final responsibility boundary:

### BYOKchat owns

- Conversations
- Context assembly
- Chat state
- Persistence
- Product UI
- Export and import
- App lifecycle recovery

### AppFoundation owns

- Provider credentials
- Provider configuration
- Model discovery
- Request encoding
- HTTP transport
- SSE parsing
- Provider streaming differences
- Response normalization
- Provider error normalization

## Cross-provider validation matrix

Run controlled live tests for every provider:

| Scenario | OpenAI | Anthropic | Gemini | OpenRouter | DeepSeek | NVIDIA |
|---|---:|---:|---:|---:|---:|---:|
| Configure key | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Discover models | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Stream short answer | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Stream long answer | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Cancel midway | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Multi-turn context | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Invalid key | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Invalid model | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Insufficient credit | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Background interruption | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

If a provider does not support model discovery, represent that accurately instead of faking parity.

## Persistence recovery

Test:

- Clean install
- Normal upgrade
- App termination during streaming
- Corrupt import
- Duplicate import
- Missing provider key after restore
- Provider removed while old conversations remain
- Model no longer available
- Conversation deletion
- Full data deletion
- Large database launch

Any message left in `pending` or `streaming` after abnormal termination must become `interrupted` on next launch.

## Security review

Confirm:

- Keys exist only in Keychain
- Keys never enter SwiftData
- Keys never enter exported files
- Keys never appear in logs
- Request bodies are not logged in release builds
- Provider-switch warnings are accurate
- No app backend receives messages
- No analytics captures chat text
- Clipboard writes occur only after explicit user action

## Build and test gate

Run locally:

```text
AppFoundation
├── swift test
├── Demo iOS build
└── Existing package validation

BYOKchat
├── XcodeGen regeneration
├── Debug build
├── Release build
├── Unit tests
├── UI smoke tests
└── Physical-device tests
```

Do not run GitHub Actions.

## Final AppFoundation state

- Streaming PR merged
- No unresolved review threads
- Tests passing
- Release tag `1.2.1`
- Streaming API documented

## Final BYOKchat state

- AppFoundation pinned to `1.2.1`
- No temporary branch dependency
- No uncommitted generated-project changes
- README complete
- Version and build number set
- Consolidation fixes pushed to `master`

## Final commit

```text
Consolidate BYOKchat for 1.0
```

## Final completion criteria

BYOKchat is implementation-complete when:

1. A new user can configure any supported provider without an app account.
2. API keys remain in Keychain.
3. Conversations remain local.
4. Every provider streams through one AppFoundation abstraction.
5. Cancellation never causes an automatic duplicate request.
6. Existing chats preserve provider and model history.
7. Provider switching is explicit.
8. Export never contains credentials.
9. The app survives interruption and relaunch without corrupt message state.
10. A clean checkout builds using the documented setup.
