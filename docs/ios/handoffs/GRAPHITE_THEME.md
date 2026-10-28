# Graphite theme — PR #50

2026-10-28. The user approved the concrete plan in existing PR #50, targeting
develop, initially extending 35b29af. The user then approved revising the flat
design at 171911d to Midnight-like translucency and depth while retaining #279ED2.
Keep the PR open without auto-merge.

- [x] Add app-owned Graphite (`graphite`), Free and always dark, directly after
  Free Paper. Existing premium themes keep their order/access; Paper stays the
  default/fallback. Existing theme IDs and the persisted state key stay intact.
- [x] Keep accent #279ED2, charcoal background #141414 and text #F2F2F2. Use
  Midnight's white surface at 0.065 alpha, elevated surface at 0.10, border at
  0.13, secondary text at 0.72 and black shadow at 0.42. Replace opaque panels
  and borders so the layered background shows through.
- [x] Remove the special flat-background branch from `themedSurface`; reuse
  AppThemeBackground's gradient, blue accent lighting and subtle shading, as
  Midnight does. Graphite's gradient is #20262D to #16384A. Existing themes keep
  their background treatment. This matches Midnight's glass-like visual depth;
  it does not introduce a new native glass/material system.
- [x] Update theme comparison/upsell copy to include both Free themes.
- [x] Review source against AppFoundation 1.6.4's AppTheme/ThemeAppearance and
  picker/access contracts, catalog ordering, source membership, diff/whitespace
  and exact remote tree/blob publication.

AppFoundation still owns theme selection, persistence and Pro access. Its package
and version are unchanged. No icon, Mac, caption artwork, preview/player, rendering,
schema, purchase products, model, queue or output changes.

Source integration is not compilation or device appearance evidence. No builds,
typechecks, tests/fixtures, CI, generation, native processing or UI/device execution
were run. User validates appearance afterward. No next feature is authorized.
