# App Store Screenshots

BYOKchat screenshots are captured from real app UI through the `BYOKchatUITests` target.

The screenshot launch mode is deterministic and isolated:

- `UI_TEST_SCREENSHOTS` seeds local provider accounts, chats, projects, attachments, usage, and MCP discovery data.
- onboarding is marked complete for the screenshot process.
- iCloud project sync is disabled.
- AppFoundation purchases use BYOKchat's built-in simulated catalog.
- fixture provider credentials use screenshot-only account IDs in the simulator Keychain.
- no provider or MCP network request is required to render the seeded screens.

Generate the suite from the repository root:

```sh
scripts/capture_app_store_screenshots.sh
```

The default destination is `iPhone 17 Pro Max`. Override it when needed:

```sh
SCREENSHOT_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
  scripts/capture_app_store_screenshots.sh
```

The UI tests keep every screenshot as an XCTest attachment. The script exports the result bundle attachments and saves normalized PNGs in this directory.

Current captures:

1. `01_Home.png`
2. `02_Sidebar.png`
3. `03_Chat.png`
4. `04_Projects.png`
5. `05_Providers.png`
6. `06_MCP.png`
7. `07_Themes.png`
8. `08_Paywall.png`

`project.yml` is the source of truth for the UI-test target and screenshot scheme. The generated Xcode project should not be edited by hand.
