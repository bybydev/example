# Inkribe macOS Shell Contract

This document is the implementation contract for the permanent Inkribe macOS shell introduced in Phase 1.

## Structural layout

The main window is always two structural columns separated by one continuous divider:

```text
Window
├── SidebarColumn
│   ├── SidebarTitlebarArea
│   └── SidebarContent
├── Divider
└── MainColumn
    ├── MainTitlebar
    ├── MainContent
    └── MainStatusOrPlayerBar
```

The divider is not decorative. It is the boundary between sidebar-owned and main-owned window regions from the top edge to the bottom edge.

Consequences:

- native traffic lights remain on the sidebar side of the divider;
- page titles and page actions begin on the main side of the divider;
- the Pro control is main-titlebar content and never appears above the sidebar;
- status and future transcript-player bars belong only to the main column;
- feature screens never implement their own sidebar/titlebar split.

## Geometry

The shell uses one shared geometry source in `InkribeShellMetrics`.

Current metrics:

```text
titlebar height             44 pt (MacAppFoundation window chrome)
expanded sidebar            220 pt
divider                       1 pt
sidebar toggle               26 pt
collapsed toggle clearance    4 pt
status bar                   30 pt
minimum window              760 × 520 pt
collapse animation           0.22 s ease-in-out
```

### Collapsed state

The navigation content collapses completely, but the structural sidebar rail does not shrink to a literal zero-width window region.

A zero-width structural sidebar would move the full-height divider to the left edge of the window and place the native traffic lights on the main side of the divider. It would also force the divider-attached toggle into the traffic-light reserve. Both violate the shell contract.

The collapsed structural width is therefore:

```text
traffic-light reserve
+ half of the divider-toggle width
+ small clearance
```

With the current MacAppFoundation metrics this is approximately 93 pt.

This supersedes the earlier planning shorthand that described the collapsed sidebar as `0`. The **navigation content width is effectively zero**; the remaining rail exists only to preserve native window controls and the continuous divider geometry.

## Sidebar state ownership

`InkribeShellState` is the single source of truth for:

- expanded/collapsed sidebar state;
- persisted sidebar visibility;
- current main-column route;
- divider position;
- divider-toggle position.

The divider and toggle must always derive from the same `sidebarWidth` value. Feature views must not store their own copies of sidebar width or visibility.

Sidebar visibility is persisted with `UserDefaults` under:

```text
Inkribe.shell.sidebarExpanded
```

## Navigation

Primary sidebar destinations are:

```text
Library
Record
Import
```

Settings is not a main-content destination. It opens the separate MacAppFoundation Settings scene.

The shell also defines transcript editing as a main-column detail route:

```text
InkribeShellRoute.transcript(TranscriptID)
```

A transcript is therefore not a modal workflow and is not a permanent top-level sidebar destination.

Keyboard navigation uses the same `InkribeShellState` owner as mouse navigation:

```text
⌘1    Library
⌘2    Record
⌘3    Import
⌃⌘S   Show/Hide Sidebar
```

## Titlebar behavior

The sidebar titlebar uses `MacAppWindowDragRegion` and reserves native traffic-light space.

The main titlebar starts after the divider and contains:

- the current route title;
- page-level actions as later phases add them;
- `ProPlanButton` on the right.

The titlebar backgrounds use MacAppFoundation semantic theme roles rather than hard-coded colors.

## Sidebar toggle

The toggle is overlaid directly on the divider and its center X is exactly the divider X.

Expanded and collapsed transitions animate the same shared width, so these move together:

- sidebar column width;
- divider;
- toggle;
- main-content leading edge.

When Reduce Motion is enabled, the shell changes state without the width transition.

The collapsed width guarantees the toggle's left edge stays outside the traffic-light reserve.

## Settings and Pro routing

The sidebar Settings action opens a separate `MacAppSettingsView` scene.

The current settings panes are:

- General;
- Appearance;
- Plan;
- About.

The titlebar `ProPlanButton` routes both Free and Pro users to the Plan pane. The Plan pane uses the shared `PurchaseManager`; its current upgrade action purchases the configured preferred entitlement product. A richer multi-plan paywall remains separate from the shell contract and can be introduced once Inkribe's legal destinations are finalized.

## Accessibility and focus

The shell keeps controls as native SwiftUI buttons and exposes stable accessibility identifiers for the structural regions and navigation controls.

Important identifiers include:

```text
Inkribe.Sidebar
Inkribe.Sidebar.Toggle
Inkribe.Sidebar.library
Inkribe.Sidebar.record
Inkribe.Sidebar.import
Inkribe.Sidebar.Settings
Inkribe.MainColumn
Inkribe.MainTitlebar
Inkribe.MainContent
Inkribe.MainStatusBar
```

Native button focus behavior is preserved; the custom shell does not replace the window with a custom event system.

## Feature-phase rule

Later phases may replace the placeholder content inside Library, Record, Import, and Transcript surfaces, but must not rewrite the root shell geometry or create feature-specific titlebar/sidebar implementations.

Any future bottom player or processing status surface must be inserted inside `MainColumn` only.
