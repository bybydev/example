# macOS Custom App Shell + Button Styles Plan

## Goal

Replace the main macOS `NavigationSplitView` + native navigation toolbar presentation with a BYOKchat-owned custom shell and header, while keeping native macOS window behavior and preserving the current sidebar visual design.

This is a focused UI architecture refactor, not a rewrite of chat/runtime/storage behavior.

## Status

- Phase 1: **implemented**
- Phase 2: **implemented**
- Phase 3: **implemented**
- Phase 4: **implemented / code-reviewed**

The main screen now uses a BYOKchat-owned shell and custom `MacChatHeader`. The native window remains titled/closable/resizable/fullscreen-capable, but its visible title is hidden and content extends into the title-bar region using full-size content. Header controls use a small semantic button-style system, and sidebar menu commands are routed through BYOKchat-owned shell state.

Phase 4 completed the source-level regression pass and final layout cleanup. The repository currently has no GitHub Actions workflow/status checks for this PR branch, so runtime/build verification still needs to be performed locally before merge.

## Hard constraints

Preserve:

- native `NSWindow` behavior
- traffic lights
- resize/minimize/fullscreen/window dragging
- menus, sheets, alerts, context menus, accessibility semantics
- existing sidebar branding/header
- existing New Chat treatment
- existing search field
- existing conversation rows and selection styling
- existing pinned/recent grouping
- existing two-column utility tile grid and tile styling
- existing chat/runtime/storage behavior

Allowed sidebar change:

- add Settings as the sixth utility tile using the same existing tile design
- remove only shell-level separator chrome that becomes unnecessary after the shell migration
- reserve title-bar space so native traffic lights do not overlap sidebar content

Do not:

- convert utility tiles into rows
- redesign the sidebar
- create a borderless/fake window
- recreate traffic lights
- change chat/provider/MCP/attachment/project/library semantics

## Target architecture

```text
Native macOS window
├── native traffic lights / resize / fullscreen
└── full-size BYOKchat content
    └── MacAppShell
        ├── MacSidebarView
        │   └── existing sidebar UI preserved
        └── MacChatPane
            ├── MacChatHeader
            │   ├── sidebar toggle
            │   ├── conversation title
            │   ├── optional message count
            │   ├── draggable empty space
            │   └── Pro / trailing actions
            ├── transcript
            └── composer
```

The completed main screen no longer depends on:

- `NavigationSplitView`
- `NavigationSplitViewVisibility`
- `.navigationTitle`
- `.navigationSubtitle`
- native main-screen `.toolbar`
- `SidebarCommands()`

---

# Phase 1 — Clean baseline + custom shell

**Status: implemented.**

Implemented:

- removed speculative/unused shell/button code from the earlier attempt
- kept Settings as tile #6 using the existing tile design
- replaced `NavigationSplitView` in `MacShellView` with `MacAppShell`
- replaced `NavigationSplitViewVisibility` with app-owned `sidebarVisible` state
- preserved the existing sidebar at its current ideal width for the first custom-shell pass
- kept conversation/search/navigation/runtime state unchanged
- added subtle sidebar show/hide transition support
- removed the separator directly above the utility grid
- added no permanent divider between sidebar and main content
- deferred draggable sidebar resizing

Acceptance:

- no `NavigationSplitView` in the main shell
- sidebar visibility is app-owned
- sidebar design is visually unchanged except the explicitly approved Settings tile, title-bar reserve, and separator removal
- Library → chat navigation reveals the sidebar through app-owned state
- no chat/runtime behavior changes

---

# Phase 2 — Title-bar integration + `MacChatHeader`

**Status: implemented.**

Implemented:

- kept the real native macOS window and traffic lights
- enabled `NSWindow.StyleMask.fullSizeContentView`
- hid the visible native window title while keeping the window identity/title intact
- made the native title-bar background transparent and removed its separator
- extended BYOKchat content into the title-bar region
- added explicit title-bar/traffic-light layout tokens used by real controls
- reserved the traffic-light area when the sidebar is visible and when it is hidden
- added draggable empty regions using `WindowDragGesture`
- removed the temporary `NavigationStack` compatibility wrapper
- removed `.navigationTitle`, `.navigationSubtitle`, and the main-screen `.toolbar` from `MacChatPane`
- added `MacChatHeader` with sidebar toggle, conversation title, optional message count, draggable center region, and Pro action
- preserved the existing Pro routing behavior exactly

Acceptance:

- no native navigation title/subtitle/toolbar remains on the main chat screen
- custom header owns the visible title and actions
- traffic lights remain native and unobstructed
- title/message count update with conversation state
- Pro behavior remains unchanged
- sidebar shown/hidden states both reserve traffic-light space correctly
- native resize/minimize/fullscreen/window behavior remains owned by AppKit

---

# Phase 3 — Button styles + command migration

**Status: implemented.**

Implemented:

- added only control tokens used by real custom-header controls
- added `MacIconButtonStyle` for compact icon-only header actions
- added `MacSecondaryButtonStyle` for the existing-Pro plan action
- added `MacPrimaryButtonStyle` for the Unlock Pro action
- deliberately did not add `MacGhostButtonStyle` because there is no current shell/header call site for it
- custom styles own hover, pressed, disabled opacity, sizing, padding, radius/surface/border treatment, and keep SwiftUI focus effects enabled
- header icon buttons retain tooltips and accessibility labels at their call sites
- migrated the sidebar toggle to `MacIconButtonStyle`
- migrated the Pro/Unlock Pro control to secondary/primary semantic styles without changing its routing behavior
- removed `SidebarCommands()` from the app scene
- replaced the sidebar command group with BYOKchat-owned Toggle Sidebar routing plus the full-screen command in the standard `.sidebar` command placement
- routed Toggle Sidebar through `MacAppModel.sidebarToggleRequestID` into `MacShellView`'s local sidebar state
- preserved New Chat, Search Conversations, and Stop Generating command behavior/shortcuts

Acceptance:

- shell/header button styles all have real call sites
- no unused speculative button style exists
- hover/pressed/disabled behavior is BYOKchat-owned for custom header controls
- native SwiftUI focus effects remain enabled for keyboard focus
- icon-only header action remains labeled and tooltip-enabled
- sidebar toggle works through BYOKchat state without `SidebarCommands()`
- standard full-screen shortcut remains available
- existing New Chat/Search/Stop shortcuts remain unchanged

---

# Phase 4 — Polish + regression verification

**Status: implemented / code-reviewed.**

Polish completed:

- verified the sidebar/main join remains separator-free at the shell boundary
- verified the existing sidebar visual structure and two-column utility grid remain intact
- verified Settings is tile #6 using the existing tile treatment
- fixed minimum-width header compression so long conversation titles yield before the Pro action
- kept the Pro action at intrinsic width while conversation titles retain tail truncation
- verified traffic-light reserve is present for both sidebar-visible and sidebar-hidden layouts
- verified shell/header colors come from theme-aware design tokens or system-adaptive colors
- verified custom header button styles keep hover/pressed/disabled states and native focus effects

Source-level functional regression review:

- New Chat request routing remains unchanged
- conversation selection/rename/delete/pin/search code remains unchanged
- send/stream/stop code remains unchanged
- attachment handling remains unchanged
- model/target selection remains unchanged
- chat tool configuration remains unchanged
- Library → source chat still selects the conversation and reveals the sidebar
- Project → chat routing remains unchanged through the existing library-navigation bridge
- utility sheets remain unchanged except the approved Settings tile
- Settings opens through the standard SwiftUI `openSettings` action
- Pro paywall / Plan routing remains unchanged
- sidebar toggle works from both the custom header and app-owned menu command
- standard `⌃⌘F` full-screen behavior remains available
- native window remains titled/resizable/miniaturizable/closable and uses full-size content rather than a borderless window

Compatibility review:

- project deployment target is macOS 15.0
- project uses Swift 6 with complete strict concurrency
- `WindowDragGesture`, `allowsWindowActivationEvents`, full-size `NSWindow` content, and focus-effect APIs used by this implementation are compatible with the supported target
- `develop` has not moved from the PR base during this implementation, so no branch drift/rebase is required

Cleanup verified:

- no `NavigationSplitView` / `NavigationSplitViewVisibility` remains in the main shell path
- no `.navigationTitle` / `.navigationSubtitle` / main-screen `.toolbar` remains in `MacChatPane`
- no `SidebarCommands()` remains in the app scene
- no temporary `NavigationStack` compatibility wrapper remains
- no unused speculative button style remains

Verification limitation:

- this repository currently exposes no GitHub Actions workflow/status check for the PR head
- therefore this phase completes source/diff/API compatibility review, but does **not** claim an Xcode build or interactive runtime UI pass
- before merge, run the macOS target locally and exercise min/default/fullscreen window sizes, sidebar toggling, title truncation, traffic-light spacing, keyboard focus, light/dark themes, and the core flows above

## Definition of done

- main shell no longer uses `NavigationSplitView`
- native main-screen title/subtitle/toolbar are gone
- custom header safely occupies the title-bar region
- native traffic lights/window behavior remain intact by architecture
- sidebar design remains unchanged
- Settings is tile #6 using the original tile style
- shell/header controls use a small semantic button-style system
- `SidebarCommands()` is gone
- core chat/navigation implementation paths are unchanged by the shell refactor
- source-level regression review is complete
- local Xcode/runtime verification remains the final pre-merge gate because no CI workflow is available
