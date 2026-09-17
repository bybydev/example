# Phase 1 Handoff — Custom macOS Shell and Navigation

## Status

Phase 1 is complete when this pull request is squash-merged.

The permanent Inkribe macOS shell is now established so later feature phases can replace content without rewriting navigation, titlebar, sidebar, divider, Settings, or Pro-routing architecture.

## Delivered

### Permanent two-column shell

- Full-height `SidebarColumn` and `MainColumn` with one continuous divider.
- Sidebar owns the native traffic-light titlebar region.
- Main titlebar starts at the divider and owns page title/actions.
- Main status bar is structurally constrained to the main column.
- Full-size native window chrome is provided through MacAppFoundation while Inkribe owns shell geometry.

### Sidebar behavior

- Expanded sidebar target is 220 pt.
- Navigation content fully collapses.
- Collapsed structural rail retains only the traffic-light reserve plus divider-toggle clearance.
- Divider and toggle derive from the same shell width.
- Toggle remains reachable in both states.
- Sidebar visibility persists through `UserDefaults`.
- Reduce Motion removes the coordinated width transition.
- Standard sidebar menu command and `⌃⌘S` use the same state owner.

### Navigation

- Library, Record, and Import are the primary destinations.
- `⌘1`, `⌘2`, and `⌘3` route through the same centralized shell state.
- Transcript editing is represented as a primary main-column detail route rather than a modal flow or top-level sidebar destination.
- Settings remains outside main-content navigation and opens the separate Settings scene.

### Settings and commerce surfaces

- MacAppFoundation Settings scene added with General, Appearance, Plan, and About panes.
- `ProPlanButton` is located only in the main titlebar.
- Free and Pro titlebar actions route to the Plan pane.
- Plan uses the shared `PurchaseManager`; its current upgrade action purchases the configured preferred entitlement product.
- A richer multi-plan paywall is intentionally separate from the shell and remains dependent on final legal destinations.

### Accessibility and interaction ownership

- Native SwiftUI buttons preserve keyboard focus behavior.
- Stable accessibility identifiers exist for shell regions, sidebar destinations, Settings, and the sidebar toggle.
- The shell does not introduce a custom event system or duplicate window state.

### Tests

Focused shell-state tests cover:

- default expanded geometry;
- one-source divider/toggle geometry;
- sidebar visibility persistence across state owners;
- collapsed toggle clearance from the native traffic-light reserve;
- transcript routing as a main detail surface rather than a sidebar destination.

## Important implementation decisions

### Collapsed structural rail is not literal zero

Earlier planning text said the collapsed sidebar width should be `0`, while the design diagrams still retained a native traffic-light region.

A literal zero structural width would place the full-height divider to the left of the traffic lights and force the divider toggle into their reserved area. The implementation therefore treats **navigation content width as zero** while retaining a narrow structural rail for the native controls and toggle clearance.

`docs/SHELL.md` is the authoritative shell geometry contract from this phase onward.

### One shell state owner

`InkribeShellState` owns navigation and sidebar geometry. Feature screens must consume this owner and must not introduce their own sidebar widths, divider locations, or navigation state machines.

### Transcript is a detail route

The transcript editor has already been modeled as `InkribeShellRoute.transcript(TranscriptID)`. Phase 5 should fill that surface rather than presenting a new modal/editor window architecture.

## Deferred to later phases

The following are intentionally not Phase 1 work:

- real recording controls and microphone workflow;
- file import/drop queue behavior;
- recent transcript data in the sidebar;
- transcript editor content and player;
- search/export controls;
- model/runtime status details;
- production multi-plan paywall presentation.

Those features should fill the permanent shell established here rather than alter its structural geometry.

## Next phase

Phase 2 owns the model asset pipeline and fixture/production model contract. It should not modify the root shell except for future status information that belongs inside the existing main status bar.
