# Inkribe macOS Shell Contract

This document is the implementation contract for the permanent Inkribe macOS shell introduced in Phase 1.

## Structural layout

While the sidebar is expanded, the main window is two structural columns separated by one continuous divider:

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

The divider is not decorative. While the sidebar is visible, it is the boundary between sidebar-owned and main-owned window regions from the top edge to the bottom edge. When the sidebar collapses to zero, the divider collapses with it and the main column becomes full width.

Consequences:

- while expanded, native traffic lights remain on the sidebar side of the divider;
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
collapsed sidebar             0 pt
titlebar toggle spacing        8 pt
status bar                   30 pt
minimum window              760 × 520 pt
collapse animation           0.22 s ease-in-out
```

### Collapsed state

The sidebar collapses to a literal zero-width region. The main column expands to the window's leading edge and the internal sidebar divider collapses away with it.

Native traffic lights then occupy the main titlebar's leading area. The main titlebar explicitly reserves `MacAppWindowChromeMetrics.trafficLightReserve` before placing the sidebar toggle and route title, so controls never overlap the traffic lights.

This keeps the collapsed state visually clean instead of leaving an empty structural rail.

## Sidebar state ownership

`InkribeShellState` is the single source of truth for:

- expanded/collapsed sidebar state;
- persisted sidebar visibility;
- current main-column route;
- sidebar width and visibility.

Feature views must not store their own copies of sidebar width or visibility. The main-titlebar toggle reads the same shell state and moves automatically as the sidebar/main-column geometry animates.

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

The sidebar titlebar uses `MacAppWindowDragRegion` and reserves native traffic-light space while the sidebar is expanded.

The main titlebar starts after the divider while expanded. When collapsed, it becomes the full-width titlebar and reserves native traffic-light space itself. It contains:

- the sidebar toggle;
- the current route title;
- page-level actions as later phases add them;
- `ProPlanButton` on the right.

The titlebar backgrounds use MacAppFoundation semantic theme roles rather than hard-coded colors.

## Sidebar toggle

The toggle is a normal control inside the main titlebar, not an overlay on top of the divider.

When expanded, it sits immediately on the main side of the full-height divider. When collapsed, it moves left with the expanding main column but stays after the native traffic-light reserve.

Expanded and collapsed transitions animate the sidebar width, divider width, main-column leading edge, titlebar reserve, and toggle position together. The divider therefore remains visually uninterrupted while present.

When Reduce Motion is enabled, the shell changes state without the geometry transition.

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
