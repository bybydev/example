# ReadAloud CI and Release Contract

> Status: GitHub Release and Xcode Cloud repository hooks are implemented.
> Fast CI and Full CI remain deferred. Xcode Cloud workflow activation and
> private dependency access are configured in Apple tooling; see
> [Xcode Cloud setup](XCODE_CLOUD.md). Local shipping checks remain in
> `RELEASE_CHECKLIST.md`.
>
> The implemented GitHub Release workflow and Xcode Cloud hooks always bundle
> real ONNX INT8/G2P/voice resources. Fixture-mode sections below describe the
> deferred blueprint, not the current Release workflow.

## Purpose

The long-term setup uses three primary GitHub Actions workflows:

```
.github/workflows/
├── fast-ci.yml
├── full-ci.yml
└── release.yml
```

All three workflows are **manual-only** and must be runnable against any selected branch/ref.

There are no automatic push or pull-request triggers.

---

## Global workflow rules

Every primary workflow uses:

```yaml
on:
  workflow_dispatch:
```

Do not add:

- `push:`
- `pull_request:`
- scheduled CI
- branch hardcoding to `master` or `develop`

The workflow must operate on the ref selected when it is dispatched.

For checkout, prefer:

```yaml
- name: Checkout selected ref
  uses: actions/checkout@v6
  with:
    ref: ${{ github.ref }}
    fetch-depth: 0
```

Using the event checkout SHA without an explicit `ref` is also acceptable when it preserves the selected dispatch ref, but never override it with a fixed branch.

Concurrency must remain branch/ref-aware:

```yaml
concurrency:
  group: <workflow>-${{ github.ref }}
  cancel-in-progress: true
```

Release uses `cancel-in-progress: false`.

---

## Resource and distribution matrix

Build configuration controls optimization and debug behavior; it does not by itself identify a shipping artifact. Resource mode and distribution eligibility must be explicit.

| Purpose | Configuration | Resources | Runtime admission | App Store Connect |
| --- | --- | --- | --- | --- |
| Fast CI / development | Debug | fixture | `.executableFixture` | Never |
| Full CI / manual development artifact | Debug, Release, or both | fixture | `.executableFixture` | Never |
| Deliberate real-resource validation / development artifact | Debug, Release, or both | real | `.productionOnly` | No automatic upload |
| TestFlight / App Store shipping | Release | real | `.productionOnly` | Eligible only after shipping checks/signing |

Fixture admission must be selected through an explicit build resource setting and compiled into the development artifact. A runtime environment flag must not be able to turn a shipping artifact into fixture mode.

All fixture builds use profile-aware fixture validation for the released single 15-second bucket. Real builds retain production provenance, checksum, bucket, and voice checks. A Release-optimized fixture build must not fail merely because its compiler configuration is Release.

Shipping packaging additionally invokes KokoroCoreML's production staging guard before model compilation, rejects synthetic model metadata even if the manifest is relabeled, and prohibits fixture uploads. Any future upload action must fail before packaging/upload when `resources != real`; real resources alone do not authorize an upload.

## Important GitHub dispatch behavior

The workflow files need to exist on the repository's default branch before they can be relied on as repository-wide manual workflows.

Once the workflow definitions are established on the default branch, dispatch them against the branch/ref being validated.

The selected ref is the source of truth for:

- source code
- `project.yml`
- checked-in Xcode project
- `Package.resolved`
- scripts
- fixture assets
- release artifacts

This allows feature branches and stacked PR branches to validate their own code before merge.

---

# 1. Fast CI

File:

```
.github/workflows/fast-ci.yml
```

## Goal

Provide the cheapest useful implementation check for the currently selected branch.

Fast CI should prove that ordinary ReadAloud development is structurally healthy without downloading the production Kokoro model set.

## Trigger

Manual only:

```yaml
on:
  workflow_dispatch:
```

## Resources

Use fixture Kokoro assets only.

Fast CI must:

- never download real production Kokoro models
- use the executable fixture-model path once Phase 0A is available
- fail clearly if fixture assets are missing or incompatible

## Intended checks

Fast CI should cover:

- repository/config validation
- XcodeGen/project consistency where applicable
- Swift package resolution against the checked-in lockfile
- fixture resource staging/validation
- iPhone Debug build
- unit tests that do not require real model quality/performance
- executable Kokoro fixture integration checks where relevant

Do not include:

- real Kokoro model download
- production archive/signing
- App Store upload
- UI tests by default
- screenshot/browser verification

## Runner

Use the current standard Apple Silicon runner/toolchain used by sibling packages, presently:

```
runs-on: macos-26
Xcode 26.3
```

Keep toolchain selection explicit so CI does not silently change behavior with runner defaults.

## Concurrency

```yaml
concurrency:
  group: fast-ci-${{ github.ref }}
  cancel-in-progress: true
```

Two different branches must not cancel each other's Fast CI runs.

---

# 2. Full CI

File:

```
.github/workflows/full-ci.yml
```

## Goal

Perform comprehensive validation of the selected branch before important merges/releases.

Full CI remains manually invoked.

## Trigger

```yaml
on:
  workflow_dispatch:
    inputs:
      resources:
        description: Kokoro resources
        required: true
        default: fixture
        type: choice
        options:
          - fixture
          - real
```

The exact input set may grow if a real need appears, but branch selection comes from the workflow dispatch ref rather than a custom branch string.

## Fixture mode

Default to fixture resources.

This should cover the broad application validation path without multi-GB downloads.

## Real-resource mode

When explicitly selected:

- restore/download the pinned real Kokoro asset set
- verify SHA-256/provenance
- reject stale/mismatched assets
- exercise real resource loading/build integration

Real-resource mode is for deliberate validation, not every run.

## Intended checks

Full CI should be a superset of Fast CI:

- all Fast CI validation
- Debug and Release configuration builds using the selected explicit resource mode
- complete unit/integration test suite appropriate to the app
- project persistence/import contracts
- EpubKit/PDFKitAudio/TextExtractor integration
- JobQueue recovery contracts
- fixture Kokoro end-to-end pipeline when `resources=fixture`
- real Kokoro resource validation when `resources=real`
- resource/distribution separation checks independent of compiler configuration
- shipping rejection checks proving fixture assets cannot enter a production shipping artifact (without requiring real model downloads in default fixture mode)

UI tests are **not automatically required** merely because the workflow is called Full CI. Add/run them only when explicitly designed and approved for a specific need.

## Concurrency

```yaml
concurrency:
  group: full-ci-${{ github.ref }}
  cancel-in-progress: true
```

---

# 3. Release

File:

```
.github/workflows/release.yml
```

## Status

Implemented.

## Goal

Create one unsigned iOS mycli artifact from exactly the branch/ref selected by
the user. The workflow is for local deployment/manual QA, not direct App Store
upload.

Release must never silently switch to `master` or `develop`.

## Trigger and inputs

Manual only:

```yaml
on:
  workflow_dispatch:
    inputs:
      configuration:
        description: Build configuration
        required: true
        default: Release
        type: choice
        options:
          - Debug
          - Release
      resources:
        description: Kokoro models
        required: true
        default: fixture
        type: choice
        options:
          - fixture
          - real
```

Exactly one configuration/resource combination is built per run, so mycli sees
one compatible iOS archive in the generated prerelease.

Additional explicit App Store/TestFlight actions can be added later, but the selected branch/ref remains authoritative.

## Selected ref

Checkout:

```yaml
- name: Checkout selected ref
  uses: actions/checkout@v6
  with:
    ref: ${{ github.ref }}
    fetch-depth: 0
```

Capture the exact release commit:

```sh
git rev-parse HEAD
```

Any GitHub release/prerelease must target that SHA.

Never create an artifact from one branch and tag another commit.

## Fixture release

Fixture mode is useful for:

- quick installable development artifacts
- mycli deployment
- branch-specific manual QA

Fixture artifacts may use Debug or Release optimization. They must be clearly marked as non-production and must never be uploaded to App Store Connect. Both their staging validator and runtime admission use explicit fixture mode; they do not bypass production checks by relabeling synthetic assets.

## Real release

Real-resource mode must:

- obtain the pinned production Kokoro assets
- verify checksums and runtime provenance
- fail if fixture resources are present
- build from the selected branch/ref
- be the only resource mode eligible for TestFlight/App Store delivery, with Release configuration, shipping guards, and explicit distribution action

## Artifact identity

Temporary/manual GitHub build releases should follow the established mycli-style pattern, e.g.:

```
mycli-build-<run-id>-<attempt>
```

Artifacts should encode enough context to distinguish:

- iOS
- configuration
- fixture vs real where useful
- release tag/run identifier

## Concurrency

```yaml
concurrency:
  group: readaloud-release-${{ github.ref }}
  cancel-in-progress: false
```

A release should not be cancelled because another run starts.

---

# Branch behavior examples

All of these must be valid manual workflows:

```
develop
feature/project-store
feature/import-pipeline
feature/reader
fix/playback-resume
stack/queue-prefetch
```

Example:

```
Run workflow
  workflow: Fast CI
  branch: feature/project-store
```

must validate `feature/project-store`, not `develop`.

Likewise:

```
Run workflow
  workflow: Release
  branch: feature/reader
  resources: fixture
  configuration: Debug
```

must create its artifact from the exact commit selected on `feature/reader`.

---

# Workflow ownership

The workflows validate the application; they do not change dependency/source-of-truth policy.

Rules:

- `project.yml` remains authoritative
- checked-in generated Xcode project and `Package.resolved` remain owner-managed
- workflows may validate/regenerate into temporary CI state if deliberately designed, but must not commit generated changes
- fixture resources are deterministic development assets
- production resources are verified separately
- no workflow mutates source branches

---

# ReadAloud CI acceptance criteria

CI setup is complete when:

1. Fast CI is manual-only.
2. Full CI is manual-only.
3. Release is manual-only.
4. None has push/PR/schedule triggers.
5. All operate on the selected dispatch ref.
6. No workflow hardcodes `master` or `develop` checkout.
7. Branch-aware concurrency prevents unrelated branches from cancelling each other.
8. Fast CI uses fixture resources and no production model download.
9. Full CI defaults to fixtures and can explicitly validate real resources.
10. Release can create fixture development artifacts from any branch.
11. Only real-resource release mode can progress toward TestFlight/App Store.
12. Production shipping validation rejects fixture resources and synthetic model metadata; Release-optimized fixture development artifacts remain supported.
13. Release artifacts identify the exact source commit.
