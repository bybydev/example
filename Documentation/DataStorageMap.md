# Data Storage Map

Where every kind of data lives in BYOKchat, today and planned. Companion to
`DataPortability.md` (backup/export formats) and the iCloud sync plan.

Legend: `✗` intentionally device-local · `⚠️` known structural debt · `☁️`
future CloudKit mapping from the sync plan · `✅` syncs today.

```
📱 ON-DEVICE (app sandbox)
│
├── Library/Preferences/com.hoangbkit.byokchat.plist      ← UserDefaults
│     · theme choice, onboarding/pro flags, device ID
│     · sidebar pinned-chat IDs · project-sync toggle
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
    │       [sync later: ☁️ per-account CKRecords]
    │
    ├── conversations-v1/                 ← SHARDED store
    │     ├── index.json                  · derived list-row cache, never authoritative
    │     └── <conversation-id>.json      · one full ChatConversation per file
    │       [sync later: ☁️ record per conversation + message pages]
    │
    ├── files-v1/                         ← ALL file bytes, one blob per ID
    │     └── <file-id>                   · chat attachments, library saves,
    │                                       project reference files — shared store;
    │                                       JSON workspaces hold metadata only
    │       [sync later: ☁️ content-addressed CKAssets, lazy fetch]
    │
    ├── library-v1.json                   ← library entry metadata (JSON)
    │       [sync later: ☁️ records]
    │
    ├── projects-v1.json                  ← JSON, metadata only
    │     · project settings/instructions/presets/tools config
    │     · reference-file POINTERS (bytes live in files-v1/)
    │     · conversation↔project membership map
    │       [sync today: ✅ iCloud envelope · later: ☁️ per-project records]
    │
    ├── mcp-servers-v1.json               ← JSON
    │     · server configs (endpoint/auth-kind/headers)
    │     · tool-catalog SNAPSHOTS        (runtime cache → never synced ✗)
    │     · per-chat tool configurations
    │       [sync later: ☁️ per-server records, snapshots excluded]
    │
    ├── project-sync-local-v1.json        ← sync identity map (localID ↔ syncID)
    │
    ├── Telemetry/telemetry.sqlite        ← SQLite diagnostics log ✗ never synced
    │
    ├── attachments-v1/, library-v1/      ← legacy blob dirs (pre-unification);
    │                                       kept only so resets on old installs
    │                                       still clean them up
    ├── MigrationBackups/                 ← pre-migration copies (keep 3)
    └── ResetBackups/                     ← pre-reset copies (keep 3)

☁️ ICLOUD — TODAY
└── <ubiquity container>/Documents/BYOKchat/project-sync-v1.json
      · monolithic projects envelope, LWW merge w/ tombstones

☁️ ICLOUD — PLANNED (Pro)
└── CloudKit private database
      · per-entity CKRecords (projects/MCP/accounts first,
        conversations next, media assets last)
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
   load-time sweep prunes, never metadata pointing at nothing).
3. **One SQLite database** — telemetry/diagnostics only.

No Core Data or SwiftData anywhere; every entity has a stable string ID and
timestamps, which is what makes each box map cleanly onto a future `CKRecord`.

## Key sources

| Concern | Code |
| --- | --- |
| Store locations / construction | `BYOKchat/App/AppModel.swift` |
| Sharded conversation persistence | `Sources/BYOKchatProviderCore/ConversationShardPersistence.swift` |
| Reset/recovery file enumeration | `BYOKchat/App/AppBootstrap.swift` (`localDataURLs`, `blobDirectoryURLs`) |
| Keychain vaults | `CredentialVault.swift`, `MCPCredentialVault.swift` |
| Project sync envelope | `ProjectSync.swift`, `App/ProjectSyncModel.swift` |
| Telemetry DB path | `TelemetryRecorder.defaultDatabaseURL` |
