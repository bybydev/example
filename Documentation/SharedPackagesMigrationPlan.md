# Shared Packages Migration Plan

## Goal

Restructure BYOK so reusable logic lives in independent local Swift packages under `Packages/`, with hard compile-time boundaries that work on both iOS and macOS.

The iOS app remains the product target. A minimal macOS target is added only as a compile sentinel: it imports every shared package and proves the shared graph remains macOS-compatible. No macOS product UI or feature parity work is part of this migration.

## Non-negotiable architecture rules

1. **No circular package dependencies, at any cost.**
2. Every package has its own `Package.swift`, source target, and tests.
3. There is no umbrella `BYOKKit` package.
4. Lower-level packages never import higher-level packages.
5. If two packages appear to need each other, move the shared type/protocol one layer lower instead of creating a cycle.
6. Do not use `@_exported import` to hide dependency problems.
7. `Packages/` contains platform-neutral shared logic only. No `UIKit`, iOS-only navigation, sheet, device-size, or app-lifecycle assumptions.
8. Shared packages declare both iOS and macOS support and must compile for both.
9. App composition belongs in the application targets. Cross-domain coordination should not be pushed into a shared package merely for convenience.
10. Migration stages are planning labels only. Do not leave `Phase1`, `Phase2`, temporary compatibility names, milestone comments, or similar implementation residue in source/tests after a move.
11. Preserve current iOS behavior throughout the migration. Structural work must not change product behavior unless explicitly required to remove a dependency cycle.
12. `project.yml` remains the XcodeGen source of truth. Do not manually edit generated `.xcodeproj` files.

## Target repository structure

```text
BYOKchat/
├── BYOKchat/                         # iOS app target
│   ├── App/
│   ├── Features/
│   └── Resources/
│
├── BYOKmac/                          # compile-check target only for now
│   └── App/
│       └── BYOKmacApp.swift
│
├── Packages/
│   ├── BYOKCore/
│   │   ├── Package.swift
│   │   ├── Sources/BYOKCore/
│   │   └── Tests/BYOKCoreTests/
│   │
│   ├── BYOKTelemetry/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   ├── BYOKTelemetry/
│   │   │   └── CSQLite/
│   │   └── Tests/BYOKTelemetryTests/
│   │
│   ├── BYOKProviders/
│   │   ├── Package.swift
│   │   ├── Sources/BYOKProviders/
│   │   └── Tests/BYOKProvidersTests/
│   │
│   ├── BYOKMCP/
│   │   ├── Package.swift
│   │   ├── Sources/BYOKMCP/
│   │   └── Tests/BYOKMCPTests/
│   │
│   ├── BYOKProjects/
│   │   ├── Package.swift
│   │   ├── Sources/BYOKProjects/
│   │   └── Tests/BYOKProjectsTests/
│   │
│   └── BYOKChat/
│       ├── Package.swift
│       ├── Sources/BYOKChat/
│       └── Tests/BYOKChatTests/
│
├── Documentation/
├── project.yml
└── README.md
```

When migration is complete, the current root `Package.swift`, `Sources/`, and `Tests/` should be removed because their responsibilities will have moved into the independent packages.

## Required dependency DAG

The dependency graph must remain a directed acyclic graph.

```text
Level 0
────────────────────────────────────────────
BYOKCore

Level 1
────────────────────────────────────────────
BYOKTelemetry  ───────► BYOKCore
BYOKProviders  ───────► BYOKCore

Level 2
────────────────────────────────────────────
BYOKMCP        ───────► BYOKCore
                ├─────► BYOKProviders
                └─────► BYOKTelemetry        # only for MCP instrumentation

Level 3
────────────────────────────────────────────
BYOKProjects   ───────► BYOKCore
                └─────► BYOKMCP              # only while project presets store MCP config

BYOKChat       ───────► BYOKCore
                ├─────► BYOKProviders
                ├─────► BYOKMCP
                └─────► BYOKTelemetry

Level 4
────────────────────────────────────────────
BYOKchat iOS   ───────► required shared packages
BYOKmac        ───────► every shared package
```

### Forbidden edges

These imports are architectural errors:

```text
BYOKCore       -> anything else
BYOKTelemetry  -> BYOKProviders / BYOKMCP / BYOKProjects / BYOKChat
BYOKProviders  -> BYOKMCP / BYOKProjects / BYOKChat
BYOKMCP        -> BYOKProjects / BYOKChat
BYOKProjects   -> BYOKChat
BYOKChat       -> BYOKProjects
```

`BYOKChat <-> BYOKProjects` is specifically forbidden. Project/chat coordination must happen in the app composition layer.

If the implementation discovers a required edge that would violate this ordering, stop and extract the shared contract into `BYOKCore` or redesign the boundary. Never add the reverse dependency temporarily.

## Package responsibilities

### BYOKCore

The lowest-level shared vocabulary. It must have no BYOK package dependencies.

Candidate contents:

- stable identifier types shared across domains
  - `ConversationID`
  - `ChatMessageID`
  - `ProviderID`
  - `ProviderAccountID`
  - `ModelID`
  - `ProjectID`
  - `MCPServerID` only if truly cross-domain
- `JSONValue`
- small platform-neutral utility types/protocols required by multiple packages

Do not turn `BYOKCore` into a dumping ground. A type belongs here only when multiple independent packages genuinely require it.

### BYOKTelemetry

Generic observability infrastructure only.

Move here:

- `TelemetryEvent`
- `TelemetryConfiguration`
- `TelemetryRecorder`
- `TelemetrySQLiteStore`
- `TelemetryPrivacy`
- `TelemetryAnalytics`
- `TelemetryDiagnostics`
- `CSQLite`

Do **not** move domain instrumentation such as `ChatRuntimeTelemetry`, `ChatToolTelemetry`, or `MCPTransportTelemetry` into the generic telemetry package. Those belong with the domain being instrumented.

`BYOKTelemetry` may know IDs from `BYOKCore`, but it must know nothing about provider runtimes, chats, MCP, projects, UI, or purchases.

### BYOKProviders

Provider-independent runtime plus native provider adapters.

Candidate contents:

- `ProviderTypes`
- `ProviderRuntime`
- `ProviderRegistry`
- `ProviderWorkspace`
- `ProviderError`
- `BuiltInProviders`
- `CredentialVault`
- `HTTPTransport`
- `SSEDecoder`
- local HTTP support
- OpenAI-compatible adapter/wire/support
- Anthropic adapter
- Gemini adapter
- provider-specific telemetry helper if needed

Provider code must never import `BYOKChat`.

Tool-call wire types used directly by provider APIs need careful placement. Prefer protocol/wire-neutral types in the lowest sensible package rather than making Providers depend upward on Chat.

### BYOKMCP

Remote MCP protocol, workspace, transport, tool approval/elicitation, and execution.

Candidate contents:

- `MCPTypes`
- `MCPChatToolTypes`
- `MCPInputRequiredTypes`
- `MCPRemoteRuntime`
- `MCPHTTPTransport`
- `MCPToolHeaders`
- `MCPCredentialVault`
- `MCPWorkspace`
- `MCPConversationToolRuntime`
- MCP transport/tool telemetry helpers

`MCPHTTPTransport` currently shares HTTP transport infrastructure with Providers, so `BYOKMCP -> BYOKProviders` is acceptable. The reverse edge is forbidden.

### BYOKProjects

Project storage, files, presets, portability, and sync.

Candidate contents:

- `ProjectWorkspace`
- `ProjectPortability`
- `ProjectSync`
- project-aware portability helpers that are truly project-owned

Projects may store provider/model identifiers from `BYOKCore` without importing Providers.

Current project MCP configuration creates a legitimate downward dependency on `BYOKMCP` unless that configuration is later moved into a lower shared contract. This is allowed as long as MCP never imports Projects.

Projects must not import `BYOKChat`. Conversation/project assignment should use stable IDs from `BYOKCore`, and app-level models should coordinate the two domains.

### BYOKChat

Conversation state, context construction, generation orchestration, tool-loop coordination, billing, and chat-specific telemetry.

Candidate contents:

- `ConversationTypes`
- `ConversationStore`
- `ConversationStore+Portability`
- `ChatContextBuilder`
- `ChatRuntime`
- `ChatFailureOrigin`
- `UsageBilling`
- generic chat/tool runtime types that are conversation-owned
- `ChatRuntimeTelemetry`
- chat/tool telemetry helper code

`BYOKChat` may depend on Providers, MCP, and Telemetry. It must not depend on Projects.

If project instructions/files are currently injected inside chat-core code, replace that coupling with neutral inputs supplied by the app layer, for example resolved instructions, attachments, or context contributions. The chat package should consume the resolved data without knowing the concept of a Project.

## macOS compile-check target

The macOS target exists only to prove every shared package is genuinely universal.

Initial structure:

```text
BYOKmac/
└── App/
    └── BYOKmacApp.swift
```

Its implementation should remain intentionally tiny:

```swift
import SwiftUI
import BYOKCore
import BYOKTelemetry
import BYOKProviders
import BYOKMCP
import BYOKProjects
import BYOKChat

@main
struct BYOKmacApp: App {
  var body: some Scene {
    WindowGroup {
      Text("BYOK")
    }
  }
}
```

Requirements:

- macOS 15+ target is sufficient for now.
- target links every local shared package product explicitly.
- no chat UI, sidebar, settings, StoreKit, onboarding, sync UI, or feature parity work.
- no persistence/bootstrap work unless compilation itself requires it.
- the target's job is simply: **if all imports and linkage compile on macOS, it passes.**
- do not let macOS compile fixes weaken or fork the iOS implementation. Shared code should use APIs supported by both platforms or hide platform-specific code behind narrow abstractions.

## Migration sequence

### 1. Audit and freeze the dependency graph

Before moving files:

- inventory imports and type references in `Sources/BYOKchatProviderCore`
- classify every current file into Core, Telemetry, Providers, MCP, Projects, Chat, or app-only
- identify types referenced by more than one future package
- explicitly resolve each potential cycle on paper before changing package manifests
- establish the final allowed dependency edges above

Deliverable is the dependency map, not temporary runtime adapters.

### 2. Extract BYOKCore

Create `Packages/BYOKCore` first.

Move only the small shared types needed to let later packages become independent. Update existing code to import `BYOKCore` where needed.

Acceptance criteria:

- package compiles for iOS and macOS
- no BYOK package dependencies
- no UIKit/AppKit/SwiftUI dependency unless a truly universal UI primitive is deliberately approved
- no domain runtime logic

### 3. Extract BYOKTelemetry

Create `Packages/BYOKTelemetry` and move generic telemetry plus CSQLite.

Move chat/MCP-specific instrumentation out of the generic telemetry folder and keep it with the future owning package.

Acceptance criteria:

- depends only on `BYOKCore`
- telemetry tests live inside this package
- SQLite builds on iOS and macOS
- no imports of Providers, MCP, Projects, or Chat

### 4. Extract BYOKProviders

Create `Packages/BYOKProviders` and move provider runtime, transports, credentials, registry/workspace, and adapters.

Resolve any current references to chat-owned types by moving neutral wire/runtime contracts downward rather than adding `BYOKProviders -> BYOKChat`.

Acceptance criteria:

- dependency direction stays downward only
- provider tests move with the package
- all built-in adapters compile on iOS and macOS
- credentials use shared Apple-platform Security APIs or a platform-neutral abstraction

### 5. Extract BYOKMCP

Create `Packages/BYOKMCP`.

Use Providers' HTTP transport abstraction if needed. Keep MCP-specific telemetry in MCP while sending events through `BYOKTelemetry`.

Acceptance criteria:

- MCP may depend on Core, Providers, Telemetry
- Providers never depends on MCP
- MCP tests move with the package
- remote transport, approval, elicitation, tool execution, and workspace behavior remain unchanged

### 6. Extract BYOKProjects

Create `Packages/BYOKProjects`.

Break any implicit Project/Chat coupling now. Project membership should use IDs from Core, not concrete chat-store/runtime types.

Acceptance criteria:

- no `import BYOKChat`
- Project -> MCP is allowed only for the existing MCP configuration/preset model
- project sync/portability tests move with the package
- project storage remains portable between iOS and macOS

### 7. Extract BYOKChat

Create `Packages/BYOKChat` last because it is the highest-level shared runtime package and consumes the lower layers.

Move conversation store/types, context building, runtime orchestration, usage billing, and chat-specific telemetry.

Resolve project data before entering Chat. The iOS app should provide already-resolved project instructions/files/tool configuration through neutral inputs.

Acceptance criteria:

- depends only on approved lower-level packages
- no Projects dependency
- no UIKit/SwiftUI
- existing conversation/context/tool-loop/billing/telemetry tests move with the package
- current iOS runtime behavior remains unchanged

### 8. Rewire the iOS app

Update `project.yml` to reference every local package from `Packages/...`.

The app layer imports only the modules it actually needs. App models remain responsible for composing Projects, Chat, Providers, MCP, purchases, themes, and UI.

Remove the old `BYOKchatProviderCore` dependency after all call sites have migrated.

Acceptance criteria:

- iOS source no longer imports `BYOKchatProviderCore`
- generated project can be recreated solely from `project.yml`
- root `Sources/`, `Tests/`, and root `Package.swift` are no longer needed and are removed
- no duplicate source files remain in old and new locations

### 9. Add the macOS compile sentinel

Add the minimal `BYOKmac` target to `project.yml` only after the package graph is established.

The single purpose of this target is to import/link every package and compile for macOS.

Acceptance criteria:

```text
import BYOKCore       ✅
import BYOKTelemetry  ✅
import BYOKProviders  ✅
import BYOKMCP        ✅
import BYOKProjects   ✅
import BYOKChat       ✅
```

No feature work is required beyond that.

### 10. Consolidate

After all packages are active:

- remove obsolete root package/source/test structure
- remove temporary adapters created only to facilitate file moves
- remove duplicate aliases/type shims once all callers use the final modules
- remove migration-specific comments/names from source and tests
- verify each package's public API is intentionally minimal
- verify no package imports an undeclared/transitive dependency
- verify docs describe the final module ownership rather than migration history

## Cycle prevention checks

Every package change must be reviewed with these checks:

1. Inspect each `Package.swift` dependency list.
2. Confirm the edge appears in the approved DAG.
3. Search source for imports of higher-level packages.
4. Treat any proposed reverse edge as a design failure, not a temporary fix.
5. Prefer protocols/value types in Core over cross-package callbacks that require reverse imports.
6. Keep application orchestration in `BYOKchat/App` or later `BYOKmac/App`.

A simple allowed dependency matrix:

| Package | Core | Telemetry | Providers | MCP | Projects | Chat |
|---|---:|---:|---:|---:|---:|---:|
| BYOKCore | — | ❌ | ❌ | ❌ | ❌ | ❌ |
| BYOKTelemetry | ✅ | — | ❌ | ❌ | ❌ | ❌ |
| BYOKProviders | ✅ | optional* | — | ❌ | ❌ | ❌ |
| BYOKMCP | ✅ | ✅ | ✅ | — | ❌ | ❌ |
| BYOKProjects | ✅ | ❌ | ❌ | ✅ | — | ❌ |
| BYOKChat | ✅ | ✅ | ✅ | ✅ | ❌ | — |

`*` Prefer provider instrumentation to use Telemetry only if it genuinely belongs inside Providers. Otherwise keep request lifecycle instrumentation in Chat and omit this dependency.

## Platform compatibility rules

Inside `Packages/`:

- Foundation: allowed
- Security/Keychain: allowed when APIs are available on both iOS and macOS
- Network: allowed when shared
- SQLite: allowed
- Swift concurrency: allowed
- SwiftUI: avoid in domain packages
- UIKit: forbidden
- iOS-only application APIs: forbidden
- AppKit: forbidden unless a future explicitly platform-specific package is created outside this shared set

When a shared package needs a capability implemented differently by platform, define a narrow protocol in the owning/lower package and inject the platform implementation from the app instead of using conditional platform branches throughout domain logic.

## Testing strategy

Each package owns tests for its behavior.

Target layout:

```text
Packages/BYOKCore/Tests/BYOKCoreTests
Packages/BYOKTelemetry/Tests/BYOKTelemetryTests
Packages/BYOKProviders/Tests/BYOKProvidersTests
Packages/BYOKMCP/Tests/BYOKMCPTests
Packages/BYOKProjects/Tests/BYOKProjectsTests
Packages/BYOKChat/Tests/BYOKChatTests
```

Tests move with the code they validate. Avoid a large central test target that re-couples otherwise independent packages.

Integration behavior spanning multiple packages should be tested at the highest owning layer, usually `BYOKChatTests` or the application target, rather than giving lower-level packages reverse dependencies for test convenience.

## Definition of done

The migration is complete when:

- `Packages/` contains independent `BYOKCore`, `BYOKTelemetry`, `BYOKProviders`, `BYOKMCP`, `BYOKProjects`, and `BYOKChat` packages
- each package has its own `Package.swift` and tests
- dependency graph is acyclic and matches the approved DAG
- no umbrella package exists
- no package relies on transitive imports
- no shared package imports UIKit or iOS-only app code
- the iOS app builds against the new packages with existing behavior intact
- the old root `BYOKchatProviderCore` package structure is removed
- the minimal macOS target imports every package and compiles
- no macOS feature implementation is required
- source/tests/docs contain final responsibility-based names with no migration-stage residue
