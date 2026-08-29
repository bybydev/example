# Data Storage Map

Where every kind of data lives in BYOKchat, today and planned. Companion to
`DataPortability.md` (backup/export formats).

Legend: `✗` intentionally device-local · `⚠️` known structural debt.

```
📱 ON-DEVICE (app sandbox)
│
├── Library/Preferences/com.hoangbkit.byokchat.plist      ← UserDefaults
│     · theme choice, onboarding/pro flags, device ID
│     · sidebar pinned-chat IDs
│     · (AppFoundation ThemeManager settings)
│
├── tmp/                                                   ← transient
│     · temp files staged for the Library row-share sheet
│
├── Keychain                                               ← secrets ONLY, never synced ✗
│     · provider API keys                (CredentialVault)
│     · MCP auth credentials             (MCPCredentialVault)
│
└── Application Support/BYOKchat/
    │
    ├── providers-v1.json                 ← JSON, whole-file atomic write
    │     · model catalog, custom providers,
    │       account METADATA (label/baseURL/headers/default model)
    │
    ├── conversations-v1/                 ← SHARDED store
    │     ├── index.json                  · derived list-row cache, never authoritative
    │     └── <conversation-id>.json      · one full ChatConversation per file
    │
    ├── files-v1/                         ← ALL file bytes, one blob per ID
    │     ├── index.json                  · derived metadata cache (name/
    │     │                                 type/size per ID), rebuilt from the
    │     │                                 directory listing when missing
    │     ├── derived/<id>-<px>           · persisted downsampled thumbnails,
    │     │                                 generated on first request
    │     └── <file-id>                   · chat attachments, library saves,
    │                                       project reference files — shared
    │                                       on-demand store; JSON workspaces
    │                                       hold metadata only (rows are
    │                                       metadata-only in memory too; bytes
    │                                       are fetched when displayed/sent)
    │
    ├── library-v1.json                   ← library entry metadata (JSON)
    │
    ├── projects-v1.json                  ← JSON, metadata only
    │     · project settings/instructions/presets/tools config
    │     · reference-file POINTERS (bytes live in files-v1/)
    │     · conversation↔project membership map
    │
    ├── mcp-servers-v1.json               ← JSON
    │     · server configs (endpoint/auth-kind/headers)
    │     · tool-catalog SNAPSHOTS        (runtime cache ✗)
    │     · per-chat tool configurations
    │
    ├── project-sync-local-v1.json        ← legacy sync identity map; kept so
    │                                       resets on installs that used sync
    │                                       still clean it up
    │
    ├── Telemetry/telemetry.sqlite        ← SQLite diagnostics log ✗ never synced
    │
    ├── attachments-v1/, library-v1/      ← legacy blob dirs (pre-unification);
    │                                       kept only so resets on old installs
    │                                       still clean them up
    ├── MigrationBackups/                 ← pre-migration copies (keep 3)
    └── ResetBackups/                     ← pre-reset copies (keep 3)
```

## Shape of the system

Three storage technologies total:

1. **JSON workspaces** (`*-v1.json`) — one Codable state struct per domain,
   written atomically. Conversations are additionally sharded into
   `conversations-v1/` so a mutation rewrites one small file instead of the
   whole corpus.
2. **Flat blob directories** (`attachments-v1/`, `library-v1/`,
   `conversations-v1/<id>.json` shards) — byte payloads named by stable ID,
   written before their metadata lands (crash leaves an orphan blob that the
   load-time sweep prunes, never metadata pointing at nothing). `files-v1`
   works like an object store: an index answers "what is stored" without
   touching bytes, and reads are on demand — thumbnails and originals are
   fetched when a surface displays or sends them, never eagerly hydrated.
3. **One SQLite database** — telemetry/diagnostics only.

No Core Data or SwiftData anywhere; every entity has a stable string ID and
timestamps.

## Key sources

| Concern | Code |
| --- | --- |
| Store locations / construction | `BYOKchat/App/AppModel.swift` |
| Sharded conversation persistence | `Sources/BYOKchatProviderCore/ConversationShardPersistence.swift` |
| Reset/recovery file enumeration | `BYOKchat/App/AppBootstrap.swift` (`localDataURLs`, `blobDirectoryURLs`) |
| Keychain vaults | `CredentialVault.swift`, `MCPCredentialVault.swift` |
| Telemetry DB path | `TelemetryRecorder.defaultDatabaseURL` |
