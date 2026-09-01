# BYOK iOS 1.0 Release Checklist

This is the release boundary after the shared layer freeze. Do not reopen macOS/shared architecture unless an iOS release blocker requires it.

## Done in code

- [x] Shared storage/runtime composition is used by iOS and frozen for 1.0.
- [x] Conversation startup is index-only; chat shards load on demand.
- [x] Normal chat search is title/index-only.
- [x] Startup composition failures go to the recovery UI instead of trapping before bootstrap.
- [x] Storage migrations, recovery export, reset backup, and blob orphan cleanup are in place.
- [x] Telemetry is app-owned, local, and injected into chat/MCP runtimes.
- [x] Release developer controls and screenshot fixtures are DEBUG-only.
- [x] StoreKit paywall/settings expose purchase, restore, subscription management, Terms, and Privacy.
- [x] Info.plist version/build come from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
- [x] Privacy manifest declares UserDefaults and app-container file timestamp required-reason APIs.
- [x] 1024x1024 App Store icon source is present.
- [x] English App Store metadata and an App Review notes template are in the repo.

## Must do on Mac before upload

- [ ] Fetch latest `develop`.
- [ ] Run `xcodegen generate` so the generated Xcode project matches `project.yml`.
- [ ] Resolve packages and confirm AppFoundation is exactly 1.2.1.
- [ ] Build the iOS app in **Release** configuration with zero compile/link errors.
- [ ] Run the BYOKchat unit-test scheme.
- [ ] Run a clean-install smoke test on a physical iPhone running iOS 26:
  - first launch + onboarding/Skip
  - create provider connection
  - send/stream a chat
  - terminate/relaunch and reopen chat
  - attach/open a file or image
  - create a project
  - open Library and MCP settings
  - background/foreground during or after a chat
- [ ] Test an upgrade path using StoreKit sandbox/TestFlight:
  - monthly/yearly/lifetime products load as expected
  - purchase grants Pro immediately
  - Restore Purchases works after reinstall/sign-out scenario
  - recurring subscription management link opens correctly
- [ ] Test the free limits: 1 connection, 1 project, 1 MCP server, 10 saved files, 2 free themes, basic analytics.
- [ ] Archive Release and run Xcode **Validate App**. Resolve every validation/privacy-manifest warning before upload.
- [ ] Upload the archive to App Store Connect/TestFlight and install that uploaded build once before submission.
- [ ] Generate final App Store screenshots using `BYOKchatScreenshots` / `scripts/capture_app_store_screenshots.sh`; inspect the actual PNGs before upload.

## Must do in App Store Connect

- [ ] Confirm app version is **1.0** and build number is unique for the upload.
- [ ] Verify all three configured product IDs exist and are reviewable:
  - `com.hoangbkit.byokchat.pro.monthly`
  - `com.hoangbkit.byokchat.pro.yearly`
  - `com.hoangbkit.byokchat.pro.lifetime`
- [ ] Confirm monthly/yearly products are in the intended subscription group and lifetime is a non-consumable.
- [ ] Complete IAP localization, pricing, screenshots/review information, and attach the IAPs to the app version where required.
- [ ] Upload final screenshots matching the submitted binary.
- [ ] Copy metadata from `AppStore/Metadata/en-US/`.
- [ ] Verify these URLs are live from a normal browser, not logged in:
  - `https://byok.pro/privacy`
  - `https://byok.pro/terms`
  - `https://byok.pro/support`
- [ ] Complete App Privacy answers so they match the shipped privacy manifest and actual direct-to-provider data flow.
- [ ] Complete age-rating/export-compliance/content-rights questionnaires.
- [ ] Fill App Review contact information.
- [ ] Prepare a dedicated, low-spend, revocable provider API credential for App Review. Do **not** commit it to git.
- [ ] Replace all `<...>` placeholders in `AppStore/ReviewNotes.txt`, paste the final notes into App Store Connect, and verify the temporary credential works immediately before submission.
- [ ] Make every configured IAP visible/reviewable and explain the BYOK model + IAPs in Review Notes.

## Final submission gate

Submit only when all of these are true:

1. The exact uploaded App Store build has been installed and smoke-tested.
2. Xcode Validate App has no unresolved errors or privacy warnings.
3. All IAPs load in the uploaded/TestFlight build.
4. Privacy, Terms, and Support URLs are publicly reachable.
5. App Review can perform a real provider request using the temporary review credential.
6. Final screenshots and metadata describe the same functionality as the submitted binary.

After approval/review is complete, revoke the temporary review provider credential.
