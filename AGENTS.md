# Inkribe Working Rules

- Do not fake completion, must stop and report problem.
- Do not run build or tests unless being asked.
- This project is using xcodegen, do not modify .xcodeproj file.

## Planned iOS caption/video app

Before working on the new iOS roadmap, read [docs/ios/README.md](docs/ios/README.md), [WORKFLOW.md](docs/ios/WORKFLOW.md), [HANDOFF.md](docs/ios/HANDOFF.md) and the requested phase brief. The historical Mac v1 phases are a separate sequence.

- Do not set up or trigger CI or perform device validation; the user will test after implementation.
- Existing no-build/no-test and XcodeGen rules above still apply.
- Planning PR #22 was squash merged. P0 is in PR #23 (draft, targeting develop); leave it open for review, do not merge/auto-merge. The latest user instruction for each PR's merge status always wins.
