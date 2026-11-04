# Xcode Cloud

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
