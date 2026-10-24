# Inkribe iOS — production readiness record

2026-10-24 (Vietnam). PR #39, five source implementation passes plus consolidation. **Release held for
owner inputs and execution evidence.** This is a reproducible source audit and
validation plan, not a successful runtime report. User retains build/test/device/
CI/export authorization. No signing, store or website resources were provisioned.

## Source audit and owner inputs

| Area | Source truth | Remaining input/evidence |
|---|---|---|
| Privacy destination | Commerce.privacyURL is https://example.com/inkribe/privacy | Replace with an actual published Inkribe policy before release; no URL/policy was invented |
| Terms / support | Apple standard EULA; mailto:hi@spokio.pro | Owner confirm terms suitability, mailbox and store metadata destinations |
| Purchases | com.hoangbkit.inkribe.pro.monthly / .lifetime; simulated $6.99 / $24.99 | Verify live records, agreements, pricing/localization, sandbox purchase/restore and expired entitlements; simulation is not store evidence |
| API privacy manifest | iOS resource now declares app-only UserDefaults CA92.1; disk-write capacity E174.1; app-container/user-selected file metadata C617.1/3B52.1 | Inspect generated archive privacy report, dependency manifests and App Store disclosures; no collection/tracking assertions were inferred from absence of app analytics calls |
| Identity/platform | iOS com.hoangbkit.inkribe, iPhone only, iOS 26; existing shared AppIcon.icon and signing team | User archive/install/signing and actual store records; Mac identity/config/resources preserved |
| Models/runtime | Default spec downloads/caches selected models; bundled-only spec uses its existing model ownership | User choose release lane, verify artifacts/runtime packaging and device memory; no model binaries fetched or runtime performed |
| Storage/upgrade | Package wrapper 1; current document schema 8 reads 1–7; direct atomic editor saves; unchanged job/request wrappers | Verify save/failure/retry/navigation/reopen, job interruption and downgrade limitations. Never downgrade schema-8 metadata in place |
| Network/permissions | User direct-media/model URLs and StoreKit; Photos add-only delivery and Files/Share routes | Exercise rights, URL/transport failures, providers/Photos permissions and disclosures against shipping behavior |
| Fonts | OS-installed faces, native closest-weight/script/emoji fallback; no new bundled font files | Device availability and shaping review. No claim of identical glyphs across platforms/OS releases |
| Footage/license | Candidate for consistent private validation: Tears of Steel, Blender Foundation; official about page lists CC BY 3.0 | Not downloaded, bundled, rendered or used for screenshots. Owner select exact uncaptioned dialogue range, retain required credits/attribution and verify portrait/public promotional rights before reuse |

Apple reason source (reviewed 2026-10-24):
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype

The API reasons follow actual call sites: SpeechModels/UserDefaults and AF theme
state; MediaImporter/SpeechModelStore/MP4Exporter capacity checks; package/repository
and user-selected import metadata validation. Manifest deliberately declares API
reasons only; it is not a substitute for the owner's complete App Store privacy
answers or the final archive's dependency report.

Footage primary sources: https://mango.blender.org/about/ and
https://mango.blender.org/ (credit/portrait-rights notices). Candidate credit:
“Tears of Steel — Blender Foundation, mango.blender.org, CC BY 3.0”; retain the
source's required credits and mark any modifications. No advertising endorsement
or model release is assumed. This reference is for the pending controlled validation
set, not an in-app stock library or an assertion that footage validation occurred.

## Reproducible validation record

| Work | Status | Result/evidence |
|---|---|---|
| Issue #38 / latest develop / PR head and source contracts | Read-only source review | Develop e39e223; passes 1–4 head 31763bb before pass 5; exact new head in PR |
| Catalog/model/codec/motion/reset/access/render/export call sites | Source reviewed | Ten current looks; historical definitions retained; schema 8; rendering uses saved values |
| Whitespace and publication consistency | Source checks | git diff --cached --check plus changed blob hashes and preservation of unmodified remote blobs; no native execution |
| Cross-pass consolidation | Source reviewed | Strict format-2 fields, modal player layers, current render-error callbacks and unified entry-point docs; see CONSOLIDATION.md |
| Shared CaptionStyleTests | Authored, unrun | 12 specifications; existing package test target only |
| Compile/typecheck/build/fixtures/CI/generation | Unrun | Restricted by current instructions |
| Native render/inference/export/import/performance | Unrun | No output files, timing numbers or memory measurements claimed |
| Device UI/gesture/keyboard/themes/VoiceOver | Unrun | SE2 and larger iPhone acceptance pending |
| App Store/live purchases/privacy report/signing/release | Unverified | Owner-only records and authorized archive/device checks required |

After validation is authorized, record exact commit, configuration/model lane,
device/OS, input asset hash/license/range, timing provenance, selected preset ID/
version/resolved values, output profile, expected behavior, actual artifact/result
and failure reproduction for each scenario. Use the same footage/range for every
preset; add Vietnamese/RTL/emoji/long captions, speech–silence–speech, gaps and
trim-boundary cases. Preserve artifacts and unresolved findings. No acceptance
box is passed because the implementation appears correct in source.

## Release gates

- Actual privacy URL and complete owner metadata/disclosures.
- Successful authorized compilation and targeted regression execution.
- Source-to-preview-to-MP4 parity and actual MP4/SRT/audio sync.
- Upgrade/recovery/data-safety, queue/allowance and per-output delivery acceptance.
- Native navigation/keyboard/accessibility/performance on supported iPhones.
- User review of remaining limitations and explicit release/merge instruction.
