# Data Portability

BYOKchat stores conversations and provider configuration locally. Phase 5 adds explicit, versioned export and import workflows without exporting credentials.

## Full backup

A full backup contains:

- custom provider definitions
- non-secret provider account configuration
- model catalog state
- conversations and messages
- per-conversation provider/model settings
- the default system prompt

The backup never contains API keys or credentials stored by `CredentialVault`.

## Import strategies

- **Merge, keep existing** preserves local records when an imported ID already exists and adds new records.
- **Replace existing** replaces provider and conversation workspaces with the imported snapshot.

Replace import removes credentials for affected accounts. Credentials must be entered again after restore.

Imports validate schema versions, duplicate IDs, provider/account references, endpoint policy, protected headers, model ownership, and conversation target accounts before mutation. If a later import step fails, the previous provider and conversation workspaces are restored.

## Conversation Markdown

A conversation can be exported as Markdown with:

- title and export date
- provider, account, and model
- system prompt
- user and assistant messages
- expandable reasoning sections
- non-complete message status

## Destructive controls

Settings provides explicit confirmation before deleting all conversations or all Keychain credentials.
