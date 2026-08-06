# Consolidation

Phase 6 removes release-blocking ambiguity without expanding the product surface.

## Backup imports

`keepExisting` imports are idempotent. BYOKchat compares a normalized conversation fingerprint that excludes generated IDs and timestamps, so importing the same backup repeatedly does not duplicate conversations.

Schema version 1 still recreates local conversation and message IDs during restore. IDs are internal implementation details and are not exposed as stable backup identifiers.

## Redirect safety

The default provider transport uses an ephemeral URL session on Apple platforms:

- cookies and URL caching are disabled
- redirects are followed only when scheme, host, and effective port remain unchanged
- original request headers are retained only for an approved same-origin redirect
- cross-host, cross-port, and cross-scheme redirects are rejected

This protects bearer keys and custom secret headers for remote and private-network providers.
