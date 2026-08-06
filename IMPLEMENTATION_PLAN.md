# BYOKchat Implementation Plan

## Product Definition

BYOKchat is an iOS-only, BYOK-only AI chat client. It connects directly from the device to user-configured AI providers and stores conversations locally.

The app is intentionally not built on AppFoundation's AI provider manager. That implementation is designed for normal apps with a small, app-defined provider catalog. BYOKchat is itself a provider client and must be able to evolve toward a much broader, OpenCode-like provider ecosystem.

### Fixed scope

- Product name: **BYOKchat**
- iOS 26+
- SwiftUI, SwiftData, XcodeGen
- Swift 6 strict concurrency
- English-only UI
- BYOK only
- Direct provider communication from the device
- Local conversation storage
- API credentials stored in Keychain
- No app account
- No BYOKchat backend
- No managed AI credits
- No StoreKit or paywall in the initial implementation
- No CloudKit or iCloud sync in version 1.0
- No GitHub Actions
- Development is pushed directly to `hoangbkit/BYOKchat:master`

### Version 1.0 chat scope

Include:

- Text chat
- Streaming responses
- Multiple conversations
- Multiple providers
- Multiple accounts per provider
- Provider and model switching
- Custom OpenAI-compatible providers
- Custom endpoints and headers
- Model discovery and manual model entry
- System prompts
- Markdown and code rendering
- Edit, resend, regenerate, stop, copy, and share
- Local search
- Conversation export
- Full local backup and restore

Exclude from version 1.0:

- Image input
- File attachments
- Voice mode
- Web search
- Tool calling
- Agents
- MCP
- Prompt marketplace
- Cross-device sync
- App-operated proxying

---

# Architecture Decision

## BYOKchat owns the provider platform

BYOKchat must not depend on these AppFoundation AI types at runtime:

- `AppAIBackendManager`
- `AppAIBackendCatalog`
- `AppAIBackendDescriptor`
- `AppAIDirectProviderClient`
- AppFoundation provider configuration screens
- AppFoundation selected-provider and selected-model preferences

The provider layer is copied from AppFoundation once as a starting snapshot, renamed, reorganized, and then developed independently inside BYOKchat.

There is no requirement to keep source compatibility with AppFoundation after the copy.

There is no AppFoundation streaming PR in this plan.

## AppFoundation remains optional shared infrastructure

BYOKchat may continue using AppFoundation for non-AI capabilities such as:

- Theme primitives
- General onboarding presentation
- Shared UI utilities
- Common extensions that are not coupled to provider management

No BYOKchat provider behavior should require an AppFoundation change.

## Ownership boundary

### BYOKchat owns

- Provider definitions
- Provider discovery
- Provider accounts
- API credentials
- Authentication strategies
- Custom endpoints
- Custom headers
- Model catalogs
- Model capability metadata
- Model variants and parameters
- Request encoding
- Streaming protocols
- Provider-specific event parsing
- Error normalization
- Connection tests
- Conversation execution
- Context budgeting
- Provider import and export
- Future OAuth integrations
- Compatibility workarounds

### AppFoundation may own

- Generic app UI foundation
- Generic onboarding shell
- Theme and visual helpers
- Non-AI reusable infrastructure

---

# Provider Platform Design

## Stable string identifiers

Provider and model identity must use stable strings rather than closed enums.

```swift
struct ProviderID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

struct ProviderAccountID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}

struct ModelID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
}
```

Adding a provider must not require adding a new enum case throughout the app.

## Provider definition

A `ProviderDefinition` describes what a provider is, not a user's configured credentials.

```swift
struct ProviderDefinition: Identifiable, Codable, Sendable {
    let id: ProviderID
    let displayName: String
    let iconName: String?
    let documentationURL: URL?
    let apiFamily: ProviderAPIFamily
    let defaultBaseURL: URL
    let authentication: AuthenticationDefinition
    let defaultHeaders: [String: String]
    let modelsEndpoint: String?
    let capabilities: ProviderCapabilities
    let configurationSchema: ProviderConfigurationSchema
}
```

Definitions may be:

- Bundled built-ins
- Bundled aliases using a shared API family
- User-created custom providers
- Imported provider configurations
- Future remotely updated definitions after explicit validation

## Provider accounts

A provider may have multiple accounts.

```swift
struct ProviderAccount: Identifiable, Codable, Sendable {
    let id: ProviderAccountID
    let providerID: ProviderID
    var label: String
    var baseURLOverride: URL?
    var headerOverrides: [String: String]
    var configurationValues: [String: String]
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
}
```

Credentials are referenced by account ID and stored separately in Keychain. They must never be stored in SwiftData, UserDefaults, logs, exports, or crash diagnostics.

## API families

Provider definitions should reuse a small set of protocol adapters.

```swift
enum ProviderAPIFamily: Codable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropicMessages
    case geminiGenerateContent
    case custom(String)
}
```

The initial source copy from AppFoundation provides a base for:

- OpenAI Responses
- OpenAI-compatible Chat Completions
- Anthropic Messages
- Gemini GenerateContent

Most additional providers should be configuration on top of these shared families rather than new client classes.

## Provider adapters

```swift
protocol ProviderAdapter: Sendable {
    var familyID: String { get }

    func testConnection(
        account: ResolvedProviderAccount,
        model: ModelID?
    ) async throws

    func listModels(
        account: ResolvedProviderAccount
    ) async throws -> [ProviderModel]

    func generate(
        request: ProviderRequest,
        account: ResolvedProviderAccount
    ) async throws -> ProviderResponse

    func stream(
        request: ProviderRequest,
        account: ResolvedProviderAccount
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error>
}
```

The registry selects an adapter using `ProviderDefinition.apiFamily`.

## Provider registry

`ProviderRegistry` is the central provider-definition service.

Responsibilities:

- Load bundled provider definitions
- Load user-created providers
- Merge overrides deterministically
- Reject duplicate or invalid identifiers
- Resolve a provider definition
- Resolve the matching API adapter
- Expose provider capabilities to the UI
- Keep provider definition state separate from account state
- Support adding many providers without changing conversation code

## Account store

`ProviderAccountStore` owns non-secret account configuration.

Responsibilities:

- Create accounts
- Rename accounts
- Enable and disable accounts
- Delete accounts
- Store base URL overrides
- Store safe custom headers
- Store provider-specific configuration values
- Choose a default account globally and per provider
- Preserve old conversation references when an account is removed

## Credential vault

`CredentialVault` owns Keychain access.

Requirements:

- Namespace credentials by BYOKchat bundle and account ID
- Support more than one secret field when a provider requires it
- Trim accidental whitespace where appropriate
- Allow secrets that intentionally contain spaces
- Delete empty credentials
- Use device-only Keychain accessibility unless a later product decision changes it
- Never return credentials through observable UI state after saving
- Provide redacted configuration status
- Support complete account credential removal

## Model catalog

```swift
struct ProviderModel: Identifiable, Hashable, Codable, Sendable {
    let providerID: ProviderID
    let id: ModelID
    var displayName: String
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var capabilities: ModelCapabilities
    var defaultParameters: ModelParameters
    var isUserDefined: Bool
}
```

The model catalog merges:

1. Bundled known models
2. Provider-discovered models
3. User-defined models
4. User overrides

Remote discovery must not erase manual models or local metadata.

## Capabilities

Provider and model capability metadata should support future expansion without requiring version 1.0 UI for every field.

Examples:

- Text input
- Text output
- Streaming
- System messages
- Reasoning controls
- Temperature
- Top-p
- Maximum output tokens
- JSON mode
- Tool use
- Image input
- Audio input
- Prompt caching
- Context window

The chat composer and settings UI must only expose controls supported by the selected model.

## Request and stream contracts

```swift
struct ProviderRequest: Sendable {
    let model: ModelID
    let messages: [ProviderMessage]
    let parameters: ModelParameters
}

struct ProviderResponse: Sendable {
    let text: String
    let providerID: ProviderID
    let accountID: ProviderAccountID
    let modelID: ModelID
    let finishReason: String?
    let usage: ProviderUsage?
}

enum ProviderStreamEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case usage(ProviderUsage)
    case completed(ProviderResponse)
}
```

Version 1.0 may ignore `reasoningDelta` in normal chat display, but the provider core should not incorrectly merge hidden reasoning into the visible answer.

## Custom OpenAI-compatible providers

Users must be able to create a provider by supplying:

- Name
- Stable local ID
- Base URL
- Chat-completions path
- Optional models path
- Authentication strategy
- Secret header name when required
- Additional headers
- Default model
- Manual model list
- Streaming support toggle

Custom providers use the shared OpenAI-compatible adapter wherever possible.

---

# Repository Workflow

All BYOKchat implementation work is committed and pushed directly to:

```text
hoangbkit/BYOKchat:master
```

Rules:

- Do not create an AppFoundation PR for this project
- Do not push provider changes back to AppFoundation
- Do not force-push
- Do not run GitHub Actions
- Keep each phase in one coherent commit or a small set of tightly related commits
- Run local builds and tests before pushing phase completion
- Generated Xcode project files must remain consistent with `project.yml`

---

# Phase 1 — Bootstrap BYOKchat and Clone the Provider Core

## Goal

Create the iOS project and establish BYOKchat's independent provider foundation by copying the useful AppFoundation AI implementation into the repository.

This is a one-time source extraction, not an ongoing fork synchronization workflow.

## Project structure

```text
BYOKchat/
├── project.yml
├── BYOKchat/
│   ├── App/
│   ├── Core/
│   ├── ProviderCore/
│   │   ├── Accounts/
│   │   ├── Adapters/
│   │   ├── Credentials/
│   │   ├── Definitions/
│   │   ├── HTTP/
│   │   ├── Models/
│   │   ├── Registry/
│   │   ├── Streaming/
│   │   └── WireFormats/
│   ├── Conversations/
│   ├── Features/
│   ├── Data/
│   ├── UI/
│   ├── Resources/
│   └── Supporting/
├── BYOKchatTests/
├── Documentation/
└── README.md
```

## Project settings

- Deployment target: iOS 26
- Bundle identifier: `com.hoangbkit.byokchat`
- Swift 6 strict concurrency
- SwiftData local store
- XcodeGen project generation
- AppFoundation dependency only for approved non-AI UI infrastructure
- No CloudKit entitlement
- No backend configuration
- No StoreKit configuration

## Source extraction

Copy the relevant AppFoundation 1.2.0 AI implementation as a starting snapshot:

- Direct request and response models
- Provider IDs and model metadata
- HTTP validation and error mapping
- Credential storage concepts
- OpenAI Responses client
- OpenAI-compatible client
- Anthropic Messages client
- Gemini GenerateContent client
- Provider configuration presets
- Model-list decoding
- Existing direct-provider fixture tests where reusable

Do not copy:

- Managed AI proxy client
- App Attest
- Entitlement synchronization
- Managed quota status
- AppAI backend manager
- Managed backend catalog
- Managed usage UI
- App-specific server registration

## Immediate detachment

After copying:

- Move all code under `BYOKchat/ProviderCore`
- Remove AppFoundation AI imports
- Rename `AppAI*` symbols to BYOKchat-owned neutral names
- Replace fixed provider enums with string IDs
- Separate provider definitions from provider accounts
- Separate credentials from account metadata
- Remove assumptions that only one account exists per provider
- Remove assumptions that the provider list is fixed at compile time
- Add source-origin documentation in `Documentation/ProviderCoreOrigin.md`
- Treat the new code as BYOKchat code from this point forward

Suggested initial renaming:

```text
AppAIProviderID            -> ProviderID
AppAIMessage               -> ProviderMessage
AppAIDirectRequest         -> ProviderRequest
AppAIDirectResponse        -> ProviderResponse
AppAIDirectUsage           -> ProviderUsage
AppAIDirectError           -> ProviderError
AppAIDirectProviderClient  -> ProviderAdapter
AppAIModel                 -> ProviderModel
```

## Streaming foundation

Add the BYOKchat-owned streaming transport during this phase.

Requirements:

- `URLSession.bytes(for:)` or an equivalent cancellation-aware byte stream
- Shared SSE decoder
- Support event and data fields
- Support multiple data lines
- Correct UTF-8 chunk handling
- Correct blank-line event termination
- `[DONE]` handling
- Provider error events
- HTTP error parsing before stream decoding
- Cancellation of the underlying request
- No automatic generation retry
- Clear premature-close behavior

Implement streaming for the four initial adapter families:

- OpenAI Responses
- OpenAI Chat Completions
- Anthropic Messages
- Gemini GenerateContent

## Initial bundled providers

Use the copied implementations to define the first provider set:

- OpenAI
- Anthropic
- Gemini
- OpenRouter
- DeepSeek
- NVIDIA

These are initial definitions, not a closed supported-provider list.

## Minimal developer test screen

Before building onboarding, add a debug-only provider-core screen that can:

- Select a bundled provider
- Enter a temporary key
- Enter a model
- Test connection
- List models
- Stream a short response
- Cancel a stream
- Display normalized usage and errors

Do not persist temporary debug credentials unless explicitly saved.

## Tests

- Provider ID encoding
- Definition loading
- Duplicate definition rejection
- Account and credential separation
- Request validation
- HTTP error normalization
- SSE chunk-boundary parsing
- Multiple events in one chunk
- Multi-line data events
- Cancellation
- Premature close
- OpenAI Responses fixtures
- OpenAI-compatible fixtures
- Anthropic fixtures
- Gemini fixtures
- Existing one-shot generation fixtures
- No references to AppFoundation AI management types

## Commit

```text
Bootstrap BYOKchat with independent provider core
```

Push directly to `master`.

## Exit criteria

- BYOKchat builds as an iOS 26 project
- ProviderCore contains no dependency on AppFoundation AI management
- All four API families support one-shot and streaming text generation
- The six initial bundled providers work through the registry
- ProviderCore unit tests pass

---

# Phase 2 — Provider, Account, and Model Management

## Goal

Build the user-facing provider platform required for a large and extensible provider ecosystem.

## Provider registry implementation

Create a bundled provider-definition format, preferably Codable JSON or plist, so most provider additions require data rather than new Swift types.

Each definition supports:

- Provider ID
- Display name
- Icon reference
- API family
- Default base URL
- Authentication strategy
- Default headers
- Models endpoint
- Connection-test behavior
- Capabilities
- Configuration fields
- Default models where useful

Validate bundled definitions during tests and fail clearly during development when invalid.

## Provider management UI

The Providers screen contains:

- Configured accounts first
- Available built-in providers
- Custom providers
- Search
- Add provider action
- Import provider configuration

A provider detail screen shows:

- Provider information
- Configured accounts
- Add account
- Custom endpoint support
- Supported API family
- Model discovery state
- Provider-specific help

## Multiple accounts

Users can create multiple accounts for the same provider, for example:

```text
OpenRouter
├── Personal
├── Work
└── Testing
```

Each account supports:

- User-defined label
- Credential fields
- Base URL override
- Safe header overrides
- Default model
- Enabled state
- Connection test
- Model refresh
- Delete account

The UI should display only redacted credential status after saving.

## Authentication strategies

Support at least:

- Bearer token
- Named header token
- Query parameter token
- Multiple named secret headers
- No authentication for local-network providers

Design the schema so future OAuth accounts can be added without changing conversation persistence.

## Keychain behavior

- Secrets keyed by account ID and secret-field ID
- Remove all secrets when an account is deleted
- Preserve secrets when an account is renamed
- Do not expose saved secret values by default
- Replace secret only when the user enters a new value
- Allow explicit remove-secret action
- Never include secrets in app state restoration

## Model management

Each account has a model screen supporting:

- Refresh from provider
- Search discovered models
- Add manual model
- Edit local model metadata
- Hide unwanted models
- Favorite models
- Choose account default
- Reset local overrides

Model refresh rules:

- Merge rather than replace
- Preserve manual models
- Preserve favorites
- Preserve user overrides
- Mark disappeared remote models as unavailable rather than immediately deleting them
- Record the last successful refresh date

## Custom OpenAI-compatible provider flow

Create a guided setup flow:

1. Provider name
2. Base URL
3. Chat-completions path
4. Optional models path
5. Authentication type
6. Credential
7. Additional headers
8. Default model
9. Test connection
10. Save provider and account

Advanced fields remain collapsed by default.

## Provider import and export

Support a versioned, non-secret provider configuration format.

Export may include:

- Provider definition
- Account label
- Endpoints
- Non-secret headers
- Manual model definitions
- Capability overrides

Export must never include credentials.

On import:

- Validate schema
- Reject unsafe URLs where required
- Show the configuration before saving
- Require the user to enter credentials separately
- Resolve provider ID conflicts explicitly

## Onboarding

Use a lightweight onboarding flow:

1. Welcome
2. Explain direct provider connections and local storage
3. Choose a built-in provider or custom provider
4. Create an account
5. Save credential
6. Discover or enter a model
7. Test connection
8. Select default account and model
9. Finish

The app may be browsed without a provider configured, but sending a message requires a valid account and model.

## Settings

Settings contains:

- Providers and accounts
- Default account
- Default model per account
- Default system prompt
- Data controls
- Privacy
- App information

## Initial provider expansion

Add configuration-driven definitions for compatible providers where practical, such as:

- Groq
- Mistral
- xAI
- Together AI
- Fireworks AI
- Cerebras
- Perplexity
- Moonshot
- SiliconFlow
- AnyScale-compatible endpoints if still applicable
- Ollama
- LM Studio
- Generic OpenAI-compatible server

Do not claim compatibility without a documented endpoint and successful manual validation. Providers with materially different protocols wait for later adapter work.

## Tests

- Provider-definition decoding
- Definition validation
- Registry merge precedence
- Multiple accounts per provider
- Credential isolation between accounts
- Account deletion cleanup
- Default account persistence
- Model merge behavior
- Manual model preservation
- Custom provider creation
- Provider configuration import/export
- Secret exclusion from exports
- Failed connection recovery

## Commit

```text
Add extensible provider and account management
```

Push directly to `master`.

## Exit criteria

- Users can configure multiple accounts across built-in and custom providers
- Provider definitions are primarily data-driven
- Credentials are isolated by account
- Models can be discovered, added manually, favorited, and selected
- A custom OpenAI-compatible provider can be created without changing code

---

# Phase 3 — Conversation Domain, Persistence, and Chat Runtime

## Goal

Build the local conversation system and connect it to the independent provider platform.

## SwiftData models

### Conversation

Store:

- UUID
- Title
- Created date
- Updated date
- Active provider ID
- Active account ID
- Active model ID
- System prompt
- Model parameter overrides
- Ordered messages

Provider, account, and model values are conversation snapshots. Changing global defaults affects only new conversations unless the user explicitly changes an existing conversation.

### Message

Store:

- UUID
- Role
- Visible content
- Optional reasoning content if intentionally preserved
- Created date
- Updated date
- Status
- Provider ID
- Account ID
- Model ID
- Finish reason
- Input tokens
- Output tokens
- Cached input tokens
- Error code
- Safe error description

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

Do not store:

- API credentials
- Authorization headers
- Complete raw HTTP requests
- Provider adapter objects
- Unredacted provider error payloads that may contain secrets

## ConversationStore

Responsibilities:

- Create conversations
- Fetch conversation lists
- Fetch ordered messages
- Rename conversations
- Delete conversations
- Delete all conversations
- Persist message lifecycle changes
- Repair interrupted states after abnormal termination
- Maintain updated dates efficiently

## ChatContextBuilder

Responsibilities:

- Build immutable request context when send begins
- Place the system message correctly for the selected adapter
- Include valid user messages
- Include only completed assistant messages
- Exclude failed, cancelled, interrupted, and empty placeholders
- Preserve chronological order
- Apply context budgeting
- Never include internal errors
- Never include messages added after the request snapshot

## Context budgeting

Use model metadata when available.

Strategy:

1. Reserve output capacity.
2. Preserve system instructions.
3. Preserve the latest user message.
4. Keep newest complete turns.
5. Remove whole oldest turns when needed.
6. Never silently cut a message in half.
7. Record when older context is omitted.

Use a conservative estimator initially. Tokenizer-specific optimization can be added later without changing the conversation model.

## ChatSession

Use `@MainActor @Observable` for transient interaction state.

Responsibilities:

- Draft text
- Active stream task
- Selected provider account
- Selected model
- Partial visible output
- Partial reasoning output
- Send availability
- Stop behavior
- Retry behavior
- Error presentation
- Per-conversation draft restoration

The provider adapters and persistence layer must not depend on SwiftUI.

## Send pipeline

```text
User presses Send
    -> validate account, credentials, and model
    -> persist user message
    -> create assistant placeholder
    -> build immutable context snapshot
    -> resolve provider definition
    -> resolve account and credentials
    -> resolve API-family adapter
    -> start stream
    -> apply deltas in memory
    -> debounce partial persistence
    -> persist final response and usage
```

## Streaming persistence

Do not write to SwiftData for every token.

Use:

- Immediate in-memory UI updates
- Debounced partial persistence around 250–500 ms
- Immediate persistence on completion
- Immediate persistence on cancellation
- Immediate persistence on error
- Immediate persistence when entering background

## Cancellation

- Stop cancels the consuming task and underlying network task
- Preserve partial visible output
- Mark the assistant message cancelled
- Never retry automatically
- Allow explicit retry
- Avoid treating user cancellation as a provider failure

## Error handling

Normalize UI for:

- Missing credential
- Authentication rejected
- Permission denied
- Insufficient credit
- Rate limit
- Invalid model
- Model unavailable
- Invalid endpoint
- Provider error
- Network failure before output
- Network failure after partial output
- Empty output
- Unsupported parameter
- Stream parsing failure
- Background interruption

Never automatically resend after uncertain transport completion because the provider may already have processed and billed the request.

## Conversation list

Implement:

- Create chat
- Open chat
- Delete chat
- Rename chat
- Most-recent ordering
- Provider/account/model badge
- Last-message preview
- Empty state
- New Chat action

Use the first meaningful user message as a local title. Do not spend an additional AI request on title generation in version 1.0.

## New conversation behavior

1. Copy the global default account.
2. Copy its default model.
3. Copy the default system prompt.
4. Persist the conversation.
5. Open it immediately.

## Provider switching

Changing an existing conversation's provider, account, or model must be explicit.

Show a warning when the provider or account changes:

```text
Future messages and the existing conversation context will be sent to the selected provider account.
```

Existing message metadata remains unchanged.

## Tests

- Conversation CRUD
- Cascade message deletion
- Stable ordering
- Provider/account/model snapshots
- Context conversion
- Context omission behavior
- Exclusion of incomplete messages
- Delta accumulation
- Debounced persistence
- Cancellation
- Partial-output failure
- Duplicate-send prevention
- Provider-account switching
- App relaunch repair of streaming messages

## Commit

```text
Add conversations and provider-backed chat runtime
```

Push directly to `master`.

## Exit criteria

- Users can create and persist conversations
- Multi-turn streaming works through the provider registry
- Account and model changes are explicit
- Cancellation and interruption are recoverable
- No conversation code depends on a concrete provider client

---

# Phase 4 — Complete Native Chat Experience

## Goal

Turn the runtime into a polished, efficient iOS chat client.

## Main navigation

```text
TabView
├── Chats
└── Settings
```

Provider management is opened from Settings and from provider/model selection sheets in chat.

## Chat screen

Navigation area:

- Conversation title
- Active provider
- Active account label
- Active model
- Menu for conversation settings

Message area:

- User messages
- Assistant Markdown
- Code blocks
- Streaming state
- Provider/model metadata
- Usage metadata when available
- Error, stopped, or interrupted state

Composer:

- Multiline text input
- Send button
- Stop button while streaming
- Provider/model shortcut
- Draft persistence

## Message rendering

Assistant messages support:

- Native Markdown
- Selectable text
- Code-block formatting
- Horizontal scrolling for long code
- Copy response
- Share response
- Regenerate
- Usage details
- Provider, account, and model details

User messages support:

- Copy
- Select text
- Edit and resend

## Edit and resend

1. Open a user message editor.
2. Confirm replacement.
3. Delete all later messages in the linear history.
4. Save the edited message.
5. Generate a new assistant response.

Version 1.0 uses linear history. Do not implement hidden response trees.

## Regenerate

- Keep the latest user message
- Replace the latest assistant result
- Use the conversation's current provider account and model
- Require explicit confirmation when the previous request ended with uncertain completion

## System prompts and parameters

Support:

- Global default system prompt
- Per-conversation system prompt
- Reset conversation prompt to default
- Per-conversation supported model parameters
- Reset parameters to model defaults

Only show parameters supported by the selected model.

Possible version 1.0 parameters:

- Temperature
- Maximum output tokens
- Reasoning effort where supported

Do not expose every provider body field in the normal chat UI.

## Search

Search locally across:

- Conversation titles
- User messages
- Assistant messages

Selecting a result opens the conversation and scrolls to the matching message where practical.

## Scrolling and keyboard behavior

- Auto-scroll while already near the bottom
- Do not force the user down after manual upward scrolling
- Show Jump to Latest
- Keep the composer stable during keyboard transitions
- Preserve drafts per conversation
- Disable duplicate sends
- Handle interactive keyboard dismissal
- Restore sensible position when returning to a conversation

## Empty and recovery states

Include clear states for:

- No conversations
- No provider account
- Missing credential for an old conversation
- Deleted account referenced by an old conversation
- Model no longer available
- Provider disabled
- Connection test failed
- Conversation interrupted during last launch

The app should guide the user to repair configuration without deleting conversation history.

## Accessibility

- Dynamic Type
- VoiceOver labels and reading order
- Appropriate hit targets
- Reduce Motion
- High contrast
- Selectable message content
- Accessible code-block copy action
- Non-color-only error states

## Performance

Validate:

- Long conversations
- Large Markdown responses
- Large code blocks
- Rapid streams
- Switching between long chats
- Search over a large local database
- Efficient SwiftData writes
- No unnecessary full-list redraw on every token

## Tests

- Edit and resend
- Regenerate
- Draft restoration
- Search
- Provider/model selector behavior
- Missing-account recovery
- Model-unavailable recovery
- Scroll-follow rules
- View dismissal during streaming
- Background and foreground transitions
- Dynamic Type smoke tests

## Commit

```text
Complete the native BYOKchat experience
```

Push directly to `master`.

## Exit criteria

- Core chat behavior is polished and consistent
- Long responses remain responsive
- Users can repair provider problems from the conversation
- Search, prompts, parameters, edit, regenerate, copy, and share are complete

---

# Phase 5 — Provider Expansion, Data Portability, and Release Completion

## Goal

Expand the provider ecosystem safely and complete the version 1.0 product lifecycle.

## Provider expansion strategy

Provider additions follow this order:

1. Add a data-only definition when an existing API family is fully compatible.
2. Add small adapter configuration hooks when compatibility differs only by headers, paths, or field names.
3. Add a new adapter only when the protocol or streaming format materially differs.
4. Add provider-specific UI only when generic schema-driven configuration is insufficient.

Avoid one provider class per brand when multiple brands share the same wire protocol.

## Validation matrix

Every bundled provider must be tracked against:

- Account creation
- Credential validation
- Model discovery
- Manual model fallback
- Short stream
- Long stream
- Multi-turn context
- Cancellation
- Invalid key
- Invalid model
- Rate limit
- Insufficient credit where testable
- Endpoint override
- Background interruption

A provider is not marked fully supported until the relevant scenarios have been manually validated.

## Local-network providers

Support providers such as Ollama and LM Studio with clear warnings:

- The iPhone must be able to reach the host
- Plain HTTP may require explicit local-network and transport configuration
- Local Network permission may be required
- Simulator and physical-device networking differ
- No-auth accounts must be represented explicitly rather than using fake keys

Do not silently weaken global App Transport Security settings.

## Data export

### Single conversation Markdown

Include:

- Title
- Date
- Provider
- Account label
- Model
- System prompt when present
- User and assistant messages

Never include credentials, authorization headers, or internal raw request payloads.

### Full backup

Export versioned JSON containing:

- Conversations
- Messages
- Non-secret provider definitions
- Non-secret account configuration
- Manual model definitions
- User preferences

Credentials are never exported.

## Import

- Validate the entire backup before database mutation
- Use a schema version
- Migrate supported older versions
- Detect duplicate IDs
- Preview provider definitions and account configuration
- Require credentials to be re-entered
- Report skipped invalid records
- Roll back on unrecoverable import failure

## Data controls

Settings includes:

- Export one conversation
- Export all data
- Import backup
- Export provider configuration
- Import provider configuration
- Delete one provider account
- Delete all credentials
- Delete all conversations
- Reset onboarding
- Reset app preferences

Destructive actions require confirmation.

## Privacy and security review

Confirm:

- Credentials exist only in Keychain
- No credential values in SwiftData
- No credential values in UserDefaults
- No credentials in exports
- No credentials in logs
- No request bodies logged in release builds
- No analytics containing conversation text
- Clipboard writes occur only after explicit action
- Provider-switch warnings are accurate
- Direct connection behavior is clearly explained
- Custom endpoint risks are clearly explained
- Imported headers cannot unexpectedly override protected security headers without warning

## Privacy documentation

Add an in-app privacy explanation and repository documentation covering:

- BYOKchat does not provide AI usage
- Requests go directly to the selected provider or endpoint
- Each provider has its own privacy and retention policy
- Conversations are stored locally by BYOKchat
- Credentials are stored in Keychain
- Backups exclude credentials
- Custom providers are controlled by the user

## App lifecycle and recovery

Validate:

- Clean install
- Upgrade migration
- App termination during streaming
- Device reboot during pending state
- Provider account deleted while referenced
- Provider definition removed or disabled
- Model removed upstream
- Corrupt import
- Duplicate import
- Large backup import
- Low-storage persistence failure

Messages left pending or streaming after abnormal termination must become interrupted at next launch.

## Release polish

Complete:

- BYOKchat brand casing everywhere
- App icon
- Launch appearance
- Provider icons and fallback icons
- Empty states
- Error wording
- Haptics
- Confirmation dialogs
- Privacy manifest review
- README
- Development setup
- Provider-contribution documentation
- Backup schema documentation

## README

Document:

- What BYOKchat is
- iOS requirements
- Supported provider families
- Bundled providers
- Custom OpenAI-compatible providers
- Direct connection behavior
- Credential storage
- Local conversation storage
- Build instructions
- XcodeGen commands
- AppFoundation's limited non-AI role
- How to add a provider definition
- When a new adapter is required

## Tests and build gate

Run locally:

```text
xcodegen generate
Debug build
Release build
Unit tests
ProviderCore fixture tests
SwiftData migration tests
Import/export tests
UI smoke tests
Physical-device provider tests
```

Do not run GitHub Actions.

## Commit

```text
Expand providers and prepare BYOKchat 1.0
```

Push directly to `master`.

## Exit criteria

- Provider support is broad and data-driven
- Custom providers work without source changes
- Backups restore conversations and non-secret provider configuration
- Security and privacy checks pass
- A clean checkout builds using documented commands

---

# Phase 6 — Consolidation

## Goal

Stop adding features and review BYOKchat as one complete system.

This phase is for simplification, correctness, consistency, and release readiness. It must not become another feature phase.

## Provider architecture consolidation

Review the entire provider platform and remove:

- Remaining AppFoundation AI dependencies
- Remaining `AppAI*` naming
- Fixed provider-switch statements that should use registry data
- Duplicate HTTP request construction
- Duplicate SSE parsing
- Duplicate authentication handling
- Brand-specific adapters that can be configuration
- Provider definitions embedded unnecessarily in Swift
- Unsafe arbitrary header handling
- Unused capability flags
- Dead provider experiments
- Temporary debug credentials
- Debug-only endpoints

Confirm the intended dependency direction:

```text
Conversation UI
    -> Chat runtime
        -> Provider registry
            -> API-family adapter
                -> HTTP and streaming transport
```

No provider adapter may depend on SwiftUI or SwiftData.

## Model and account consolidation

Verify:

- Account IDs remain stable after rename
- Credential keys use account IDs, not labels
- Conversations survive account deletion
- Deleted accounts show recoverable missing-account state
- Model refresh never destroys manual models
- Capability overrides have deterministic precedence
- Global defaults do not silently rewrite old conversations
- Custom providers can be exported without secrets

## Cross-provider validation

Run live tests for each bundled provider that can be accessed.

Minimum matrix:

| Scenario | Required |
|---|---:|
| Create account | Yes |
| Save and remove credential | Yes |
| Test connection | Yes |
| Discover models or document unsupported discovery | Yes |
| Stream short response | Yes |
| Stream long response | Yes |
| Multi-turn context | Yes |
| Cancel midway | Yes |
| Invalid key | Yes |
| Invalid model | Yes |
| Rate-limit mapping | Fixture or live |
| Partial-output network failure | Fixture |
| Background interruption | Yes |
| Provider/account switching | Yes |

Do not claim universal provider compatibility based only on a shared API label.

## Persistence consolidation

Test:

- Clean install
- Normal upgrade
- Schema migration
- App termination during streaming
- Relaunch repair
- Conversation deletion
- Full data deletion
- Missing account
- Missing model
- Missing provider definition
- Corrupt backup
- Duplicate backup
- Large conversation history
- Large model catalog

Remove redundant persisted fields and add migrations before release rather than carrying accidental schema debt into 1.0.

## Security consolidation

Audit every path that handles credentials or headers.

Confirm:

- Keychain only for secrets
- No secrets in observable snapshots
- No secrets in crash strings
- No secrets in debug print output
- No secrets in exported provider JSON
- No secrets in conversation JSON
- No secret-bearing request dumps
- Clipboard only after explicit user action
- Custom endpoint and custom-header warnings are accurate
- Account deletion removes all associated secrets

## UX consolidation

Walk the complete user journey:

```text
Install
-> add provider or custom endpoint
-> create account
-> enter credential
-> discover or add model
-> test connection
-> create chat
-> stream response
-> stop
-> regenerate
-> switch model
-> switch provider account
-> search
-> export
-> delete credentials
-> repair old conversation
```

Remove redundant screens, duplicate settings, and unnecessary confirmation steps while preserving security-critical warnings.

## Performance consolidation

Profile:

- Token streaming update frequency
- Markdown rendering
- SwiftData write frequency
- Conversation-list fetches
- Search queries
- Provider model lists
- Large backup encoding and decoding
- Memory after opening multiple long chats

Fix measured bottlenecks rather than adding speculative caches.

## Documentation consolidation

Ensure documentation matches the final implementation:

- ProviderCore architecture
- Provider-definition schema
- API-family adapters
- Custom-provider setup
- Credential storage
- Backup schema
- Build instructions
- Supported and partially supported providers
- Known limitations

Remove obsolete references to AppFoundation AI provider management and the abandoned AppFoundation streaming PR.

## Final build gate

Run locally:

```text
xcodegen generate
Clean Debug build
Clean Release build
All unit tests
All fixture tests
All migration tests
Import/export tests
UI smoke tests
Physical-device tests
```

Do not run GitHub Actions.

## Final repository state

- BYOKchat owns all provider management and provider runtime code
- AppFoundation is used only for explicitly approved non-AI infrastructure
- No feature-branch package references
- No temporary copied-file markers
- No uncommitted generated-project drift
- README and architecture documentation are current
- Version and build number are set
- All consolidation fixes are pushed directly to `master`

Suggested final commit:

```text
Consolidate BYOKchat for 1.0
```

## Final completion criteria

BYOKchat is implementation-complete when:

1. A user can add built-in and custom providers without an app account.
2. Multiple accounts per provider are supported.
3. Credentials remain in Keychain and never enter exports.
4. Provider definitions are open-ended and mostly data-driven.
5. OpenAI Responses, OpenAI-compatible, Anthropic, and Gemini families stream through independent BYOKchat adapters.
6. A custom OpenAI-compatible provider can be added without source changes.
7. Conversations survive provider, account, and model changes.
8. Cancellation never causes an automatic duplicate request.
9. Interrupted streams recover safely after relaunch.
10. Provider switching is explicit about where conversation context is sent.
11. Backups restore conversations and non-secret provider configuration.
12. The app remains responsive with long conversations and fast streams.
13. No BYOKchat provider work requires modifying AppFoundation.
14. A clean checkout builds using the documented local workflow.
