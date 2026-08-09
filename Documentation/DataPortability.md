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
- per-chat enabled MCP server IDs
- per-tool Ask / Always Allow / Disabled policy
- the default system prompt

The backup never contains provider API keys or remote MCP credentials stored in Keychain.

MCP data is an optional field in backup schema v1. Per-chat MCP policy is itself optional inside the MCP workspace, so older schema-v1 backups produced before those fields existed remain decodable.

## Import strategies

- **Merge, keep existing** preserves local records when an imported ID or portable conversation fingerprint already exists and adds new records.
- **Replace existing** replaces provider, conversation, and MCP workspaces with the imported snapshot.

For an older full backup with no MCP field, replace restore clears the current MCP workspace rather than silently retaining unrelated newer server configuration.

Replace import removes credentials for affected provider accounts and MCP servers. Credentials must be entered again after restore.

Imports validate schema versions, duplicate IDs, provider/account references, endpoint policy, protected headers, model ownership, conversation target accounts, attachment/tool-trace integrity, MCP workspace references, and MCP chat-policy references before mutation. If a later import step fails, the previous provider, conversation, and MCP workspaces are restored best-effort.

## Conversation identity during restore

Conversation restore reconstructs conversations through the normal store mutation path, so an imported conversation can receive a new local `ConversationID`.

`ConversationStore.importWorkspace` therefore returns a source-to-local ID mapping. Full backup restore uses that mapping to remap per-chat MCP policy onto the effective local conversations before committing the MCP workspace.

This prevents imported Ask/Always-Allow/Disabled choices from becoming orphaned or attaching to the wrong chat.

The same restore path explicitly preserves:

- attachment bytes and metadata
- structured `ChatToolRound` values
- assistant usage/finish metadata
- drafts and context-omission state

Portable conversation fingerprints include attachments and structured tool traces so merge import does not treat materially different chats as duplicates.

`keepExisting` import is idempotent: importing the same portable conversation repeatedly does not create duplicates. The fingerprint intentionally excludes regenerated local IDs and timestamps while retaining content and structured conversation state that changes semantic identity.

## MCP configuration

MCP workspace persistence contains only non-secret configuration and cached discovery data:

- server ID/name/HTTPS endpoint
- authentication strategy metadata, but never the secret itself
- optional non-secret request headers
- enable/disable state
- discovered server/protocol metadata
- cached tool schemas and expiry metadata
- per-chat selected servers
- per-tool permission policy

Bearer tokens and custom authentication-header values live only in the dedicated MCP Keychain vault.

Deleting an MCP server also removes it from stored per-chat selection and removes known policies for tools in that server's cached catalog.

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

Settings provides explicit confirmation before deleting all conversations or all Keychain credentials. Delete All Credentials covers both provider credentials and remote MCP credentials.
