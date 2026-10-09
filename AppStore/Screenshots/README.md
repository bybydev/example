# App Store Screenshots

BYOKchat screenshots are captured from the real app UI through the `BYOKchatUITests` target.

The screenshot launch mode is deterministic and isolated:

- `UI_TEST_SCREENSHOTS` seeds local provider accounts, chats, projects, attachments, usage, and MCP discovery data.
- onboarding is marked complete for the screenshot process.
- AppFoundation purchases use BYOKchat's built-in simulated catalog.
- fixture provider credentials use screenshot-only account IDs in the simulator Keychain.
- no provider or MCP network request is required to render the seeded screens.

## Xcode Cloud

After regenerating the project with XcodeGen and committing the generated Xcode project/package resolution files, Xcode Cloud needs no custom setup scripts, environment variables, secrets, or fixture files.

Use the shared `BYOKchat` scheme. Its Test action includes both `BYOKchatTests` and `BYOKchatUITests`; Xcode Cloud can run both from this one scheme. The screenshot tests belong to `BYOKchatUITests`. The target launches the app with screenshot mode enabled, seeds the fixture state automatically, navigates the real UI, and keeps each capture as an XCTest screenshot attachment in the Xcode Cloud test results.

Current captures:

1. `01_Home`
2. `02_Sidebar`
3. `03_Chat`
4. `04_Projects`
5. `05_Providers`
6. `06_MCP`
7. `07_Themes`
8. `08_Paywall`

## Local capture

For local development, the optional helper script runs the same UI-test target and exports the XCTest attachments as named PNG files into this directory:

```sh
scripts/capture_app_store_screenshots.sh
```

The default destination is `iPhone 17 Pro Max`. Override it when needed:

```sh
SCREENSHOT_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
  scripts/capture_app_store_screenshots.sh
```

`project.yml` is the source of truth for the UI-test target and main iOS scheme. Regenerate the Xcode project with XcodeGen rather than editing the generated project by hand.
