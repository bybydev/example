# Manual Build Release for mycli

The user explicitly authorized this release-workflow source setup after Pro PR #31 was squash merged. It overrides the earlier no-CI-setup instruction only for this manual release lane. Nothing has been dispatched, downloaded, generated, compiled, signed or deployed by the agent. App source, product identities, project specs, resource policy and signing entitlements are unchanged. Fast/Full CI are not added.

The contract follows [hoangbkit/guidelines](https://github.com/hoangbkit/guidelines/blob/master/github-actions-workflows.md). `.github/workflows/release.yml` has **only workflow_dispatch**. Opening/merging a PR, pushing a commit or creating a tag never starts it. The workflow runs on macos-26, explicitly selects installed Xcode 26.3, reports ref/SHA/toolchain, has a 90-minute timeout and repository-wide publication concurrency without cancellation. It grants contents:write for prerelease publication, with no signing credentials or App Store Connect access.

## Inputs

| Input | Options | Default |
|---|---|---|
| platform | iOS / macOS / both | iOS |
| configuration | Debug / Release | Release |
| ios_models | download / bundled; ignored for macOS-only | download |

Choose the ref/branch in GitHub's dispatch UI. Checkout uses that selected ref; the prerelease points to the exact checked-out SHA. Debug respects existing `.debug` bundle IDs; Release respects existing production IDs. No CI identity override. One configuration per run.

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
- Current sources have no app icon artwork. A missing declared compiled icon is an error; an archive declaring no icon reports a warning. No placeholder artwork or App Store readiness claim is introduced. Product artwork/privacy/store metadata remain separate production work.
- This is the mycli unsigned build lane, not App Store/TestFlight production signing. It does not apply a framework MinimumOSVersion patch, provision developer resources, run tests or upload to Apple.
