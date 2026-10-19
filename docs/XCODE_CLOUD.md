# Xcode Cloud

ReadAloud uses the committed `ReadAloud.xcodeproj`, shared `ReadAloud`
scheme, and `Package.resolved`. No XcodeGen installation or project/package
regeneration runs in the cloud.

## Repository hooks

| Hook | Responsibility |
| --- | --- |
| `ci_scripts/ci_post_clone.sh` | Apply Spokio's macro/plugin trust settings; check committed project inputs; download, verify, and stage production ONNX assets. |
| `ci_scripts/ci_post_xcodebuild.sh` | After a successful archive, verify the archived app's assets, manifest, license notices, and absence of Core ML models. |

All hooks are executable and automatically discovered by Xcode Cloud. Resource
preparation uses the same commands as the GitHub release workflow:

```sh
python3 scripts/onnx-assets.py download
bash scripts/stage-onnx-resources-for-build.sh
```

Both Debug and Release use the real bundled assets: Kokoro INT8, Misaki G2P
ONNX plus lexicon, and 28 English voices. Downloads run on the build machine;
the app requires no model download. Existing valid files are reused by the
downloader; missing or invalid files are downloaded and verified. Staging
copies only declared assets and license notices.

The target's existing pre-build phase verifies/stages resources again before
the Resources phase. The archive hook verifies the actual bundled files,
rather than relying only on workspace staging.

Test-without-building skips model preparation because it uses
the previously built test products. The archive hook does not run archive
verification for test, build, or analyze actions, or after a failed archive.

ReadAloud does not patch ONNX Runtime framework metadata. The pinned 1.24.2
binary already declares `MinimumOSVersion = 15.1` for both iOS device and
simulator slices. Spokio's Extensions workaround does not apply because
ReadAloud does not link ONNX Runtime Extensions.

## One-time Apple setup

These scripts prepare builds; the workflow and repository permissions are
configured in Xcode/App Store Connect, not by committing a GitHub workflow.

1. Open `ReadAloud.xcodeproj` in Xcode and select the shared `ReadAloud` scheme.
2. In **Product → Xcode Cloud → Create Workflow**, select the ReadAloud app
   (`com.hoangbkit.readaloud`) and connect `hoangbkit/ReadAloud`.
3. Grant Xcode Cloud access to the private package repositories when prompted:
   AppFoundation, EpubKit, PDFKitAudio, TextExtractor, and JobQueue. Include
   any private transitive dependency Apple reports. Cloud resolves packages
   before the post-clone hook; adding a GitHub token to that hook is too late.
4. Select an Xcode/macOS environment supporting iOS 26 and Swift 6.2 or later.
5. Configure an **Archive → iOS → Release** action. Keep automatic signing.
   TestFlight/App Store Connect distribution is an optional workflow setting.
6. Remove automatic branch, PR, tag, and scheduled start conditions; run the
   workflow manually on the selected branch. To try this PR, select
   `codex/screenshot-studio-six-scenes`.
7. If tests are desired, add a separate **Test → iPhone → Debug** action using
   the existing `ReadAloudTests` scheme test target.

No custom environment variables or model-download credentials are required.
Xcode Cloud supplies the `CI_*` variables used by the hooks. Do not configure
Spokio's `SPOKIO_CI_USE_TEST_MODELS` flag; ReadAloud has no fixture mode.

## First-run checks

Review the post-clone log for all 31 verified assets and successful staging.
After Archive, review the post-xcodebuild log for verification of
`ReadAloud.app/ONNX`.

No cloud build, test run, or distribution was started as part of adding these
hooks. The first successful Apple-hosted archive remains the end-to-end check.

## References

- [Apple: Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Apple: Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Apple: Configuring your first Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
- Spokio `ci_scripts/ci_post_clone.sh`
- ReadAloud `.github/workflows/release.yml`
