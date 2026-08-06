# Provider Workspace

BYOKchat keeps provider configuration and credentials in separate storage systems.

## Non-secret workspace

`ProviderWorkspaceStore` owns a versioned JSON document containing:

- custom provider definitions
- provider accounts and labels
- endpoint overrides
- safe non-secret headers
- default accounts and models
- discovered and manual model metadata
- favorite, hidden, and availability state

The workspace can be exported or imported because it contains no credentials.

## Credential vault

`CredentialVault` stores secrets by stable account ID and secret-field ID. On Apple platforms, `KeychainCredentialVault` uses device-only Keychain accessibility. Account labels are never used as credential keys, so renaming an account does not affect its saved secrets.

Deleting an account removes its complete credential namespace before removing its non-secret workspace state.

## Runtime resolution

A request resolves through:

```text
ProviderAccount
  -> ProviderDefinition
  -> CredentialVault
  -> ResolvedProviderAccount
  -> API-family adapter
```

Conversation and UI layers never receive the saved credential after account configuration. The resolved account exists only at the provider-runtime boundary.

## Model merge rules

Provider refreshes merge rather than replace:

- favorites are preserved
- hidden state is preserved
- manual models are preserved
- local metadata fills missing remote metadata
- remote models missing from a later refresh are marked unavailable
- missing models are not immediately deleted
