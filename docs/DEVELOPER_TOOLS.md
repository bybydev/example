# Inkribe v1 — Developer Tools

## Requirement

In Debug builds, Inkribe must expose MacAppFoundation's Developer Tools as a dedicated macOS window opened from a top-level **Developer** menu in the application menu bar.

Use MacAppFoundation's existing identifiers and view directly rather than recreating the developer console.

```swift
#if DEBUG
Window(
    MacAppFoundationDeveloperTools.windowTitle,
    id: MacAppFoundationDeveloperTools.windowID
) {
    FoundationDeveloperView(
        purchaseManager: purchases,
        configuration: developerConfiguration
    )
    .macAppTheme(themeStore)
}
#endif
```

Add the menu command to the app scene:

```swift
.commands {
    #if DEBUG
    CommandMenu("Developer") {
        Button("Developer Tools…") {
            openWindow(id: MacAppFoundationDeveloperTools.windowID)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
    }
    #endif
}
```

## Rules

- The **Developer** menu exists only in Debug builds.
- Selecting **Developer → Developer Tools…** opens/focuses the MacAppFoundation Developer Tools window.
- Use `MacAppFoundationDeveloperTools.windowID` and `windowTitle`; do not duplicate string IDs locally.
- Use `FoundationDeveloperView` directly.
- Inject the same app-scoped `PurchaseManager` used by the production UI.
- Inject the same `MacAppThemeStore` used by the main window, Settings, onboarding, paywall, and upsells.
- Developer Tools remains a separate window and must not be embedded inside Settings.
- Inkribe may append app-specific developer sections/actions when useful for testing transcription, local models, or fixture state, but the base console remains framework-owned.
- No Debug purchase simulator or Developer menu code may be reachable in Release/App Store builds.

## Spokio-style Log window

Inkribe must also copy the Debug log-window architecture from Spokio `develop`.

Spokio currently has three pieces that should be mirrored:

1. `Helpers/LoggerHandler.swift`
   - a shared `LogStore`
   - bounded in-memory log history (`maximumEntries = 500`)
   - a `LogEntry` containing timestamp, level, logger label, message, and optional metadata
   - a `DemoLogHandler` that forwards `swift-log` events into the observable store
   - `MultiplexLogHandler` so logs can still go to the normal console handler while also being captured for the UI

2. `Views/Settings/LogInspectorView.swift`
   - header titled **Logs**
   - **Copy Log** action for all visible entries
   - **Clear** action
   - scrollable monospaced log rows
   - timestamp format `HH:mm:ss.SSS`
   - logger level + label + message + metadata
   - alternating row background for readability
   - text selection
   - per-row context-menu copy
   - automatic scroll to the newest entry

3. `App.swift`
   - Debug-only dedicated `Window("Logs", id: ...)`
   - `LogInspector(store: LogStore.shared)` as its content
   - **Developer → Show Logs** opens the window with `openWindow(id:)`

### Inkribe implementation contract

Create an Inkribe-owned logging utility modeled directly on that design, adapted only where needed for Inkribe naming/themes.

Suggested structure:

```text
Inkribe/
├── Developer/
│   ├── Logging/
│   │   ├── LogEntry.swift
│   │   ├── LogStore.swift
│   │   ├── InkribeLogHandler.swift
│   │   └── LogInspectorView.swift
│   └── DeveloperTools/
└── App/
```

Keep the architecture intentionally small; do not turn this into a general logging framework.

Bootstrap `swift-log` before other app services so startup/model/runtime errors are captured from the beginning. Use a multiplex handler so the same event is available to both normal development output and the in-app store.

The store should remain bounded (initially 500 entries, matching Spokio) to avoid unbounded memory growth.

### Log window scene

Add a dedicated Debug-only scene, separate from MacAppFoundation Developer Tools:

```swift
#if DEBUG
Window("Logs", id: InkribeWindowID.logs) {
    LogInspectorView(store: LogStore.shared)
        .macAppTheme(themeStore)
        .frame(minWidth: 600, minHeight: 500)
}
.defaultSize(width: 700, height: 600)
#endif
```

The exact identifier type can follow the final Inkribe app-window ID convention, but there must be one stable logs window ID.

### Developer menu integration

The Debug menu becomes:

```text
Developer
├── Developer Tools…      ⌘⌥D
└── Show Logs
```

`Show Logs` opens/focuses the dedicated Inkribe Logs window with `openWindow(id:)`.

Do not put the Log inspector inside Settings or inside `FoundationDeveloperView`; both remain independently openable diagnostic windows.

### Inkribe logging coverage

At minimum, route useful structured logs from:

- app startup / dependency initialization
- model discovery and validation
- Whisper model load/unload
- llama.cpp / Qwen model load/unload
- audio recording start/pause/resume/stop
- media decoding/import errors
- transcription queue lifecycle
- transcription progress/failures/cancellation
- AI cleanup/chunking/generation failures
- persistence errors
- export errors
- StoreKit/paywall integration errors where app-owned logging is useful

Do not log transcript contents, raw audio, prompts containing user transcript text, or other private user content by default. Logs are diagnostics, not a transcript archive.

### Log window acceptance criteria

- Debug build exposes **Developer → Show Logs**.
- Selecting it opens/focuses a separate Logs window.
- Logs generated through the app's `swift-log` setup appear live in the window.
- New entries auto-scroll into view.
- Whole-log copy works.
- Individual-row copy works.
- Clear removes the in-memory history.
- Log history is bounded.
- Metadata formatting is deterministic/readable.
- The view uses monospaced selectable text and follows the current Inkribe theme where appropriate.
- Sensitive transcript/audio contents are not logged by default.
- The Log window and capture/UI plumbing are excluded from Release/App Store builds unless a later product decision explicitly changes that policy.

## Initial Inkribe-specific developer hooks

Where useful, add app-defined Developer Tools actions for:

- reveal/copy bundled Whisper model path
- reveal/copy bundled Qwen model path
- validate bundled model presence/checksums
- show whether test fixtures or production models are active
- reset onboarding state for replay
- create/delete small sample transcript records for UI testing

These are development conveniences only and must remain under `#if DEBUG`.

## Acceptance criteria

- Debug build shows a top-level **Developer** menu.
- **Developer Tools…** opens the framework `FoundationDeveloperView` window.
- `⌘⌥D` opens the same window.
- **Show Logs** opens the dedicated Inkribe Logs window.
- The Developer Tools and Logs windows can be open simultaneously.
- The Developer Tools window uses the current Inkribe theme.
- StoreKit simulator changes in Developer Tools affect the same `PurchaseManager` observed by the Inkribe paywall, plan button, badges, and gates.
- Developer Tools and the Debug Log-window UI are absent from the Release/App Store build.
