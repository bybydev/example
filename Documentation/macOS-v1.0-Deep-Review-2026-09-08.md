# BYOKchat macOS — Working App Review

**Reviewed baseline:** `develop` at `b39661c50c109e30b48c361ae95a0248cfde2c9d`  
**Immediate goal:** make the native macOS app reliable and complete as a working product before spending time on App Store packaging, screenshots, metadata, or submission mechanics.  
**Scope:** startup, window shell, chat, providers/models, attachments, Projects, Library, MCP/tools, Analytics, settings/themes, purchases, storage/recovery, and functional regression coverage.

---

## Phase 1 implementation status

Phase 1 implementation is now in progress on this PR.

Completed in code:

- fixed single-conversation deletion so the persisted delete is the primary operation and MCP/Project cleanup failures become warnings;
- stopped clearing Mac presentation state before the persistent delete succeeds;
- preserved/resumed drafts when a delete fails;
- added revision-safe debounced draft persistence so stale tasks cannot overwrite/remove newer draft work;
- prevented runtime conversation reloads from clobbering a newer local debounced draft;
- blocked duplicate sends while a conversation is already generating;
- rolled back a newly-created empty conversation when its initial Project assignment fails;
- made Mac startup service composition injectable while preserving the production secure default, allowing startup/retry/recovery to be tested without production Keychain state;
- added Mac chat-session correctness tests;
- added Mac startup/retry/recovery/reset integration tests.

Reviewed without a forced rewrite:

- `ChatRuntime` already owns durable edit/regenerate/cancel semantics and has shared-core regression coverage for linear-history truncation, regeneration, and cancelled partial-output persistence;
- the Mac composer already disables send/edit input while the current conversation is streaming and routes the active send button to `stop`;
- no additional Mac-specific edit/regenerate/stop defect was found in the static review, so those working shared-runtime paths are being left intact instead of changed speculatively.

Still required before Phase 1 can be called validated:

- compile and run the new `BYOKmacTests` with Xcode;
- manually exercise send → stop, regenerate, edit/resend, delete, draft persistence, startup retry, Start Fresh, and Reset using the running Mac app;
- fix any behavior exposed by those runs before moving to Phase 2.

No App Store packaging work belongs in this phase.

---

## Decision

The Mac app already has enough features. The next work should be almost entirely **functional hardening**.

Do not spend the next development cycle on:

- screenshots;
- App Store metadata;
- review notes;
- archive/submission polish;
- version/plist cleanup unless it blocks running/testing the app;
- documentation cleanup unrelated to implementation;
- new provider families;
- new MCP protocol scope;
- another navigation redesign.

The practical goal is:

> **A user can launch BYOKchat, connect a provider, chat for a long session, use files/projects/tools, quit/relaunch, and manage their data without encountering broken state or misleading behavior.**

Current classification: **feature-complete Mac beta that needs functional stabilization.**

---

# Priority order

## P0 — make core app flows trustworthy

1. Startup and recovery must never strand the user.
2. Conversation create/send/stop/regenerate/edit/delete must remain consistent.
3. Provider/model selection must never leave a chat targeting an unusable configuration without clear recovery.
4. Drafts and pending attachments must not disappear on failed sends or navigation.
5. Project/Library/MCP cleanup must not leave the UI lying about what actually happened.
6. The custom window/sidebar/titlebar shell must behave correctly during normal Mac use.

## P1 — make all major product surfaces work end-to-end

1. Provider lifecycle.
2. Attachments.
3. Projects.
4. Library.
5. MCP approvals/elicitation and inheritance.
6. Backup/import/reset/recovery.
7. Free/Pro gates and purchases.
8. Analytics/diagnostics.

## P2 — confidence and polish

1. Mac behavioral tests around the orchestration layer.
2. Small UI smoke suite.
3. Keyboard/focus/accessibility regression pass.
4. Performance with long chats and large local workspaces.

Everything related purely to App Store presentation can wait until the app itself is solid.

---

# 1. Startup, persistence, and recovery

## Current state

This area is structurally strong:

- explicit startup stages;
- storage prepared before service composition;
- providers/projects/MCP/conversation summaries/Library loaded in stages;
- full conversation shards stay lazy;
- startup failure has Retry, Finder access, diagnostics, and safe recovery;
- “Start Fresh” moves the workspace aside instead of deleting it;
- full reset keeps a recovery copy and separately cleans credentials/telemetry.

## What still needs proof

There is very little Mac-specific regression coverage for these paths.

Test and fix:

- clean first launch;
- relaunch with an existing workspace;
- corrupt/missing storage components;
- failure during provider load;
- failure during MCP load;
- failure during project/library reconciliation;
- Start Fresh recovery;
- recovery backup pruning;
- full reset then immediate continued use;
- backup merge and replace;
- partial restore failure followed by reload.

### Functional exit gate

A failure at startup must always end in one of two states:

- the original workspace is usable; or
- a new workspace is usable and the previous bytes are still recoverable.

No dead-end startup state.

---

# 2. Chat lifecycle — highest-value area

`MacChatSessionModel` is the most important Mac-specific model because users spend most of their time here.

## Strong behavior already present

- virtual new chat until first send;
- lazy hydration;
- search;
- debounced draft persistence;
- send/edit/regenerate/stop;
- provider/model/reasoning affinity;
- streaming presentation coalescing;
- tool-call state;
- pending attachment retention.

## Confirmed correctness problem: delete semantics

Single-conversation deletion previously deleted the conversation first, then removed MCP/project metadata in the same `do/catch`.

That meant:

1. conversation deletion could succeed;
2. secondary cleanup could fail;
3. the method could report `false` even though the conversation was already gone;
4. summary reload could be skipped.

This is now fixed in Phase 1: primary deletion is authoritative, secondary cleanup is best-effort, presentation state is removed only after primary success, and the effective summary list is refreshed after deletion.

## Required chat regression matrix

- first send creates exactly one conversation;
- new-chat draft survives provider setup detour;
- failed pre-turn request preserves draft;
- failed pre-turn request preserves pending attachments;
- successful send clears the correct draft only;
- stop generation leaves persisted chat in a stable state;
- regenerate replaces/extends the correct assistant turn without duplicating the user turn;
- edit-and-resend truncates the intended tail only;
- delete during/after generation behaves correctly;
- switching conversations while one streams does not corrupt either chat;
- quit/relaunch restores conversation and draft state;
- changing provider/model on an existing chat updates only that chat;
- unavailable provider/model produces a recoverable UI state.

---

# 3. Custom Mac shell and window behavior

PR #20 introduced the custom shell/titlebar/sidebar. This is now the newest high-risk UI code.

The design direction is fine; do not redesign it again. Stabilize it.

## Must work reliably

- app launch and initial focus;
- traffic lights;
- drag window from custom titlebar regions;
- minimize/restore;
- full-screen enter/exit;
- resize down to minimum size and back up;
- sidebar show/hide repeatedly;
- Command-N;
- Command-K;
- Command-Comma;
- Command-Period while generating;
- selecting chats quickly;
- opening/closing utility sheets;
- opening/closing Settings;
- closing and reopening the main window;
- theme changes with sheets/windows open;
- focus returning to composer after expected actions.

## Important UX concern

The shell should never make core chat interaction feel fragile. If titlebar/window tricks cause focus, dragging, or sizing bugs, fix those before polishing any secondary surface.

---

# 4. Providers and models

The Mac wrapper is functionally broad enough already.

## Required working flows

- create built-in provider connection;
- save/replace credential;
- refresh models;
- choose default model;
- test connection;
- disable/re-enable account;
- delete account;
- manual model;
- favorite/hide model;
- OpenRouter metadata behavior;
- OpenAI-compatible custom endpoint;
- custom headers/auth/path configuration;
- invalid credential;
- unavailable model;
- selected account becomes disabled;
- selected model disappears after refresh;
- Free connection cap;
- Pro unlock.

## Important behavior rule

Existing chats should fail gracefully when their saved provider/model is no longer usable. The UI should guide the user to select another valid target instead of silently switching or becoming stuck.

---

# 5. Attachments

Attachments are already feature-rich enough.

## Required working flows

- Files picker;
- Finder drag/drop;
- clipboard image paste;
- normal file attachment;
- image attachment;
- attachment-only message;
- mixed attachments;
- too many files;
- oversized file;
- combined-size limit;
- switch chats with unsent attachments;
- failed send then retry;
- persisted attachment preview after relaunch;
- reuse Project file;
- reuse Library file.

The important invariant is simple: **navigation or a failed request must not silently lose user-selected files.**

---

# 6. Projects

Projects are already broad enough for 1.0.

Test actual workflows rather than presentation enums:

- create project;
- rename/edit/delete project;
- project instructions inherited by new chat;
- provider/model defaults inherited by new chat;
- project files available to chat;
- prompt preset populates composer;
- MCP/tool defaults inherited;
- move an existing conversation into/out of project;
- open project conversation;
- delete project while keeping its conversations usable;
- Free one-project limit;
- existing projects remain usable after Pro entitlement loss.

No Project redesign before these flows are boringly reliable.

---

# 7. Library

The Library feature set is sufficient.

Test:

- import file;
- preview;
- rename;
- delete;
- attach to new chat;
- attach to existing chat;
- save assistant response;
- save chat attachment without accidental duplicate storage;
- open source conversation;
- source conversation was deleted;
- Free 10-file cap;
- existing items remain usable after entitlement loss.

The current NotificationCenter source-chat bridge is acceptable for now. Do not refactor it unless testing shows a real navigation bug.

---

# 8. MCP and tools

The protocol/runtime layer is already shared and mature. Focus on the Mac interaction layer.

Test with one deterministic MCP server:

- add server;
- authenticate;
- discover tools;
- enable/disable server;
- enable tool in chat;
- Ask → Allow Once;
- Ask → Deny;
- Ask → Always Allow;
- verify Always Allow survives relaunch;
- project-inherited tools;
- per-chat override;
- tool error;
- form elicitation;
- URL elicitation;
- remove server while chats reference it;
- Free one-server limit;
- Pro unlock.

## Critical invariant

Tool approval state must never accidentally become more permissive because persistence failed.

The existing `Always Allow` path already leans in the safe direction; keep that behavior.

---

# 9. Backup, import, reset, and destructive operations

This is high-risk because users may have valuable local history.

Test:

- full backup export;
- merge import;
- replace import;
- provider configuration import/export;
- imported credentials remain intentionally absent;
- delete all conversations;
- delete all credentials;
- reset all application data;
- recovery folder created;
- app works immediately after reset;
- partial cleanup failures shown as warnings;
- primary operation is never misreported because secondary cleanup failed.

The data model already uses safer semantics in several places. Apply that same pattern consistently everywhere.

---

# 10. Free/Pro and StoreKit

This is part of a working app, but it comes after core chat/data correctness.

Test:

- Free theme limit;
- Free provider limit;
- Free project limit;
- Free MCP limit;
- Free Library limit;
- Pro unlock changes creation limits immediately;
- existing data stays accessible if Pro expires;
- purchase;
- restore;
- entitlement refresh after foreground;
- paywall open/close/reopen;
- no Debug simulated state leaks into normal builds.

Do not expand monetization scope while stabilizing the app.

---

# 11. Analytics and diagnostics

This should never interfere with chat.

Test:

- empty app;
- large conversation history;
- missing/incomplete usage data;
- Free analytics;
- Pro analytics;
- entitlement change while view is open;
- telemetry storage failure;
- clear telemetry;
- budget boundary.

### Invariant

Analytics/telemetry failure must be fail-open and must not prevent normal app startup or chat.

---

# 12. Tests to add first

Current Mac tests mostly cover rendering helpers and presentation/policy state. The missing coverage is the app orchestration layer.

Phase 1 now adds `MacChatSessionModelTests` and `MacStartupRecoveryTests`. Next test suites belong to Phase 2 as their corresponding end-to-end surfaces are exercised.

## `MacDataManagementModelTests`

Cover backup merge/replace and destructive operations.

## `MacProviderModelTests`

Cover provider lifecycle, targets, credentials, model availability, and limits.

## `MacMCPModelTests`

Cover inheritance/override, Always Allow persistence, server lifecycle, and approval/elicitation state.

## Minimal Mac UI smoke tests

Only cover critical navigation and app-shell behavior:

- launch;
- sidebar;
- new chat;
- search;
- utility surfaces;
- Settings;
- paywall.

Do not spend time building a large screenshot-testing framework right now.

---

# 13. Implementation phases

## Phase 1 — Core correctness

**Goal:** eliminate behavior that can corrupt, lose, or misrepresent user state.

Implemented in this PR:

- single-conversation delete consistency;
- safer draft persistence/reload behavior;
- duplicate-send guard;
- first-chat Project assignment rollback;
- testable startup composition;
- startup/retry/recovery/reset tests;
- chat delete/draft/Project rollback tests.

Remaining validation is execution of the new tests plus hands-on Mac smoke testing of send/stop/regenerate/edit/recovery.

**Exit gate:** normal chat/data operations cannot leave contradictory UI vs persisted state.

## Phase 2 — End-to-end product workflows

**Goal:** every major feature works as a complete workflow.

- providers/models;
- attachments;
- Projects;
- Library;
- MCP;
- backup/import/data management;
- Free/Pro gates.

Fix bugs found while exercising these flows. No new features.

**Exit gate:** every major surface can be used from start to finish without dead ends.

## Phase 3 — Mac shell and reliability

**Goal:** make the desktop app feel stable during long real usage.

- titlebar/window/sidebar/focus regression;
- keyboard shortcuts;
- long streaming conversations;
- rapid navigation during generation;
- large workspace behavior;
- quit/relaunch cycles;
- UI smoke tests;
- accessibility issues that directly block use.

**Exit gate:** no known P0/P1 functional bugs in daily-use Mac workflows.

## Later — release packaging

Only after the app is functionally solid:

- version/plist cleanup;
- privacy/archive validation;
- App Store metadata;
- screenshots;
- review notes;
- final submission preparation.

These are intentionally **not** part of the immediate implementation focus.

---

# 14. Functional smoke matrix

Before calling the app functionally ready:

1. clean launch;
2. create provider and select model;
3. send streamed chat;
4. stop generation;
5. regenerate;
6. edit and resend;
7. rename/pin/search/delete chat;
8. quit/relaunch and verify state;
9. image attachment;
10. file attachment;
11. Finder drop;
12. clipboard paste;
13. Project create/edit/delete and Project chat;
14. Library import/preview/attach/source-chat navigation;
15. MCP discover/approve/deny/Always Allow/elicitation;
16. backup export/import;
17. destructive reset and recovery;
18. Free limits;
19. Pro unlock/restore;
20. long response with Markdown/code/math/Mermaid;
21. switch chats during streaming;
22. resize/minimize/full-screen/close/reopen;
23. Settings/theme switching;
24. offline/invalid provider/recovery states.

If these work reliably, then spend time preparing the release package.

---

# Final assessment

BYOKchat Mac does not need more feature ideation right now.

It needs the existing product to become dependable.

The best next sequence is:

> **chat/data correctness → complete end-to-end workflows → Mac shell reliability → only then release packaging.**

That is the shortest path to a Mac app worth shipping.
