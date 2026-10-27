# iOS library organization — PR #46

2026-10-27. Source integration on `fix/ios-improvements` targeting develop.
Reference: Spokio iOS LibraryView and SpokioScopeTile at 80fc72f.

## Implemented

- [x] Replace media-type chips with All, Favorites, alphabetical custom folders and Trash.
- [x] Match Spokio's clear capsule fill, thin outline, icon/label/count, typography,
  11/7 padding, 10-point inter-pill spacing and accent selection.
- [x] Remove the Projects header count. Group label, Sort and Options on the left.
- [x] Floating + menu offers New Project and New Folder. Header Options manages the
  selected folder and opens Storage; top toolbar remains crown and settings.
- [x] Create/rename folders with trimmed nonempty names, length and duplicate-name
  validation; retain draft/error on unsuccessful save.
- [x] Project actions add/remove favorites and move to a folder or None.
- [x] Folder deletion clears memberships for active and trashed projects while
  preserving project packages and favorites; a deleted selected folder returns to All.
- [x] Imported projects join the folder selected when import began. If assignment
  fails, the committed projects stay in All with an error instead of being lost.
- [x] Duplicates retain folder membership; the new copy starts without a favorite flag.
- [x] Trash has scoped search/sorting, restore and confirmed per-project permanent
  deletion. Corrupt/future packages remain visible; Restore is unavailable for them,
  while explicit deletion uses the existing package-store cleanup path.
- [x] Failed organization reads preserve the existing file and cached state, expose
  Retry and disable organization changes. All projects remain accessible.

## Persistence and integration

`ProjectRepository` serializes reads and atomic writes of
`Library/organization-v1.json` under the existing app project root. The versioned
index stores folder IDs/names and project UUID membership/favorite flags. Reads
and writes validate identities, folder references and bounded file size; existing
files are never replaced with an empty index after a decode/read failure.

Folder/favorite changes do not modify project JSON, content revisions, source
paths, transcription payloads/checkpoints, allowance or editor state. Existing
project schema 10 and queue/package wrappers are unchanged. Soft Trash/Restore
preserves membership/favorites. Counts use actual active or trashed snapshots, so
metadata for permanently removed UUIDs is never counted or resurrected.

Search and sorting are in-memory projections within the selected scope, matching
Spokio. Search offers All when a subset is selected. Hero and pills remain hidden
while searching. The hero still follows the latest updated active project,
independently of scope and display sorting. Paper/theme access and the earlier
home changes remain in this PR. No new purchase gate is introduced.

## Review and acceptance

The user subsequently requested ReadAloud-style plain rows, then square aspect-fit
thumbnails with a neutral adaptive background (64 points in the list, 80 in the
hero). Project navigation rows now use native List disclosure chevrons; the
per-row ellipsis button is removed. Leading swipe toggles Favorites; trailing
swipe offers Rename and confirmed Move to Trash. Long press retains Favorites,
Move to Folder/None, Rename, Duplicate and Move to Trash. Shared action helpers
retain the existing pending-edit, active-transcription and storage guards.
Trash rows also expose Restore/Delete Forever through swipe and long press,
retaining the existing explicit destructive confirmation. Hero, pills and header
remain scrolling content in the same plain List, with the floating + overlay.

Hero tap-target correction: Recent Project, Free usage and Queue each own a
borderless section button whose label includes its padding and hit shape. There
is no navigation action on the hero container. Usage presents the existing
AppFoundation LimitReachedUpsellFlow with non-limit overview copy; only its
explicit upgrade action opens the paywall. Error-state Retry is a sibling button,
not nested inside the usage button. Queue navigation is confined to its section.

Home sorting now matches Spokio's independent Sort By and Order pickers:
Date Created, Date Updated, Name or Duration, each Ascending or Descending.
Choices persist in app preferences and are preserved after import. The default
remains Date Updated descending. Active/favorite/folder/search and Trash lists
share these controls; duration uses rational CMTime comparison and tied values
use stable project UUID ordering. Unreadable Trash metadata sorts last in either
direction. Created dates and durations come from existing saved documents, with
no project schema change, media processing or filesystem scan on menu selection.

Theme previews use AppFoundation's standard five-minute behavior. The Settings
picker shows the built-in countdown, End and Unlock controls. Preview expiration
returns to the committed theme; unlocking Pro promotes the active preview through
the framework. Paper remains first, default and the only permanently Free theme.

Settings no longer includes the duplicate Usage section or its allowance-refresh
hooks. The duplicate Queue navigation row is also removed from Settings. Free
usage, its retry/upsell actions and Queue access remain in the home hero.

Settings Contact Support, Terms of Use and Privacy Policy now use the Inkribe
pages at `https://spokiostudio.com/inkribe/contact`, `/inkribe/terms` and
`/inkribe/privacy`. The paywall shares the same terms/privacy constants.

Source/call-site, diff, whitespace and publication review only. No builds,
typechecks, tests, fixtures, CI, project generation, UI/device execution or native
processing ran. Compilation and on-device visual/runtime acceptance remain pending.
The PR is left open without auto-merge.

