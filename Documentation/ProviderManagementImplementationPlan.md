# Provider Management Redesign — Implementation Plan

Phased implementation of `Documentation/ProviderManagementRedesign.md`. Each phase compiles and behaves correctly on its own, so it can land and be verified before the next begins. Phases 1–2 rewire the core without changing any screen; 3–5 replace the UI; 6 is cleanup.

User-visible behavior does not change until Phase 4 (the flat list replacing the wizard). Everything before that is invisible plumbing with one deliberate exception noted in Phase 2.

## Phase 1 — `ProviderKind` core + migration

**Goal:** the enum exists, accounts carry it, the runtime switches over it. No UI changes.

### Core (`Sources/BYOKchatProviderCore`)

1. Add `ProviderKind.swift`:
   - `enum ProviderKind: String, Codable, CaseIterable, Sendable` — `anthropic, openai, gemini, deepSeek, openRouter, nvidia, openAICompatible`.
   - `AuthSpec` (`.bearer | .header(String) | .none | .userChoice`), `PathSpec` (`.fixed(chat:models:) | .userEditable`), `LogoSpec` (`.brand(String) | .monogram(Character)`).
   - Spec extension: `displayName`, `defaultEndpoint: URL?`, `apiFamily`, `auth`, `paths`, `supportsDiscovery`, `logo`, `reasoningDefault`, `contextWindowKind`, `extraCredentialFields` (openRouter: appTitle/httpReferer).
   - Port values from `BuiltInProviders` definitions verbatim — this is a transcription of existing constants, not a behavior change. Keep `BuiltInProviders` ID constants as the rawValue source of truth (`ProviderKind(rawValue:)` for known IDs, `.openAICompatible` otherwise).
2. Extend `ProviderAccount` with `var kind: ProviderKind` and, for `openAICompatible` only, the definition-folded fields: `chatCompletionsPath: String?`, `modelsPath: String?`, `authChoice: AuthSpec?`. Mark optional-with-default so decoding of new files is explicit and decoding of old files is handled by the migration (step 4), not by silent defaults.
3. Reduce `ProviderDefinition` usage to a derived value: add `ProviderAccount.definition` (computed) and `ProviderKind.definition(displayName:)` for the `openAICompatible` case, feeding the existing adapters. `ProviderRegistry` and `BuiltInProviders` stay in place this phase — adapters still consume `ProviderDefinition`.
4. Add `ProviderWorkspaceMigration`:
   - Load: if `schemaVersion == 1` and accounts lack `kind`, map `providerID` → kind (known IDs) or `.openAICompatible` (fold the matching custom definition's base URL/auth/paths into each referencing account), bump a new marker field, rewrite the file.
   - Custom definitions with zero referencing accounts are dropped.
   - Files already migrated pass through untouched (idempotent).
5. Runtime/adapter selection: `ProviderRuntime.adapter(providerID:)` → `adapter(for account:)` switching on `account.kind` (via `apiFamily`). `ProviderAccountManager.resolvedAccount` keeps working; add `resolvedAccount.kind`.

### App (`BYOKchat`)

6. `ProviderManagementModel.load()` calls the migration before `workspace.load()`.
7. No view changes. `provider(for:)` keeps returning definitions for existing UI.

**Verify:** fresh install, migrated v1 file, custom-provider file with shared definitions (two accounts → two independent folded copies), zero-account custom definition dropped. Export/import round-trip of the migrated file.

## Phase 2 — Read-only snapshot + single default resolution

**Goal:** one default rule, no writes on read. Consumers adopt it. One intentional behavior change (below).

### Core

1. Add to `ProviderWorkspaceStore`:
   ```swift
   func resolvedDefaultAccountID(
     requiresCredential: (ProviderID) -> Bool,
     hasCredential: (ProviderAccountID) -> Bool
   ) -> ProviderAccountID?
   ```
   Pure. Fallback: stored default if usable → first ready → first enabled → first → nil. No persistence.
2. `deleteAccount` keeps its existing default reassignment (the only implicit default rewrite).

### Model (`ProviderManagementModel`)

3. `reloadSnapshot()` becomes read-only: delete `ensureDefaultModelsExist()`, the repair loop, and the inline default-model re-add in `createConnection`. Snapshot = read + compute `defaultAccountID` via the resolver + presentation order.
4. Expose `isReady(_ account:)` (the existing `connectionIsReady`) and `resolvedDefaultAccount: ProviderAccount?`.
5. Readiness display for not-ready accounts: keep `connectionStatus` as the single predicate source.

### Chat consumers

6. `ChatManagementModel`: inject `resolveDefaultAccountID: () -> ProviderAccountID?` from `AppModel` (wired to the provider model's resolved value). `createConversation` uses it instead of `providerWorkspace.defaultAccountID()` + `accounts[0]`.
7. `ChatView+Content`: `defaultAccount` / `isConnectionReady` / `readiness` rebuilt on the model's `resolvedDefaultAccount` + `isReady`.
8. Picker fallbacks — add the missing `isAvailable` filter (**the one intentional behavior fix**):
   - `ComposerTargetPickerView.swift:130-131`
   - `NewChatInputComposer.swift:154-155`
   - `ConversationTargetView.swift:75-76`

**Behavior change:** a default model that disappears from discovery is no longer silently re-added as a manual model; it stays stored-but-unavailable and chat falls back in memory. A disabled account can no longer be persisted as the default by snapshot repair.

**Verify:** favorite/hide toggle does no Keychain reads or writes; deleting the default account reassigns the stored default; fresh-chat creation, fresh-composer chip, and the list footer all agree on the default.

## Phase 3 — Unified editor + scoped update API

**Goal:** `ConnectionEditorView` exists for create + edit; nothing else is replaced yet (old screens keep working).

### Model

1. Scoped update on `ProviderManagementModel`:
   ```swift
   func updateAccount(
     accountID: ProviderAccountID,
     label: String? = nil,
     newCredential: String? = nil,     // non-nil non-empty = replace
     baseURLString: String? = nil,     // "" = clear override
     headers: [String: String]? = nil,
     metadata: [String: String]? = nil
   ) async -> Bool
   ```
   Fetches the current account from the workspace by ID, applies non-nil fields only, validates, upserts, reloads. No captured-struct writes.
2. `createConnection` signature absorbs definition-folded fields for `openAICompatible` (endpoint required, auth choice, paths) and auto-names on empty label: `provider.displayName`, next integer on collision.

### View

3. New `Features/Providers/ConnectionEditorView.swift`:
   - Create + edit modes, fields conditioned by `kind` per the doc's field table (`openAICompatible` create-only auth/paths blocks, openRouter app/referer, `Fetch Models` gated on `supportsDiscovery` + key present).
   - Create: provider menu (built-ins + `openAICompatible` "New provider…" inline section), everything in `@State`, single Save commit → `createConnection` → auto `testConnection` (failure = alert, account kept).
   - Edit: provider row locked, endpoint pre-filled with override-or-default, key write-only with Replace reveal, scoped `updateAccount`, dirty-state confirm on cancel.
   - Name under Advanced, placeholder = auto-name, empty = auto-name.
4. Provider logo rendering per `LogoSpec` (brand asset fallback monogram); wire into editor + existing rows.
5. Existing screens are untouched this phase.

**Verify:** create each kind (incl. `openAICompatible` with HTTP private LAN), edit every field in isolation while watching the others survive (regression for the stale-struct clobber), cancel create leaves zero accounts, app-kill mid-create leaves zero accounts.

## Phase 4 — Flat list + delete old screens + setup-from-chat

**Goal:** the new surface ships; old screens are deleted.

1. Rewrite `ConnectionsView` → `ProvidersView` (flat, one row per account, no sections): row = `LogoSpec` logo, provider-derived label, default model or status text, status dot; footer "New chats use …"; sort provider-then-label. Delete default reordering in `reloadSnapshot` presentation (keep sort provider/label).
2. Row tap → `ConnectionEditorView` (edit mode). `+` → create mode. Repair deep-links: chip states push the editor with `focus: .apiKey` or `.model` (new init parameter).
3. Delete: `ConnectionFlowView`, `ConnectionDetailView`, `ConnectionNameEditorView`, `ConnectionCredentialEditorView`, `ConnectionAdvancedEditorView`, `CustomProviderEditorView` (surface), `CustomProviderManagementView`, `ConnectionSetupModelPickerView`, `ConnectionDetailButton`/`ConnectionActionLabel` (unused after), `initialProviderID` plumbing.
4. Setup-from-chat: `ChatView.swift:439-445` — finishing setup dismisses back to the now-ready composer; `onConnectionReady` and the `{ openSettings() }` closure are deleted. Completion title: "Done".
5. Pro gating moves to `+` in `ProvidersView` (`BYOKProAccess.canCreateProviderAccount` unchanged).

**Verify:** every journey from the redesign doc (first launch, repair, everyday switch, second key, custom); no orphan accounts possible from any cancel path; "Personal"-label migration renders provider names.

## Phase 5 — Shared model/effort picker

**Goal:** one picker component; the chip deep-links.

1. New `Features/Chats/TargetPickerView.swift` per the redesign doc: account strip (flat, one avatar per account, non-ready last with status + Fix), searchable favorites-first model list, reasoning segments, staging/commit rules exactly as specced (model tap = commit+dismiss; avatar/effort = stage; Done = commit; swipe = discard).
2. Reuse as:
   - Composer chip picker (fresh + existing) — replaces `ComposerTargetPickerView` + `ConversationTargetView`'s picker body.
   - Editor default-model field (no strip/reasoning).
   - Models management (favorites/hide/search + Add Manual) — replaces `ConnectionModelsView`.
3. Effort semantics: Off/Auto/Low/Med/High per the doc's table; Auto = per-provider `reasoningDefault`; re-derive Auto when a tapped model lacks reasoning support and staging was a concrete level.
4. Chip: `[A] Anthropic · Opus 5 · High` per the doc; readiness deep-links from Phase 4 step 2 drive it.

**Verify:** staging never writes until commit; existing-chat commit is exactly one `updateTarget`; effort survives model switches; editor + management reuse shows correct subsets.

## Phase 6 — Dead machinery removal

**Goal:** final sweep, mechanical.

1. Delete from core: `isSeed`, `lastSeenAt`, `ProviderWorkspaceState.tombstones` + its write/prune/migration line + `ImportValidation.swift:117` reference + fixture usages; `providerDefaultAccountIDs`, `setDefaultAccount(_:for:)`, `defaultAccountID(for:)`; `ProviderBehaviorID`, persisted `ProviderDefinition`/`ProviderRegistry`/`BuiltInProviders` catalog validation once Phase 1's `ProviderAccount.definition` is the only consumer. `SyncTombstonePolicy` stays (four other stores use it).
2. Delete from model: `createAccount` duplicate, void `testConnection`/`refreshModels` variants, `statusMessage`, `ProviderManagementModel+LocalProvider.swift`.
3. Delete from UI: remaining header-parser duplicates (one strict parser in `ConnectionComponents`), duplicate OpenRouter metadata assembly (one helper per `extraCredentialFields`), `providerSymbol` mapping (replaced by `LogoSpec` in Phase 3).
4. Export/import: confirm the post-deletion workspace state round-trips and `ImportValidation` matches the slimmed schema.

**Verify:** full-project grep for deleted symbols returns nothing; export → wipe → import restores accounts (minus secrets), names, models, favorites.

## Dependencies and risk

```
P1 kind core ──► P2 read-only snapshot ──► P3 editor ──► P4 flat list ──► P5 picker ──► P6 cleanup
   migration is     behavior change:           biggest new    deletes wizard;    new component;    mechanical,
   the risk         defaults no longer         surface        first-run path     chip rewiring     no behavior
                    self-healed                                                  changes
```

- **Phase 1** carries the only data-format risk: the migration. Keep it idempotent and additive; the old file layout must round-trip through export/import before Phase 2 starts.
- **Phase 2** is the only phase with an intentional behavior change; call it out in the changelog.
- **Phase 4** is the only user-visible cutover; ship it only after Phase 3's editor is verified on all kinds.
- **Phase 5** can be split (picker component → chip rewiring) if it grows.

Out of scope (unchanged from the redesign doc): OAuth, usage/balance display, import re-credential flow, model pruning policy, per-operation busy indicators.
