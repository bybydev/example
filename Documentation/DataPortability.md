# Data Portability

BYOKchat stores conversations, provider configuration, and remote MCP configuration locally. Export/import workflows are explicitly versioned and never export credentials.

## Full backup

A full backup contains:

- custom provider definitions
- non-secret provider account configuration
- model catalog state
- conversations and messages
- persisted image/file attachments
- structured tool-call rounds
- per-conversation provider/model settings
- remote MCP server configuration
- cached MCP discovery snapshots/tool schemas
- the default system prompt

The backup never contains provider API keys or remote MCP credentials stored in Keychain.

MCP data is an optional field in backup schema v1. This keeps schema-v1 backups produced before MCP support backward compatible: they decode with no MCP workspace and can still be restored.

## Import strategies

- **Merge, keep existing** preserves local records when an imported ID already exists and adds new records.
- **Replace existing** replaces provider, conversation, and MCP workspaces with the imported snapshot.

For an older full backup with no MCP field, replace restore clears the current MCP workspace rather than silently retaining unrelated newer server configuration.

Replace import removes credentials for affected provider accounts and MCP servers. Credentials must be entered again after restore.

Imports validate schema versions, duplicate IDs, provider/account references, endpoint policy, protected headers, model ownership, conversation target accounts, attachment/tool-trace integrity, and MCP workspace references before mutation. If a later import step fails, the previous provider, conversation, and MCP workspaces are restored best-effort.

## MCP configuration

MCP workspace persistence contains only non-secret configuration and cached discovery data:

- server ID/name/HTTPS endpoint
- authentication strategy metadata, but never the secret itself
- optional non-secret request headers
- enable/disable state
- discovered server/protocol metadata
- cached tool schemas and expiry metadata

Bearer tokens and custom authentication-header values live only in the dedicated MCP Keychain vault.

## Conversation Markdown

A conversation can be exported as Markdown with:

- title and export date
- provider, account, and model
- system prompt
- user and assistant messages
- expandable reasoning sections
- non-complete message status

Attachment metadata and structured tool-round details are not yet expanded in Markdown export even though they are preserved in the full JSON backup.

## Destructive controls

Settings provides explicit confirmation before deleting all conversations or all Keychain credentials. Delete All Credentials now covers both provider credentials and remote MCP credentials.
