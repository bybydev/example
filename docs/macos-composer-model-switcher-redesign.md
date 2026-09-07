# macOS Composer Model Switcher Redesign

## Status

Design only. Do not implement as part of this commit.

## Goal

Make switching the active chat target from the macOS composer extremely fast for the three things users change most often:

- provider connection
- model
- reasoning / thinking effort

The composer switcher should be a lightweight, high-frequency control. The AI Providers workspace remains the place for provider management and configuration.

## Design principle

Use two clearly separated surfaces:

- **Composer quick switcher** — choose a ready provider connection, model, and effort with minimal interaction.
- **AI Providers workspace** — manage credentials, endpoints, discovery, model visibility, favorites, default models, headers, connection status, testing, and deletion.

The quick switcher should consume configuration from AI Providers rather than duplicating management features.

## Current flow

The composer already exposes the active target as a compact pill. When a target exists, clicking the pill opens `MacTargetPickerView`. When there is no target, the composer opens provider management.

The current picker is a 680×500 modal sheet with:

- provider list on the left
- searchable model list on the right
- reasoning controls at the bottom
- Cancel / Done commit flow
- Manage Providers entry point

This is functionally correct but too heavy for a high-frequency composer action.

## Proposed interaction model

Replace the modal target-picker experience with a popover anchored to the composer target pill.

The popover should support immediate changes without a separate Done button.

Conceptually:

```text
                 COMPOSER

      [ Claude · Sonnet 4.6 · High ▾ ]
                         │
                         ▼
              ┌──────────────────┐
              │ Quick Switcher   │
              │                  │
              │ Provider         │
              │ Model            │
              │ Effort           │
              │                  │
              │ Manage Providers ├──────────────┐
              └──────────────────┘              │
                                                ▼
                                ┌──────────────────────────────┐
                                │ AI Providers                 │
                                │                              │
                                │ Overview / Models / Connection
                                │                              │
                                │ Keys                         │
                                │ Discovery                    │
                                │ Favorites                    │
                                │ Hidden models                │
                                │ Endpoints                    │
                                │ Headers                      │
                                └──────────────────────────────┘
```

## Composer pill

Keep the existing compact target-pill pattern.

For a reasoning-capable model:

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Message…                                                               │
│                                                                        │
│  ＋    [ OpenAI · GPT-5.6 · High ▾ ]                         [ ↑ ]     │
└────────────────────────────────────────────────────────────────────────┘
```

For a non-reasoning model:

```text
[ OpenAI · GPT-4.1 ▾ ]
```

For a custom provider connection:

```text
[ LM Studio · Qwen3-30B · High ▾ ]
```

When horizontal space is constrained, provider name is the first piece of information that may be omitted:

```text
[ Sonnet 4.6 · High ▾ ]
```

Priority order for the pill is:

1. model name
2. effort, when applicable
3. provider / connection name

## Quick-switcher popover

Recommended layout:

```text
                          ┌─────────────────────────────────────────┐
                          │ Switch Model                            │
                          │                                         │
                          │ [OpenAI] [Anthropic] [Gemini] [More…]  │
                          │                                         │
                          │ 🔍 Search models...                     │
                          │                                         │
                          │ ★ GPT-5.6                         ✓     │
                          │   gpt-5.6                               │
                          │                                         │
                          │ ★ GPT-5.6 Mini                          │
                          │   gpt-5.6-mini                          │
                          │                                         │
                          │   GPT-5.5                               │
                          │   gpt-5.5                               │
                          │                                         │
                          │ ─────────────────────────────────────── │
                          │ Thinking                                │
                          │ [Off] [Min] [Low] [Med] [High] [Max]   │
                          │                                         │
                          │ ─────────────────────────────────────── │
                          │ ⚙ Manage AI Providers…                  │
                          └─────────────────────────────────────────┘
                                              ▲
┌────────────────────────────────────────────────────────────────────────┐
│ Message…                                                               │
│                                                                        │
│  ＋    [ OpenAI · GPT-5.6 · High ▾ ]                         [ ↑ ]     │
└────────────────────────────────────────────────────────────────────────┘
```

## Provider section

Use horizontally arranged connection chips rather than a permanent provider sidebar.

Example:

```text
PROVIDER

[ ◉ OpenAI ] [ A Claude ] [ ✦ Gemini ] [ ◇ OpenRouter ]
```

These chips represent **provider connections / accounts**, not only provider kinds.

If multiple connections use the same provider, distinguish them by connection label:

```text
[ ◉ OpenAI ]
   Personal

[ ◉ OpenAI ]
   Work
```

### Provider visibility rules

The quick switcher should normally show only ready provider connections.

Connections that are:

- disabled
- missing credentials
- missing an available model

belong in the AI Providers management workspace rather than the fast picker.

Selecting a provider connection changes the model list to that account's available models.

Provider selection by itself does not need to persist until a model is selected.

## Model section

The model list is optimized for choosing, not managing.

```text
MODELS

🔍 Search models...

★ Claude Sonnet 4.6                          ✓
  claude-sonnet-4-6

★ Claude Opus 4.6
  claude-opus-4-6

  Claude Haiku 4.5
  claude-haiku-4-5
```

Use the existing provider model ordering:

1. favorites first
2. available before unavailable
3. alphabetical by display name

### Model-list rules

The quick switcher should support:

- search by display name
- search by model ID
- visible selected-state checkmark
- immediate model selection

The quick switcher should **not** expose:

- favorite / unfavorite controls
- hide / unhide controls
- model discovery refresh
- manual model creation
- default-model management

Those remain in:

```text
AI Providers
    → Provider
        → Models
```

This makes model favorites useful as a speed feature for the composer without duplicating management UI.

## Immediate application

There is no Done button.

Selecting a model should immediately apply the resulting chat target.

For an existing conversation:

```text
choose provider/model/effort
        ↓
MacChatTarget
        ↓
chats.applyTarget(...)
        ↓
conversation target updates
```

For a fresh chat:

```text
choose provider/model/effort
        ↓
MacChatTarget
        ↓
newChatTarget updates
```

The popover may remain open after a model selection so the user can adjust effort immediately. It should dismiss naturally when the user clicks outside it or explicitly closes it.

## Thinking / reasoning effort

Reasoning should be a direct selector rather than a toggle plus secondary picker.

Recommended control:

```text
THINKING

[ Off ] [ Min ] [ Low ] [ Medium ] [ High ] [ Max ]
```

This makes changing effort one click.

### Unsupported models

When the selected model does not support reasoning, hide the Thinking section entirely.

This keeps the quick switcher compact and removes irrelevant controls.

### Reasoning state behavior

The picker should preserve user intent while browsing providers/models.

Recommended logic:

```text
if selected model does not support reasoning
    → reasoning = Off

else if user explicitly changed effort during this popover session
    → preserve the user's staged effort

else
    → seed from the provider/model reasoning default
```

Carry forward the existing iOS concept of tracking whether reasoning was explicitly touched during the current picker session so provider browsing does not unexpectedly overwrite the user's choice.

## Manage AI Providers handoff

The footer should provide one clear escape hatch into the full provider-management surface:

```text
────────────────────────────────────────
⚙ Manage AI Providers…
```

Selecting it should:

1. close the quick-switcher popover
2. open the existing AI Providers utility workspace

The composer switcher must not duplicate credential, endpoint, discovery, header, or model-management features.

## Empty / invalid states

### No configured target

Keep the current composer behavior conceptually:

```text
[ Set Up Provider ]
```

Clicking it should open AI Providers rather than an empty quick switcher.

### Target becomes invalid

If the currently selected account/model is deleted, disabled, hidden in a way that makes it unusable, or otherwise invalid, rely on the existing target-validation / preferred-target behavior and surface a valid fallback where possible.

The quick switcher itself should only present selectable ready targets.

## Search behavior

Search is scoped to models within the currently selected provider connection.

Matching should remain case-insensitive against:

- model display name
- model ID

Do not search provider management metadata from this field.

## Keyboard behavior

The popover should feel native for keyboard-heavy Mac use.

Recommended behavior:

- opening the switcher may focus model search
- Up / Down moves through visible model rows
- Return selects the highlighted model
- Escape closes the popover
- provider chips remain reachable by keyboard focus
- effort segments remain keyboard accessible

A future keyboard shortcut could open the switcher directly, but this is not required for the first implementation.

## Optional phase 2: Recent targets

A later optimization may add recent complete targets above the model list.

Example:

```text
RECENT

[ GPT-5.6 · High ]   [ Sonnet 4.6 · High ]
[ Gemini 3 Pro · Med ]
```

A recent target represents the full selection:

```text
provider account + model + reasoning effort
```

This would make a common cross-provider switch a two-click action:

```text
click composer pill
→ click recent target
```

This is intentionally deferred because it introduces target-history persistence. Favorites already provide most of the immediate speed benefit using existing data.

## Relationship to existing architecture

The redesign should reuse existing target/provider APIs rather than create a parallel state system.

Relevant existing concepts:

- `MacChatTarget`
- `MacProviderModel.accounts`
- `MacProviderModel.models(for:)`
- `MacProviderModel.isReady(_:)`
- `MacProviderModel.supportsReasoning(accountID:modelID:)`
- `MacProviderModel.reasoningDefault(for:)`
- `MacProviderModel.preferredTarget()`
- `MacChatSessionModel.target(for:)`
- `MacChatSessionModel.applyTarget(_:conversationID:)`
- `MacChatSessionModel.newChatTarget`

The underlying storage and conversation-target persistence already support the proposed UI.

## Implementation boundary

The first implementation should be a presentation refactor, not a provider/storage migration.

Suggested first implementation scope:

1. replace the composer target-picker sheet with an anchored popover
2. provider connection chip strip
3. searchable favorites-first model list
4. direct effort selector
5. immediate target application
6. `Manage AI Providers…` handoff
7. accessibility and keyboard navigation
8. preserve all current validation and target-persistence behavior

Do not add recent-target persistence in the initial implementation.

## Non-goals

This design does not change:

- provider account storage
- Keychain credential storage
- provider discovery
- model visibility/favorite persistence
- project provider/model defaults
- conversation target persistence
- OpenRouter routing behavior
- provider-management information architecture

It only redesigns the composer-facing interaction for rapidly choosing provider, model, and effort.
