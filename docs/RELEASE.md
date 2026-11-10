# Inkribe release builds

Two independent, manual-only release lanes exist. Neither runs on pushes, PRs or tags.
This file consolidates the former XCODE_CLOUD.md and BUILD_RELEASE.md topics.

## Xcode Cloud (TestFlight / App Store lane)


Inkribe uses the committed `Inkribe.xcodeproj`, shared `Inkribe` scheme,
`Package.resolved`, and `Inkribe/Resources/Info.plist`. Generate the project
locally from `project.yml` and commit updated inputs when source membership,
dependencies, or project settings change.

## Model selection

Set `IOS_MODELS` in the workflow's Environment section. It can be an ordinary
or secret environment variable.

| Value | Build behavior |
| --- | --- |
| Unset, empty, or `download` | No bundled weights; Tiny, Base, and Small remain downloadable in Settings. |
| `bundled` | Include verified Whisper Small multilingual (`ggml-small.bin`) and use the existing bundled-only policy. |
| Any other value | Fail the post-clone hook with the accepted values. |

The variable defaults to `download` in both hooks. Only an explicit `bundled`
value downloads weights on the Cloud build machine. The helper reuses
`scripts/release_models.py` and the pinned manifest's size/SHA-256 checks.
Model weights remain outside Git.

## Repository hooks

| Hook | Responsibility |
| --- | --- |
| `ci_scripts/ci_post_clone.sh` | Check committed inputs and the iOS scheme; read `IOS_MODELS`; prepare required weights and configure the iOS resource/flag. |
| `ci_scripts/ci_post_xcodebuild.sh` | After a successful archive, verify the iOS identity and selected model contents. |

Both hooks are executable. Xcode Cloud discovers them beside the project.
The setup follows Spokio and ReadAloud's committed-project and lockfile pattern.
Cloud resolves packages before custom post-clone preparation, so project
generation and package updates belong on the developer's Mac.

`scripts/xcode_cloud.py` adjusts only the Inkribe target's model resource and
existing `INKRIBE_IOS_BUNDLED_MODELS_ONLY` flag after dependency resolution.
It reads the project with Apple's `plutil`, locates the iOS target by name,
and checks the modified project's full structure before replacing the file.
The package graph, lockfile, signing settings, and Mac target are preserved.
Xcode performs the normal resource copy and signing afterward.

The archive hook checks the actual app with the same model verifier as GitHub
releases. It reads and verifies the archived resources.
Other actions and failed archives skip archive verification.
Test-without-building skips resource preparation.

## One-time Apple setup

1. Open `Inkribe.xcodeproj` on a Mac and select the shared `Inkribe` scheme.
2. Use **Product → Xcode Cloud → Create Workflow** for the iOS app record
   `com.hoangbkit.inkribe`, and connect `hoangbkit/Inkribe`.
3. Grant Xcode Cloud access to the app repository and any dependency Apple
   reports. The current remote packages are public; a GitHub token is not
   required by these hooks.
4. Name the workflow **Inkribe iOS Release** and select an Xcode/macOS environment
   supporting the project's iOS 26 and Swift 6.2 dependencies. Select **Clean**
   for the distribution workflow's build environment.
5. Choose a **Manual** start condition and an **iOS Archive** action with the
   `Inkribe` scheme. Its archive configuration is Release. Keep automatic signing.
6. Choose **TestFlight and App Store**, restrict workflow editing as Apple
   requires for submission-eligible builds, and select your internal TestFlight
   group for the distribution post-action.
7. Leave `IOS_MODELS` unset for the default download build. Set it to `bundled`
   for a build containing Small multilingual.

Workflow configuration, GitHub authorization, signing access, and TestFlight
groups are managed in Xcode/App Store Connect.

## Updating committed inputs

On a Mac, use the base spec and resolve the selected iOS scheme:

```sh
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project Inkribe.xcodeproj -scheme Inkribe
```

Commit `project.pbxproj`, shared schemes, the workspace's
`xcshareddata/swiftpm/Package.resolved`, and the generated iOS Info.plist.
Keep the committed project in the base download configuration; the Cloud hook
selects bundling from the workflow variable. Check project changes against
`project.yml`. User-specific workspace settings are ignored.

The initial project and lockfile were taken from the existing MyCLI release
`mycli-build-41759535435-1`, built from source commit
`e5efd65a1debed7f62e43422a46527123725e147`. Its source is the PR's Home fixes
baseline. The Info.plist retains the generated metadata declared in `project.yml`.

## First Cloud archives

Run a manual archive with `IOS_MODELS` unset and review the archive hook's
download-policy verification. Then run with `IOS_MODELS=bundled`; the log must
verify Small's pinned bytes and checksum in the archived app. On a fresh install,
confirm the bundled build transcribes in airplane mode.

The repository setup has received source and syntax review. Apple-hosted
compilation, signing, upload, and device acceptance remain unverified.

## Manual GitHub Actions lane (unsigned archive builds for mycli)


The user explicitly authorized this release-workflow source setup after Pro PR #31 was squash merged. It overrides the earlier no-CI-setup instruction only for this manual release lane. Nothing has been dispatched, downloaded, generated, compiled, signed or deployed by the agent. App source, product identities, project specs, resource policy and signing entitlements are unchanged. Fast/Full CI are not added.

The contract follows [hoangbkit/guidelines](https://github.com/hoangbkit/guidelines/blob/master/github-actions-workflows.md). `.github/workflows/release.yml` has **only workflow_dispatch**. Opening/merging a PR, pushing a commit or creating a tag never starts it. The workflow runs on macos-26, explicitly selects installed Xcode 26.3, reports ref/SHA/toolchain, has a 90-minute timeout and repository-wide publication concurrency without cancellation. It grants contents:write for prerelease publication, with no signing credentials or App Store Connect access.

## Inputs

| Input | Options | Default |
|---|---|---|
| platform | iOS / macOS / both | iOS |
| configuration | Debug / Release | Release |
| ios_models | download / bundled; ignored for macOS-only | download |

Choose the ref/branch in GitHub's dispatch UI. Checkout uses that selected ref; the prerelease points to the exact checked-out SHA. iOS uses `com.hoangbkit.inkribe` for both Debug and Release by explicit user request. Mac keeps `com.hoangbkit.inkribe.debug` for Debug and `com.hoangbkit.inkribe` for Release. No CI identity override. One configuration per run.

GitHub requires the workflow definition on the repository's **default branch (currently master)** before its Run workflow control appears. This PR targets develop as requested; merging into develop alone does not expose the default-branch dispatch entry. Promote the workflow definition to master through the usual reviewed release process, then select develop/another branch to run. Do not change the default branch or merge automatically for this setup.

## Models, dependencies and generation

| Selection | Resources staged before XcodeGen | Spec / behavior |
|---|---|---|
| iOS + download | No weights | project.yml; choose/download Tiny/Base/Small in app |
| iOS + bundled | Pinned real Small only | project-ios-bundled.yml; bundled Small, no app download/cache fallback |
| macOS | All five pinned models | project.yml; existing offline Mac resource policy |
| both | All five pinned models | Base or bundled spec according to ios_models; iOS still copies only the selected policy's resources |

Release configuration alone does not select bundled-only packaging. `scripts/release_models.py` reads the existing global JSON manifest, verifies exact bytes and SHA-256, and streams missing/invalid required models to temporary files before atomic publication. No fixtures, moving revisions or silent missing-model fallback. The iOS-only download choice never fetches weights, even though SwiftPM still resolves required native dependencies. Mac Qwen/diarization models are not copied into iOS.

The exact model-set/manifest/helper cache is separate from SwiftPM sources/binary artifacts. Cached weights are fully checked every run, and verified cold downloads are saved before compilation so a later compiler failure does not waste the downloads. No DerivedData cache. Model bytes are downloaded only when the user eventually dispatches an applicable lane; none were downloaded during implementation.

`PRIVATE_REPO_TOKEN` is optional for private GitHub dependencies and must have access to the required dependency repos. Without it, normal public dependency access is used; an inaccessible private dependency fails visibly. Checkout credentials are not persisted; the optional dependency URL rewrite is removed at job end. No secret values are written into generated project/release assets. Use the existing configured DEVELOPMENT_TEAM from project.yml for local mycli signing; the runner never needs signing certificates/profiles.

Archive and effective build-settings commands pass `-packageAuthorizationProvider netrc` so SwiftPM does not query macOS Keychain for binary-download credentials. This addresses the captured CI stall in `KeychainAuthorizationProvider` / `SecItemCopyMatching`. The public Whisper framework remains a pinned remote binary target; Git dependency access still uses the optional token URL rewrite. No Keychain changes are required.

## Assets and validation

The workflow builds the actual Inkribe iOS device scheme and/or InkribeMac universal scheme with signing disabled. Separate DerivedData/archive paths are used per platform and cleaned after ZIP creation. Before packaging, `scripts/verify_release_archive.py` checks actual archive/app structure, bundle identity, effective project team/entitlement declarations, encryption declaration, executable CPU slices, iPhoneOS platform/Photos usage text, selected iOS build flag and exact copied model bytes. Mac verifies all five models and third-party notices. Unsigned archives have no final signature entitlements; mycli resolves them from the generated project and signs locally.

Each prerelease includes the selected archive(s) plus exactly one generated project ZIP, packaged after dependency resolution. ZIP integrity, expected asset set, archive root, project.pbxproj/shared schemes and per-file 2 GiB limit are checked before publication. The workflow never splits an oversized archive, drops models or substitutes a raw .app/Actions artifact. A size violation fails clearly before creating a release.

| Platform | Example assets (Release) |
|---|---|
| iOS | Inkribe-iOS-release-unsigned-mycli-build-RUN-ATTEMPT.xcarchive.zip + Inkribe-xcodeproj-mycli-build-RUN-ATTEMPT.zip |
| macOS | Inkribe-macOS-universal-release-unsigned-mycli-build-RUN-ATTEMPT.xcarchive.zip + same project ZIP |
| both | Both archives + one project ZIP |

Published prerelease name/tag: `mycli-build-<run-id>-<attempt>`. These are disposable unsigned builds, separate from product version tags. Local `mycli deploy ios --release` / `mycli deploy mac --release` chooses an artifact and performs signing/export/deployment. Keep a matching source checkout with relative packages, resource/entitlement specs and local credentials; the project ZIP is not a source-code replacement.

## Remaining validation and limitations

- No workflow, build/test/typecheck, XcodeGen, real-resource download, archive, local signing/deployment or device validation was run. Static YAML/Python/embedded-shell syntax inspection does not prove Xcode compilation or archive acceptance. The first manual run remains necessary.
- The runner image documentation lists Xcode 26.3; the workflow checks the explicit path and fails if unavailable rather than silently switching compilers. Installed XcodeGen must satisfy project.yml's existing minimum version.
- The five Mac weights total 2,212,332,186 bytes before compression, in addition to native binaries. Whether the final ZIP fits below 2 GiB is unmeasured. Oversized Mac output fails before publication; changing Mac resource policy or mycli's artifact contract needs a separate decision.
- Both app targets use the same existing `InkribeMac/AppIcon.icon`, following Spokio's shared-resource setup. iOS includes that exact file in its resource build phase and selects `AppIcon` for Debug/Release; the bundled-model spec inherits it. Archive validation requires an icon declaration and compiled icon output. The icon is not copied or redesigned; actual compilation/device appearance remains unverified.
- This is the mycli unsigned build lane, not App Store/TestFlight production signing. It does not apply a framework MinimumOSVersion patch, provision developer resources, run tests or upload to Apple.
