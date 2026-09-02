# Provider Management Redesign

Design reference for the reworked provider management surface: one flat provider list, one unified editor, one model/effort picker, and a `ProviderKind` enum as the single source of provider behavior. This document is the plan of record; it supersedes the connection/wizard flows described in `ProviderWorkspace.md` where they disagree.

## Problem summary

The current surface is provider-speak leaking into the UI:

- A 3-page wizard commits a half-configured account on page 2, cannot go back, deletes everything on cancel, and orphans the account if the app dies mid-flow.
- "Connection" vocabulary ("Add Connection", "Start Chatting") confuses provider (the service) with provider account (a key for that service). Users think provider → model, nothing else.
- Custom providers get a second management surface and definition rows that look different from built-ins.
- Four separate places re-derive default-account and readiness rules with slightly different predicates; three pickers filter model fallbacks differently.
- Dead machinery (`isSeed`, `lastSeenAt`, per-provider default IDs, tombstones in the provider workspace, `statusMessage`, duplicate header parsers and API pairs) blurs which parts of the surface are real.

## Core concept: `ProviderKind`

The most important object is the supported-provider enum. Every provider account stores its `kind`; every provider decision is a `switch` over it.

```swift
enum ProviderKind: String, Codable, CaseIterable, Sendable {
  case anthropic, openai, gemini, deepSeek, openRouter, nvidia
  case openAICompatible        // user-defined + self-hosted — ONE case, not per-instance
}
```

A static spec extension is the only place provider policy lives:

```swift
extension ProviderKind {
  var displayName: String          // "Anthropic" … / user names openAICompatible at create
  var defaultEndpoint: URL?        // api.anthropic.com … / nil → user must type
  var apiFamily: APIFamily         // anthropic→anthropicMessages, gemini→generateContent, else openAI
  var auth: AuthSpec               // .bearer | .header("x-api-key") | .header("x-goog-api-key")
                                   //   openAICompatible → .userChoice(bearer|header|none)
  var paths: PathSpec              // .fixed(chat:"/v1/messages", models:"/v1/models")
                                   //   openAICompatible → .userEditable
  var supportsDiscovery: Bool      // false only where modelsPath is nil (nvidia today)
  var logo: LogoSpec               // .brand(asset) | .monogram(letter)
  var reasoningDefault: ReasoningOptions?  // deepSeek/anthropic .high, gemini .medium, else nil
  var contextWindowKind: ...       // anthropic/gemini inputOnly, else combined
  var extraCredentialFields: ...   // openRouter → appTitle, httpReferer
}
```

Nothing else makes provider decisions: no `isBuiltIn` flag, no `ProviderBehaviorID`, no `ProviderDefinition` persistence, no registry lookup. Adapter selection, auth-header injection, editor layout, logos, reasoning defaults, and context budgeting all condition on `kind`.

### What the enum deletes

| Today | After |
| --- | --- |
| `ProviderBehaviorID` | merged into `ProviderKind` |
| `ProviderDefinition` (persisted) | static spec in `ProviderKind` extension |
| `ProviderRegistry` (actor) | `ProviderKind.allCases` is the catalog |
| `customProviders` in workspace state | account fields (endpoint/auth/paths) |
| `synchronizeCustomProviders()` | nothing to sync |
| `upsert/deleteCustomProvider` | no definition lifecycle |
| `isBuiltIn` flag | `kind != .openAICompatible` |
| registry validation at startup | compile-time exhaustive switch |

Startup failure handling around catalog validation (`secureRecoveryFallback` and its bootstrap path) shrinks accordingly — the catalog can no longer be invalid.

## Naming and identity

Accounts stay an internal concept. Presented identity is provider-first:

- Default account label = the provider name ("Anthropic").
- Collision auto-numbers: "Anthropic 2", "Anthropic 3", …
- The user may rename in the editor's Advanced section; custom names are respected.
- The label is shown only when it differs from the provider name (or when disambiguation is needed); the chat chip shows it only when the default account is not the first of its provider.

Migration for existing installs: a stored label of "Personal" renders as the provider name (display-only fallback); the stored value is untouched until the user edits it.

## Provider logos

- Assets: `provider.anthropic`, `provider.openai`, `provider.gemini`, `provider.openrouter`, `provider.deepseek`, `provider.nvidia`.
- `logo(for:)`: brand asset when the kind has one (monochrome-adapted for dark mode); otherwise a monogram tile (first letter, tinted). `providerSymbol` SF-symbol mapping is deleted.
- Used identically in list rows, picker strip, editor header, and the chat chip.

## Surface 1 — Providers list (flat)

One row per account. No Default section, no Other section, no Custom section — one flat list, every row identical.

```
┌──────────────────────────────────────┐
│ ‹ Settings          Providers     +  │
├──────────────────────────────────────┤
│ [A] Anthropic          Opus 5    ●  >│
│ [A] Anthropic 2        Opus 5    ●  >│
│ [O] OpenRouter         ⚠ Needs key >│
│ [G] Gemini             Flash     ●  >│
│ [L] llama.box          Opus 5    ●  >│
│                                      │
│  New chats use Anthropic · Opus 5    │
└──────────────────────────────────────┘
```

- Row = logo, provider-derived label, default model of the account, status dot.
- Status text appears in place of the model when not ready ("Needs key", "Needs model", "Disabled").
- Sort: provider name, then label; built-ins and customs interleave.
- The "New chats use …" footer is the single source of truth for the default; no Default badge in rows.
- Custom provider definition editing lives inside the account editor, never as a list row.

## Surface 2 — Unified editor (create + edit, same form)

One editor for every kind of account. No separate custom-provider editor, no separate name/credential/advanced sheets, no wizard.

```
 CREATE (any provider)                        EDIT (any provider)
┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
│ Cancel        Add Connection    Save │    │ Cancel           Anthropic 2    Done │
├──────────────────────────────────────┤    ├──────────────────────────────────────┤
│ PROVIDER                             │    │  [A] Anthropic · locked              │
│ [ Ⓐ Anthropic                     ▾] │    ├──────────────────────────────────────┤
│     menu = built-ins + existing      │    │ ENDPOINT                             │
│     customs + "New provider…"        │    │ [ https://api.anthropic.com       ]  │
│                                      │    ├──────────────────────────────────────┤
│ API KEY                              │    │ API KEY                              │
│ [                               ]    │    │ ✓ Saved in Keychain      [Replace]  │
│  Where do I find my key? >           │    ├──────────────────────────────────────┤
│                                      │    │ MODELS                               │
│ AUTH            (new custom only)    │    │ [ Fetch Models ]     12 available    │
│  (•) Bearer  ( ) Header: [x-api-key] │    │ Default: [ claude-opus-5          >] │
│  ( ) None                            │    │          + Add ID · Manage  >        │
│ PATHS           (new custom only)    │    ├──────────────────────────────────────┤
│  Chat:   [/chat/completions       ]  │    │ ┌ Advanced ────────────────────────┐ │
│  Models: [/models                 ]  │    │ │ Headers: Name: Value per line    │ │
│  (built-ins hide this block — theirs │    │ │ Name:    [ Anthropic 2         ] │ │
│   are fixed by the app)              │    │ └──────────────────────────────────┘ │
│                                      │    │ ☐ Enabled        Delete              │
└──────────────────────────────────────┘    └──────────────────────────────────────┘
```

### Editor field conditioning (from the kind spec)

| Field / block | anthropic | openai | gemini | deepSeek | openRouter | nvidia | openAICompatible |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Endpoint (editable) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ required |
| Auth picker | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ create-only |
| Chat path | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ create-only |
| Models path | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ create-only |
| API key | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | per auth |
| OpenRouter app/referer | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| Fetch Models | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | if modelsPath |
| Default model picker | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Name / Headers | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

The editor view renders from `ForEach(kind.editorFields)` — fields appear by spec.

### Editor rules

- **Base URL is editable for every provider**, built-ins included. Pre-filled from the kind's default; the override is the field, not a hidden "advanced" thing.
- **Provider is locked in edit mode.** Changing provider changes auth scheme, paths, and model ID space — that is delete + recreate.
- **API key is write-only**: create = paste new; edit = empty means keep, "Replace" reveals the field. Never displays the secret.
- **Auth scheme and paths for a custom provider are shown once at create** and fixed afterwards (wire data, not user toggles).
- **Name defaults to the provider name**, placeholder shows the auto value, empty save = auto-name. Demoted under Advanced.
- **"New provider…" in the provider menu** creates the definition inline (name, endpoint, auth, paths) and drops into the same form with the provider preselected; one Save commits both.
- **Save commits once.** Create: validate → `createConnection(...)` (the only write) → auto `testConnection`; failure alerts with the account kept. Edit: scoped `updateAccount(accountID:, only changed fields)`. No account exists before Save in create mode — cancel/swipe/app-kill leaves nothing behind.
- Fetch Models is a button in the form gated on the key being present; failure is an inline warning and manual-ID entry stays available.

## Surface 3 — Model/effort picker

One sheet, three decisions, each one tap away. Same component for fresh chat and existing chat, plus reused (without account strip / reasoning) as the editor's default-model picker and models manager.

```
┌────────────────────────────────────────────────────┐
│  ── PROVIDER ────────────────────────────────────  │
│  (A)  (A)  (O)  (G)  (+)                           │
│  Anthropic 2                     ● Ready           │
│────────────────────────────────────────────────────│
│  🔍 Search                                    (♥)  │
│────────────────────────────────────────────────────│
│  FAVORITES                                         │
│   ★ Opus 5        claude-opus-5 · 1M · vision  ✓   │
│  ALL                                               │
│     Sonnet 5      claude-sonnet-5 · 1M · vision    │
│     ─ R1 ──────────────── unavailable ───────────  │
│  + Add model ID manually                           │
│────────────────────────────────────────────────────│
│  REASONING                                         │
│  [ Off ][ Auto ][ Low ][ Med ][ High ]             │
│                                                    │
│                      [ Done ]                      │
└────────────────────────────────────────────────────┘
```

- Account strip: one avatar per account (flat — two Anthropic keys are two Anthropic logos, distinguished by the label underneath). Tap = browse that account's models with its default pre-checked.
- Non-ready accounts appear last, marked with status; a broken account offers "Fix" deep-linking into the editor with the key field focused.
- Reasoning section appears only when the browsed model supports it.

### Commit rules

| Control | Action | Sheet stays open? |
| --- | --- | --- |
| account avatar | switch browsing context | yes |
| model row | commit account+model, keep effort | no — commits & dismisses |
| effort segment | stage effort (chip preview updates live) | yes |
| Done | commit whatever is staged | dismiss |
| swipe down | discard staging | — nothing was written |

One commit rule: **model tap or Done writes; everything else stages.** Existing-chat commit is a single `updateTarget` — one write, not one per tap.

### Effort semantics

| Segment | Stored as | Shown when |
| --- | --- | --- |
| Off | `reasoning.enabled = false` | model supports reasoning |
| Auto | `enabled = nil` (per-provider default: DeepSeek/Anthropic high, Gemini medium) | always when the section shows |
| Low/Med/High | `enabled = true, effort = level` | model supports reasoning |

Tapping a model whose reasoning support differs from the staged effort keeps the staging but re-derives Auto if unsupported — no dead combinations.

### Entry states

```
open picker
  ├─ fresh chat     → staged = targetOverride ?? (resolvedDefaultAccount, its default model, Auto)
  └─ existing chat  → staged = (conversation.accountID, conversation.modelID,
                               conversation.options.reasoning)
commit(selection)
  ├─ fresh     → targetOverride = selection
  └─ existing  → updateTarget(account, model, reasoning) once
```

### Chat chip

```
[A] Anthropic · Opus 5 · High        (single account of its provider)
[A] Anthropic 2 · Opus 5 · High      (when the label differs / disambiguates)
```

Tap → the picker. Broken states deep-link straight to their one-field fix:

| Readiness | Chip shows | Tap goes to |
| --- | --- | --- |
| no connection | "Set Up Connection" | editor (create mode) |
| needs API key | "Add API Key · <name>" | editor (edit mode), key focused |
| no model | "Choose Model · <name>" | picker for that account |
| ready | "<Provider> · <Model>" | picker |

## Model picker reuse matrix

| Context | Account strip | Reasoning | Commit target |
| --- | --- | --- | --- |
| Composer chip (both modes) | ✓ | ✓ | stage / updateTarget |
| Editor "Default model" field | ✗ | ✗ | writes the form field |
| Models management | ✗ | ✗ | default + favorite/hide |

## Screens deleted

ConnectionFlowView (wizard), ConnectionDetailView, ConnectionNameEditorView, ConnectionCredentialEditorView, ConnectionAdvancedEditorView, CustomProviderEditorView (as a separate surface), CustomProviderManagementView, ConnectionSetupModelPickerView (folded into the shared picker), and the Setup-from-Chat sheet that opened Settings on finish.

## Journeys

```
First launch   empty chat → editor (create, provider preselected) → Save → back to chat, ready
Repair         chip "Needs API key" → editor, key focused → paste → Done → chip "Ready"
Everyday       chip → picker (account strip + model list + effort)
Second key     + → editor → same provider, key #2 → auto-named "Anthropic 2" → second flat row
Custom         + → provider menu → "New provider…" → inline fields → same form → Save
```

## Runtime behavior conditioning

| Decision | `switch kind` |
| --- | --- |
| wire adapter | anthropic → AnthropicMessages, gemini → GeminiGenerateContent, else OpenAICompatible |
| auth header | kind.auth: x-api-key / x-goog-api-key / Authorization / account's chosen header |
| reasoning default | .high / .high / .medium / nil per spec |
| router metadata | openRouter → inject X-Title, HTTP-Referer |
| model context budget | spec.contextWindowKind |
| discovery behavior | spec.supportsDiscovery |

## Internal model changes

- `reloadSnapshot()` becomes read-only: no repair writes, no `ensureDefaultModelsExist`, no default-model re-adds. Repair happens in explicit mutation paths only.
- One default-resolution rule, one place: stored default if usable → first ready → first enabled → first. Derived defaults are never persisted; the stored default changes only via explicit set/delete.
- Scoped update API: `updateAccount(accountID:label:newCredential:baseURLString:headers:metadata:)` — the model fetches current state by ID and applies only non-nil fields; callers never pass captured account structs.
- Chat-side consumers (`ChatManagementModel`, `ChatView`, all three target pickers) use the same resolution and `isReady` predicate; model fallbacks filter `isAvailable`.
- Dead machinery removed: `isSeed`, `lastSeenAt`, provider-workspace `tombstones` (SyncTombstonePolicy stays — four other stores use it), per-provider default IDs, `statusMessage`, duplicate header parsers, void/`Result` API pairs collapsed, `initialProviderID`.

## Migration

One-time load transform (pre-release, schema evolving in place):

```
old account { providerID: "anthropic" }     → kind: .anthropic, fields carry over
old account { providerID: <custom def id> } → kind: .openAICompatible
  + fold its definition's endpoint/auth/paths INTO the account (self-contained;
    two accounts sharing a definition each get their own copy)
old custom definition with zero accounts    → dropped (nothing referenced it)
```

"Personal" labels migrate per the naming rule above (display-only fallback).

## Implementation order

1. `ProviderKind` + spec extension; migrate the providers file; adapters and runtime switch over the kind.
2. Read-only snapshot + single default resolution; chat consumers adopt it; fix the unavailable-model fallback in the three pickers.
3. Unified `ConnectionEditorView` (create + edit) with kind-conditioned fields; scoped update API underneath.
4. Flat Providers list replaces ConnectionsView; delete the wizard and the per-field editor sheets; fix setup-from-chat.
5. Shared model/effort picker; chip readiness deep-links.
6. Dead machinery removal (final sweep).
