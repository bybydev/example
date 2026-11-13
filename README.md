# Inkribe

Native, local-first iPhone app for turning videos into captioned videos.

Website: https://spokiostudio.com/inkribe

For architecture, invariants, and agent workflow, see [AGENTS.md](AGENTS.md).

## Setup

Requirements: macOS, Xcode 26+ (iOS 26 SDK), XcodeGen 2.45.4+.

```sh
xcodegen generate
open Inkribe.xcodeproj
```

Run the `Inkribe` scheme. `project.yml` is the source of truth; don't edit the
generated Xcode project.

## Speech models

Whisper models are downloaded on-device by the app and are not committed.
`Models/` is only needed for bundled/CI builds:

```sh
./scripts/download-models.sh
xcodegen generate --spec project-ios-bundled.yml
```

## Notes

- The `InkribeMac` target is frozen. The Makefile `build`/`test` targets still
  point at the macOS scheme; build and run the iOS app from Xcode.
