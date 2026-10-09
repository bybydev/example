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
- [x] MCP saving separates persistence from discovery; post-save warnings remain visible in the server list.
- [x] MCP editor/Tools errors use a local presenter with root fallback, URL elicitation shows its destination, and enum selections initialize backing values.
- [x] Chat and Save Images own Library save errors locally; LibraryView retains its own alert.
- [x] New Library saves enforce the current Free policy inside serialized store mutations; already-listed attachments remain idempotent.
- [x] Library attachment batches preflight composer metadata before loading originals, exclude existing attachment IDs, and retain final composer validation.
- [x] Library source subtitles/search use index-backed chat summaries without hydrating chat shards.
- [x] Project mutations and chat Tools writes share the iOS MCP operation queue; inheritance refreshes before a mutation completes and materialization reads authoritative stores.
- [x] Project editor/list/detail/sidebar errors have local ownership with root fallback; alert dismissal handles only the displayed error, and failed deletion keeps its detail view open.
- [x] Project reference-file imports preflight the entire batch from metadata before reading bytes and validate actual sizes before accepting any additions.
- [x] MCP deletion scrubs Project defaults/presets and chat permissions independently of discovery cache, refreshes both models, and preserves a deletion retry path on persistence/credential failure.

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
- [ ] Test the free limits: 1 connection, 1 project, 1 MCP server, saved files per `BYOKProPolicy.freeLibraryItemLimit`, 2 free themes, basic analytics.
- [ ] Complete the MCP smoke path below on the intended Release/TestFlight build; opening MCP settings alone is insufficient.
- [ ] Complete the Library smoke path below on the intended Release/TestFlight build; opening Library alone is insufficient.
- [ ] Complete the Projects smoke path below on the intended Release/TestFlight build; creating a Project alone is insufficient.
- [ ] Archive Release and run Xcode **Validate App**. Resolve every validation/privacy-manifest warning before upload.
- [ ] Upload the archive to App Store Connect/TestFlight and install that uploaded build once before submission.
- [ ] Generate final App Store screenshots using the `BYOKchat` scheme / `scripts/capture_app_store_screenshots.sh`; inspect the actual PNGs before upload.

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

## MCP release smoke path (issue #36)

Code completion does not mark these checks as passed. Record results for the exact physical-iPhone release build before submission.

- [ ] Add a valid remote MCP configuration while the endpoint is offline. Save dismisses the editor, the server remains visible, and discovery failure appears as a separate warning.
- [ ] Restore endpoint availability and recover using Refresh Tools. Also confirm a disabled server saves without discovery.
- [ ] Enable the server for a chat. Induce an auth/network failure and confirm the Tools sheet presents one error without a duplicate root alert.
- [ ] Run an Ask-policy tool and choose **Allow Once**.
- [ ] Run an Ask-policy tool and choose **Deny**.
- [ ] Choose **Always Allow** and confirm the next call no longer prompts.
- [ ] Relaunch and verify server configuration, credential access, chat exposure, and permissions persist.
- [ ] Exercise a form with a required single-option enum, a valid default, and an invalid default. The visible selection matches the submitted value without requiring a change first.
- [ ] Exercise URL elicitation. The destination is visible before opening; the displayed URL matches the link; Cancel / Decline / Continue work.
- [ ] Cancel generation while awaiting an approval or elicitation and confirm the pending interaction clears.

Validation results: **not run**. Replace this note with the build identifier, device, and results after completing the smoke path.

## Library release smoke path (issue #40)

Code completion does not mark these checks as passed. Record results for the exact physical-iPhone release build before submission.

- [ ] Manually add an image and a document; preview and share both.
- [ ] Attach a saved Library item to a fresh chat and to an existing chat. Items already pending in the composer are excluded from both picker tabs.
- [ ] With existing composer attachments, reject an entire selected batch that exceeds 8 attachments, 20 MB per item, or 40 MB total. Confirm no selected originals are loaded for a rejected batch, and a valid batch appends normally.
- [ ] Save a sent attachment to Library and an assistant response as Markdown. Induce missing-blob/storage failures and confirm one Chat-owned Library alert; dismissing it leaves unrelated errors untouched.
- [ ] Save remote and embedded response images. Induce fetch/storage failures and confirm one local Save Images alert, with unsaved selections retained for retry and successful saves excluded from retry.
- [ ] At the current `BYOKProPolicy.freeLibraryItemLimit`, a new attachment save opens the Pro upsell. Repeat saving an already-listed attachment: no duplicate entry or upsell. With one Free slot remaining, overlap saves and confirm only one new entry is committed.
- [ ] Verify Pro saves are unrestricted by item count; after entitlement loss, existing entries still open, preview, share, and attach.
- [ ] Open Library with entries from many chats and verify source labels/search match current chat titles without loading chat shards. Deleted source chats fall back to Chat; Open Source Chat keeps its existing behavior.
- [ ] Delete a Library entry still referenced by a chat and confirm the chat attachment remains available.
- [ ] Delete the final owner and confirm orphan cleanup eventually removes the blob.
- [ ] Relaunch and verify entries, thumbnails, and source labels remain correct.

Library validation results: **not run**. Replace this note with the build identifier, device, and results after completing the smoke path. Library is ready for iOS 1.0 only after this path passes.

Deferred to iOS 1.0.1/later: bounded response-image downloads and strict image-signature checks; preserving file-type semantics on rename. These are outside issue #40's 1.0 implementation.

## Projects release smoke path (issue #44)

Code completion does not mark these checks as passed. Record results for the exact physical-iPhone release build before submission. These checks require explicit authorization before the assistant runs them.

- [ ] Create a Project with provider/model defaults and instructions. Create a new Project chat and verify those defaults. Edit the Project defaults and confirm existing chats keep their current provider/model.
- [ ] Add Project reference files and attach one from the composer; create/apply a reusable prompt preset.
- [ ] Configure different MCP defaults in Projects A and B. Add a standalone chat to A, move it to B, then remove it. Tools immediately reflects the current inheritance at each step.
- [ ] Immediately customize a server toggle/permission after each membership change. Repeat with overlapping actions and Always Allow approval persistence; the explicit override must use current inheritance. An existing explicit override survives membership changes.
- [ ] Trigger duplicate-name/preset validation, import/read, and storage failures where reproducible. The active Project sheet/list/detail/sidebar displays one local error, retains unsaved editor state, and root does not duplicate it.
- [ ] Dismiss a Project error while another Project or provider/chat/MCP error is pending. Only the displayed error is acknowledged; remaining errors stay available. Verify root fallback when no local Project surface is visible.
- [ ] With existing and unsaved Project files, reject selections exceeding 8 files, 20 MB per file, or 40 MB combined before reading selected payloads. Unknown size metadata is visibly rejected. Check failed reads/changed sizes where reproducible: accept no subset and keep the previous file list. Valid batches append normally.
- [ ] Delete an MCP server used by multiple Project defaults, tool presets, and explicit chat permissions. Verify its IDs/policies disappear, other settings and preset identities remain, summaries update, and inherited chat Tools refreshes. Repeat after invalidating/changing discovery so older policy keys are covered.
- [ ] Where reproducible, fail Project cleanup, Keychain cleanup, or MCP deletion persistence. The server remains available for deletion retry, partial cleanup is reflected accurately, no full-success message appears, and retry completes. A failed MCP commit restores its previous credential; restoration failure is reported explicitly.
- [ ] For imported server IDs sharing the same eight-character tool namespace, deletion with ambiguous policies reports a clear error and preserves the server and permissions rather than guessing ownership. Remove conflicting permissions and retry.
- [ ] Fail Project deletion where reproducible: detail remains open and its chats survive. Retry successfully: the view exits and its chats become standalone.
- [ ] Relaunch and verify membership, files, defaults, prompts, permissions, and successful server cleanup persist.

Projects validation results: **not run**. Replace this note with the build identifier, device, and results after completing the smoke path. Projects is ready for iOS 1.0 only after this path passes.

Implementation boundaries: no Projects architecture redesign or macOS UI changes. The coordinated server deletion commits Project cleanup first, then removes the credential and commits MCP deletion, restoring the credential if that commit fails. Stores remain separate persistence domains; a later-stage failure can leave already-committed Project cleanup in place, and the retained server allows idempotent retry. Existing exposed names and empty-configuration semantics are preserved.

Deferred to iOS 1.0.1/later: empty Project MCP configuration normalization; earlier preset-limit/name validation UX; missing Project-file blob reconciliation; Sources preview/open. Separate explicit-empty chat-override semantics are also outside issue #44.


## Provider model editor

- [ ] Add a built-in connection from the generic Add flow: suggested models are visible immediately and Fetch uses the default endpoint.
- [ ] Type a complete model ID character by character, edit/delete it, then Save directly or use Use Model ID. Repeat with a populated catalog and NVIDIA.
- [ ] Open the searchable picker for DeepSeek, OpenAI, OpenRouter, and a compatible server; select a model and return without losing fetched results.
- [ ] Create an OpenRouter connection after Fetch, Save, and relaunch: all fetched models, context/capability metadata, and model pricing survive.
- [ ] Create a compatible connection using only the main endpoint field. Verify bearer/header/no-auth modes, optional empty models path, and private-network HTTP.
- [ ] Edit an endpoint, replacement key, headers, or OpenRouter metadata before Fetch: requests use the form values. Leaving the key unchanged uses Keychain.
- [ ] Fetch in edit mode, then Cancel or swipe-dismiss: stored account, credential, model list, and default remain unchanged.
- [ ] Change provider/configuration while discovery runs: old results never repopulate the new draft. Switching provider clears the old key/model selection.
- [ ] Failed or empty discovery leaves manual input usable; malformed headers are shown before discovery.
- [ ] Save an edited model catalog/default and relaunch: favorites/hidden flags and manual models survive refresh; models omitted from a potentially partial API list remain available in the cached catalog.
- [ ] A hidden/unavailable saved default requires an explicit valid selection or manual ID before Done; saving that choice makes it usable for new chats.
- [ ] Saving failure stays in the editor with an error; retry creates no duplicate connection.

## Clean new-chat launch

- [ ] Cold-launch with a ready saved connection: the launch background transitions directly to the hydrated new-chat composer, with no "Open Chat" or provider-setup screen in between.
- [ ] Cold-launch without a usable connection: show the appropriate connection/model setup state after loading finishes; do not create an invalid chat.
- [ ] Fail initial chat persistence: present startup recovery/Retry instead of a stuck opening screen. Retry uses the existing unsent-chat recovery path.
- [ ] Repeated New Chat taps, switching from Library/Providers, and project New Chat open one session without flashing the setup CTA or adding empty chats to history.

## AppFoundation 1.6.4 migration smoke path (PR #51)

The iOS target uses AppFoundation 1.6.4. XcodeGen's `project.yml`, the generated Xcode project, and SwiftPM's resolved revision must agree. Offline verified entitlement caching is intentionally **not enabled**; this migration retains the existing live StoreKit policy.

- [ ] Cold-launch Free with a previously selected Pro-only theme: show the committed Free theme while entitlements are checking, and remain Free after confirmation without a Pro-theme flash.
- [ ] Cold-launch with an active monthly, yearly, or lifetime Pro purchase: entitlement resolves to Pro and the saved Pro theme becomes available without manual relaunch. Check this after temporarily failing product-catalog loading.
- [ ] Downgrade/expire Pro, force-quit, relaunch repeatedly, and verify the Free theme persists; restoring Pro restores the remembered Pro preference. Selecting an explicit Free theme while expired keeps that preference after renewal.
- [ ] Exercise a Pro theme preview, purchase while previewing, cancel purchase, and expire a preview across relaunches; verify theme promotion/rollback and countdown behave correctly.
- [ ] In Settings, open the Pro plan section, restore purchases, change subscription management, and verify monthly/yearly/lifetime product types, introductory offer copy (if eligible), pending purchase state, and the main paywall's **analytics history** wording.
- [ ] Toggle simulated purchases in Debug Developer Tools, grant and revoke simulated Pro, restart the app, and verify themes and historical analytics match effective entitlement without stale access.
- [ ] Build and exercise the iOS target with Xcode 26 / Swift 6.2; verify the AppFoundation dependency resolves to tag `1.6.4`. Neither the macOS MacAppFoundation dependency nor macOS views are changed by this migration.

AppFoundation migration validation results: **source/API compatibility reviewed; build, tests, and physical-iPhone smoke checks not run**.

## Analytics release smoke path (issue #46)

Analytics uses remaining saved chat history, not a provider billing ledger. Regeneration, editing earlier turns, and deletion can reduce Spend and Monthly Budget totals. Free and Pro both disclose this. Budget warnings exclude other-app API usage and do not enforce provider limits.

Code completion does not mark these checks as passed. Record the exact Release/TestFlight build and physical iPhone results before submission. No CI setup or dispatch is part of this issue.

- [ ] Free can select Today and access **all** analytics sections (usage, performance, reliability, errors, provider/model breakdowns, conversation details, budget and local telemetry) for today's data. Each 7D/30D/Month/All range button shows an inline lock icon (not a separate upgrade banner); tapping **each** locked button opens the historical-analytics Pro upsell without revealing older values. VoiceOver announces that each is locked and requires BYOK Pro.
- [ ] Pro can select Today/7D/30D/Month/All with the same analytics features; the old Basic/Advanced distinction is absent from the dashboard and paywall comparison.
- [ ] Downgrade from Pro while a historical range or per-conversation detail is open: visible aggregates and details immediately clamp to Today. Restoring Pro allows historical selection again without deleting saved data.
- [ ] Free budget controls evaluate today's portion only and clearly disclose that the month is incomplete; Pro uses the full current-calendar-month total regardless of the selected display range. Telemetry counts, performance and breakdowns respect the accessible date range.
- [ ] History-mutation copy is visible in Free/Pro analytics and per-conversation details.
- [ ] Regenerate, edit an earlier turn, and delete a chat; remaining-history totals follow the copy.
- [ ] Compare complete reported cost, complete estimate, partial calculation, and unavailable cost in Analytics, Message Info, conversation details, and provider/model rows. Estimates never claim a guaranteed minimum.
- [ ] Exercise missing input/output prices and usage, explicit zero prices/tokens, and a tool round with missing usage followed by a priced round. Known subtotals remain, and completeness does not recover from summing unknown usage as zero.
- [ ] OpenRouter non-streaming and final streaming cost (including zero) override prices. Multiple tool rounds use final totals once; mixed reported/estimated rounds retain all known costs. BYOK fees remain scoped/incomplete without verified full upstream semantics.
- [ ] xAI reported USD ticks remain preferred; native cache reads/writes, Anthropic write duration, Gemini thinking output/cache storage, OpenAI context tiers, and DeepSeek time buckets remain accurate or explicitly incomplete.
- [ ] Offline catalog fallback, unknown exact IDs, invalid catalog data, and custom endpoints do not invent pricing. See [covered IDs and pricing rules](ModelPricing.md).
- [ ] Generate a new direct DeepSeek Flash response using the default endpoint and `/v1`: legacy `deepseek-v4-flash` / `deepseek-v4-flash-vision-exp` requests may return `deepseek-flash` without losing estimated cost. A genuine Flash-to-Pro change stays unavailable. Inspect the saved source, verification date, and official pricing link in Message Info; relaunch preserves the amount in the lightweight index. Older missing snapshots are not retroactively priced.
- [ ] For new unavailable receipts, Message Info explains missing supported pricing, missing request usage, changed model/account configuration, or an unsupported billing mode instead of only a generic unavailable explanation.
- [ ] Edit a custom account endpoint/configuration after discovering prices: its cached rates disappear, model selections/capabilities remain, and old in-flight discovery cannot restore stale rates. Refresh discovers new rates; renaming retains them. Change the endpoint between tool rounds and verify the next round does not borrow the turn's original rates.
- [ ] Cancel or fail the transport after a provider completion event: the observed usage/cost remains in Message Info, Analytics, and the lightweight index after relaunch. The completed request is not also counted as a failed provider request. Cancellation before completion remains incomplete/unknown.
- [ ] Relaunch and inspect the lightweight index: numeric costs, completeness, source/version, and per-request rules remain stable after model/catalog price changes, without hydrating all chat shards.
- [ ] Budget distinguishes no requests, all unknown costs, partial cost, and complete cost; incomplete costs below threshold show uncertainty rather than headroom. Partial/estimated threshold warnings identify the recorded subtotal/estimate. Budget remains current-calendar-month while another range is selected.
- [ ] Successful empty and populated telemetry loads render correctly. Fail the events read and the statistics read separately; neither failure appears healthy empty or valid zero. Check disabled recorder, failed Retry, and successful Retry.
- [ ] Telemetry failure keeps usage/spend usable, hides untrusted performance/reliability throughout, and exposes no raw storage error in ordinary Analytics.

Analytics validation results: **not run on device**. Swift package regression tests are added but **not executed in the implementation workspace (Swift/Xcode unavailable)**. Replace these notes with actual results before release.

## Composer target label polish (PR #49)
- [ ] Verify iOS composer shows “DS V4.1 Flash” instead of the long “DeepSeek-V4.1-Flash · Default…” label, including after changing model and reasoning in the picker.
- [ ] Verify provider defaults omit the effort suffix, explicit Medium/High/Off still show succinctly, model families from OpenRouter remain identifiable, and custom providers use compact initials when needed.
- [ ] VoiceOver announces full provider/account, unabridged model name and reasoning even when the visual chip is shortened.

## Manual model removal (PR #49)
- [ ] Add a custom ID in Provider Settings; swipe left or long-press the model in Choose Model to remove it. Cancel must preserve it; Done must remove it across relaunch.
- [ ] Delete a saved custom ID from composer in both flat (≤5) and pushed (6+) layouts. Cancel discards deletion; Done commits. Deleting the selected model requires a replacement model for a chat.
- [ ] Enter a brand-new model ID in composer, then use Clear entered ID before Done; it must not persist or leave a stale selection.
- [ ] Removing the provider's only manual default in Connection Settings clears its default and allows reconfiguration. Catalog-only models cannot be deleted through this action.
- [ ] Confirm existing chats retaining a deleted model ID do not lose history; removing the default updates the connection's fallback without silently rewriting chat targets.

## Composer model picker (issue #50)
- [ ] For 0–5 models, select inline and confirm reasoning stays directly below the model list.
- [ ] For 6+ models, tap **anywhere** on the selected-model row (title, empty middle, far trailing edge). The pushed searchable list opens on the **first tap** even with 400+ cached models; Back preserves selection. Switch providers and recheck the threshold.
- [ ] Enter an exact model ID absent from provider discovery, cancel to discard, then Done to persist and select it. Confirm it appears in Provider Settings after relaunch.
- [ ] Open an old connection with saved models while offline; keep cached choices available. Retry manual refresh, then verify newly discovered models appear without navigating to settings.
- [ ] Verify favorites, hidden states, manual IDs, previous selection, and reasoning survive discovery failures and partial lists without duplicate global alerts.
