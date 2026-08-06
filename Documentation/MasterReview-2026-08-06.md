# BYOKchat `master` branch review

**Review date:** 2026-08-06  
**Reviewed commit:** `feca1e6b2f518e49b8a2f157e9b9569d1214d41c`  
**Scope:** iOS application layer, provider core package, persistence, credential handling, streaming, import/export, and tests.

## Executive summary

The codebase has a solid overall separation between UI state, provider runtime, conversation runtime, persistence actors, and the Keychain-backed credential vault. The test suite also covers several difficult lifecycle cases, including interrupted generations, cancellation, history editing, model refreshes, and Swift 6 concurrency behavior.

The review found **seven actionable issues**:

- **1 high-severity security issue** in cleartext local-provider URL validation.
- **3 high-severity reliability or recovery issues** involving stream finalization, malformed imports, and failed workspace loading.
- **3 medium-severity data-integrity or request-sizing issues** involving credential deletion, provider-only replacement imports, and context budgeting.

**Release recommendation:** fix findings 001–004 before shipping the local-HTTP or import workflows broadly. Findings 005–007 should follow before treating backup/restore and long-context conversations as production-safe.

## Findings overview

| ID | Severity | Area | Summary |
|---|---|---|---|
| BYOK-REV-001 | High | Security | Public hostnames beginning with `fc` or `fd` are accepted as private-network hosts and may receive API keys over cleartext HTTP. |
| BYOK-REV-002 | High | Streaming | A final JSON SSE event flushed at EOF is discarded, which can truncate output or incorrectly report a premature stream end. |
| BYOK-REV-003 | High | Import safety | Crafted backup/configuration JSON with duplicate IDs can trigger a Swift precondition failure instead of a recoverable import error. |
| BYOK-REV-004 | High | Recovery | A failed provider-workspace load permanently marks the store as loaded, preventing retry for the remainder of the process. |
| BYOK-REV-005 | Medium–High | Credentials | Account deletion and replacement imports can delete Keychain credentials before the durable workspace transition is known to have succeeded. |
| BYOK-REV-006 | Medium | Data integrity | Replacing provider configuration can leave existing conversations pointing to accounts that no longer exist. |
| BYOK-REV-007 | Medium | Context building | The newest turn and system prompt can exceed the calculated model input budget, causing avoidable provider-side context errors. |

---

## BYOK-REV-001 — Public `fc*` / `fd*` hosts pass private-network validation

**Severity:** High  
**Location:** `Sources/BYOKchatProviderCore/HTTPTransport.swift`, `ProviderHTTP.isPrivateNetworkHost(_:)`

### Observation

The private-host check contains this prefix test:

```swift
if value.hasPrefix("fe80:") || value.hasPrefix("fc") || value.hasPrefix("fd") {
  return true
}
```

The `fc` and `fd` checks are intended for IPv6 unique-local addresses, but they are applied to every host string. A normal public hostname such as `fcexample.com` or `fdexample.com` therefore passes as private.

When a custom provider enables local HTTP, a URL such as `http://fcexample.com/v1` is accepted. Requests may then attach a bearer token or custom authentication header to a cleartext connection outside the private network.

### Impact

- API keys can be transmitted without TLS to a public host.
- The UI presents the endpoint as an explicitly allowed local provider even though it is not local.
- This bypasses the security boundary established by `allowsLocalHTTP`.

### Recommendation

Parse IP literals before applying IPv4/IPv6 range rules. Only treat `fc00::/7`, `fe80::/10`, loopback, and approved IPv4 private/link-local ranges as private when the host is actually an IP address. Handle `localhost` and `.local` names separately.

Avoid classifying arbitrary single-label or prefix-matching DNS names as private unless that behavior is explicitly required and clearly disclosed.

### Regression tests

- Reject `http://fcexample.com/v1` when local HTTP is enabled.
- Reject `http://fdexample.com/v1` when local HTTP is enabled.
- Accept actual ULA literals such as `http://[fd00::1]:11434/v1`.
- Accept link-local IPv6 only when correctly represented as an IPv6 literal.
- Continue accepting loopback and RFC1918 IPv4 addresses.

---

## BYOK-REV-002 — EOF-flushed SSE JSON event is ignored

**Severity:** High  
**Location:** `Sources/BYOKchatProviderCore/OpenAICompatibleAdapter.swift`, streaming completion path

### Observation

Events produced while chunks arrive are fully decoded. At EOF, however, the adapter only examines events returned by `SSEDecoder.finish()` for `[DONE]`:

```swift
for event in try decoder.finish() where event.data == "[DONE]" {
  completed = true
}
```

`SSEDecoder.finish()` deliberately flushes an unterminated final event. If the provider closes the stream immediately after a final JSON event without a trailing blank line, that event is discarded. Its final content, reasoning, usage, model, response ID, and `finish_reason` are never processed.

### Impact

- The last output fragment may disappear.
- Usage and finish metadata can be lost.
- A valid provider response can become `prematureStreamEnd`.
- Persisted conversation text can be shorter than what the provider sent.

### Recommendation

Extract event processing into one shared function and pass both `decoder.append(_:)` and `decoder.finish()` results through it. `[DONE]`, provider errors, usage, deltas, and finish reasons should have identical handling regardless of whether the event was terminated by a blank line or EOF.

### Regression tests

- Final JSON event without a trailing newline or blank line.
- Final JSON event with `finish_reason` but no `[DONE]`.
- Final usage-only event flushed at EOF.
- Final reasoning/content delta followed immediately by connection close.
- `[DONE]` flushed at EOF.

---

## BYOK-REV-003 — Malformed imports can cause precondition traps

**Severity:** High  
**Locations:**

- `Sources/BYOKchatProviderCore/DataPortability.swift`
- `Sources/BYOKchatProviderCore/ProviderWorkspace.swift`

### Observation

Imported JSON is decoded into arrays but is not comprehensively validated before dictionary construction or persistence.

For replacement backup validation, account records are converted with:

```swift
Dictionary(uniqueKeysWithValues: backup.providerWorkspace.accounts.map { ($0.id, $0) })
```

A backup containing duplicate account IDs causes `Dictionary(uniqueKeysWithValues:)` to trap. The process terminates instead of returning a `ProviderError`.

Related imported structures also permit duplicate provider, account, model-record, conversation, or message IDs. Imported custom provider definitions are not all revalidated through `ProviderRegistry.validate(_:)`, and model refresh later constructs a dictionary from stored model records, creating another possible trap after a malformed import has been accepted.

### Impact

- A user-selected JSON file can crash the app.
- Invalid references and duplicate IDs can enter persisted state.
- The crash may occur during a later action, making the original import difficult to diagnose.

### Recommendation

Add a complete, non-mutating validation pass before applying any import:

1. Reject duplicate IDs for providers, accounts, account/model records, conversations, and messages.
2. Validate every custom provider with `ProviderRegistry.validate(_:)`.
3. Validate account-to-provider and model-record-to-account references.
4. Validate global and provider-specific default account IDs.
5. Validate conversation targets against the effective account graph.
6. Return a typed `ProviderError.importConflict` with a user-readable description.

Use dictionary construction that detects duplicates explicitly rather than relying on a precondition-enforcing initializer.

### Regression tests

- Duplicate account IDs in a full backup.
- Duplicate model records for the same account/model pair.
- Duplicate custom provider IDs.
- Invalid default-account references.
- Invalid account/provider combinations.
- Duplicate conversation and message IDs.
- Invalid custom provider URL or authentication header in imported configuration.

---

## BYOK-REV-004 — Failed provider-workspace load cannot be retried

**Severity:** High  
**Location:** `Sources/BYOKchatProviderCore/ProviderWorkspace.swift`, `ProviderWorkspaceStore.load()`

### Observation

The method sets `hasLoaded` in a `defer` before reading and decoding storage:

```swift
guard !hasLoaded else { return }
defer { hasLoaded = true }
guard let data = try await persistence.loadData() else { return }
let decoded = try JSONDecoder.provider.decode(ProviderWorkspaceState.self, from: data)
```

`defer` runs even when file reading, decoding, or schema validation throws. The state remains at its empty default, but every subsequent `load()` call returns immediately.

At the application layer, the load error is converted to an error message and startup continues. The process can therefore remain in an apparently empty provider state until relaunch, even if the failure was transient.

### Impact

- A temporary read error cannot recover in the same session.
- Existing accounts can appear missing.
- Retrying through refresh or another screen does not reload storage.
- The empty state can be mistaken for successful initialization.

### Recommendation

Set `hasLoaded = true` only after a successful no-file path or a successful decode/validation assignment. Leave it `false` after errors so callers can retry. Consider exposing a distinct load state (`idle`, `loading`, `loaded`, `failed`) so application startup does not treat failure as completed initialization.

### Regression tests

- Persistence throws once, then succeeds; the second `load()` restores data.
- Invalid JSON fails without marking the store loaded.
- Unsupported schema fails without marking the store loaded.
- Empty storage marks the store loaded successfully.

---

## BYOK-REV-005 — Credential deletion is not transactionally aligned with workspace persistence

**Severity:** Medium–High  
**Locations:**

- `Sources/BYOKchatProviderCore/ProviderRuntime.swift`, `ProviderAccountManager.deleteAccount(_:)`
- `Sources/BYOKchatProviderCore/DataPortability.swift`, replacement import
- `BYOKchat/App/DataPortabilityModel.swift`, provider-configuration replacement

### Observation

Account deletion removes the Keychain entry before deleting and persisting the account:

```swift
try await vault.removeAll(accountID: id)
try await workspace.deleteAccount(id)
```

If workspace persistence fails, the account remains configured but its credential is already gone.

Replacement imports have a similar partial-failure problem. Workspace state can be rolled back from exported JSON, but credentials removed from Keychain cannot be restored. `removeCredentials(accountIDs:)` also processes entries sequentially, so a failure can leave an unknown subset removed.

### Impact

- An operation reported as failed may still irreversibly delete API keys.
- Rollback can restore configuration while silently leaving accounts unauthenticated.
- Users may lose multiple credentials during a replacement import.

### Recommendation

Treat workspace persistence as the commit point. Persist the account/configuration transition first, then delete credentials that are definitively orphaned. Report cleanup failures separately and retain enough information to retry cleanup safely.

For replacement imports, avoid claiming transactional rollback for credentials. Validate first, commit durable configuration, then perform explicit post-commit Keychain cleanup with per-account results.

### Regression tests

- Workspace delete fails after account selection; credential remains available.
- Keychain cleanup fails for one of several accounts; result identifies the failed account and remains retryable.
- Replacement import persistence fails; no credential is removed.
- Post-commit cleanup failure does not roll back into a misleading mixed state.

---

## BYOK-REV-006 — Provider-only replacement can orphan conversations

**Severity:** Medium  
**Location:** `BYOKchat/App/DataPortabilityModel.swift`, `importProviderConfiguration(from:strategy:)`

### Observation

Full-backup import validates conversation targets against the effective provider-account graph. Provider-configuration import does not perform an equivalent check.

With `.replaceExisting`, the app can replace all provider accounts while retaining all conversations. Existing conversations may then reference account IDs that were removed by the import.

### Impact

- Existing chats remain visible but fail when sending, regenerating, or changing target.
- The failure appears later as an account/provider lookup error rather than as an import conflict.
- A configuration-only operation can silently make the conversation database unusable.

### Recommendation

Before replacement, compute the account IDs referenced by existing conversations and compare them with the incoming effective account set. Either:

- block the import with a clear list/count of affected conversations;
- preserve referenced accounts;
- require explicit remapping; or
- require the user to delete affected conversations first.

### Regression tests

- Replacing providers while a conversation references a removed account is rejected.
- Replacement succeeds when every referenced account remains available.
- Merge import preserves current references.
- Disabled accounts and custom-provider removal are handled explicitly.

---

## BYOK-REV-007 — Context builder can exceed its own input budget

**Severity:** Medium  
**Location:** `Sources/BYOKchatProviderCore/ChatContextBuilder.swift`

### Observation

The system prompt is always included. The newest turn is also always selected because the first reversed turn bypasses the budget check:

```swift
if selected.isEmpty || used + cost <= inputBudget {
  selected.append(turn)
  used += cost
}
```

An oversized system prompt, latest user message, or latest turn can therefore produce `estimatedInputTokens` greater than `inputBudget`. The request is sent anyway and relies on the provider to reject or truncate it.

### Impact

- Long prompts can fail with context-length errors even though the app already knows the model budget.
- A very large configured output reserve can leave almost no input budget.
- Behavior differs across providers depending on their server-side truncation policy.

### Recommendation

Make the over-budget case explicit. Before network dispatch, either:

- return a typed local error explaining which component is too large;
- safely truncate the latest user content with a visible warning; or
- reduce the requested output reserve when appropriate and approved by the user.

The final result should guarantee `estimatedInputTokens <= inputBudget` whenever a finite context window is known.

### Regression tests

- Oversized system prompt.
- Oversized latest user message.
- Latest user/assistant turn larger than the complete input budget.
- Output reserve equal to or greater than the context window.
- Exact-boundary request remains accepted.

---

## Positive observations

- Provider runtime, conversation runtime, workspace persistence, and UI state are separated cleanly.
- Mutable core stores are actors, while UI models are isolated to `MainActor`.
- The default URL session disables cookies and caching.
- Redirect handling is restricted to the same scheme, host, and effective port.
- API keys are stored separately from exported provider and conversation data.
- Streaming partial output is periodically persisted and repaired after interruption.
- The existing tests cover cancellation, uncertain completion, edit/regenerate history behavior, model refresh merging, and compatibility decoding.

## Suggested fix order

1. Fix private-network host parsing and add security regression tests.
2. Unify SSE event processing for chunk and EOF events.
3. Add full import graph validation and duplicate detection.
4. Correct provider workspace load/retry state.
5. Redesign credential cleanup around a durable commit point.
6. Validate provider-only replacement against current conversations.
7. Make oversized context handling explicit.

## Validation notes

This report is based on static inspection of `master` at the reviewed commit. No GitHub Actions workflow was started. The execution environment used for the review did not provide Xcode, so the iOS application and package tests were not built or executed as part of this report.