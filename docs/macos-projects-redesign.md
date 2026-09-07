# macOS Projects Redesign

## Goal

Bring Projects into the same desktop-native design language as the redesigned Library and MCP Server surfaces while preserving the project feature set already implemented in PR #19.

The redesign should make Projects feel like a workspace, not a nested settings screen.

## Problems in the current UI

- Projects embeds its own `NavigationSplitView` inside the already-modal utility surface, creating a second sidebar/navigation hierarchy.
- The outer utility sheet already owns the `Projects` title, so the inner navigation title duplicates hierarchy and consumes space.
- Project detail is split into `Chats / Sources / Settings`, but important project concepts such as tools are buried under Settings.
- Sources are effectively read-only from the detail view; adding/removing files requires opening Edit Project.
- Edit Project is a large grouped form containing identity, provider/model defaults, instructions, files, prompt presets, MCP configuration, and tool presets in one long sheet.
- Project management therefore feels configuration-heavy compared with Library and MCP Server management.

## Design principles

1. **Flat top-level management**
   - No nested `NavigationSplitView`.
   - Projects home is a single scrollable list of project cards.
   - Selecting a project drills into a full-width project detail surface.

2. **Progressive disclosure**
   - Home shows only operational summary information.
   - Project detail exposes major project concerns through dedicated tabs.
   - Editing is focused and contextual instead of one giant form.

3. **Match Library and MCP visual language**
   - Flat canvas.
   - Surface cards with subtle borders.
   - Compact toolbars and summary text.
   - Explicit empty states.
   - Overflow menus for destructive/secondary actions.

4. **Projects remain workspaces**
   - Chats, sources, instructions, defaults, reusable prompts, and tools stay first-class project concepts.
   - Do not reduce Projects to a metadata/settings list.

## Information architecture

### Projects home

Flat project cards with:

- icon + accent
- project name
- chat count
- source count
- provider/model summary
- enabled MCP server count
- direct `New Chat` action
- overflow menu for Edit / Delete
- chevron/card click to open the project

Conceptual layout:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│  [ Search projects... ]                                  [+ New Project]    │
│                                                                              │
│  4 projects                                                                  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  🔨  Spokio                                                      ›     │  │
│  │      12 chats · 6 sources                                              │  │
│  │      OpenAI · GPT-5.6 · 3 MCP servers                                 │  │
│  │                                                   [New Chat]   [•••]   │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

Projects should suppress the generic utility footer, like Library and MCP Servers.

### Project detail

Header:

- Back to All Projects
- project icon/name
- summary: chats · sources · MCP servers
- `New Chat`
- overflow/edit actions

Tabs:

- `Overview`
- `Chats`
- `Sources`
- `Tools`

Conceptual layout:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│  ‹ All Projects                                                              │
│                                                                              │
│  🔨  Spokio                                                                  │
│      12 chats · 6 sources · 3 MCP servers          [+ New Chat]   [•••]     │
│                                                                              │
│       [ Overview ]     [ Chats ]     [ Sources ]     [ Tools ]              │
│  ──────────────────────────────────────────────────────────────────────────  │
│                         selected section                                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Overview tab

Overview should present project configuration as readable cards instead of a form.

Sections:

### Project

- icon
- name
- accent
- focused Edit action

### New Chat Defaults

- provider account
- model
- focused Edit action
- explanation that defaults only apply to new chats

### Instructions

- system/project instructions
- empty state uses app-default wording
- focused Edit action

### Reusable Prompts

- prompt preset cards/rows
- `Use`
- Edit/Delete overflow
- Add prompt action

### Danger Zone

- Delete Project

## Chats tab

Treat project chats like a lightweight, project-scoped chat browser.

- search field
- `Add Existing`
- `New Chat`
- date grouping where useful (`Today`, `Yesterday`, `Previous 7 Days`, month/year)
- title
- last-message preview or message count
- updated date
- context menu: Open / Remove from Project

## Sources tab

Treat project sources as a project-scoped Library.

- search field
- `Add Files`
- source count + total size
- filename
- type
- size
- estimated tokens
- source actions via overflow/context menu
- direct Remove from Project
- file capacity summary (`N of 8 files · X of 40 MB`)

Source add/remove management should live here rather than requiring Edit Project.

## Tools tab

Reuse the redesigned MCP permission language and controls.

- explanatory inheritance copy
- each configured server displayed as a management card
- per-project server enable state
- discovered tool count
- per-tool permission picker: `Ask / Always Allow / Disabled`
- safety hints: read-only / destructive
- tool presets below server configuration
- `Save Current as Preset`
- `Apply` existing preset

The goal is for project tool defaults to visually match chat-level MCP configuration.

## Create Project

Creation should be intentionally small.

Required/initial fields:

- name
- icon
- accent
- provider account (optional; app default)
- model (optional; account default)

Everything else can be configured after creation from the project detail surface.

```text
┌─────────────────────────────────────────┐
│ New Project                             │
├─────────────────────────────────────────┤
│ Name       [                         ]  │
│ Icon       [ 🔨 ]                       │
│ Color      ● ● ● ● ● ● ●               │
│                                         │
│ New Chat Defaults                       │
│ Provider   [ App Default           ▾ ]  │
│ Model      [ Account Default       ▾ ]  │
│                                         │
│                 [Cancel]  [Create]      │
└─────────────────────────────────────────┘
```

## Editing strategy

Avoid a single giant `Edit Project` form.

Use focused editors/sheets for:

- Project identity
- New Chat Defaults
- Instructions
- Prompt preset editor

Sources and tools should be managed directly in their tabs.

The existing full editor may temporarily remain as an implementation fallback while the focused surfaces are introduced, but it should no longer be the primary UX once the redesign is complete.

## Empty states

Projects home:

- `No Projects`
- short explanation
- prominent `New Project` action

Project Chats:

- `No Chats Yet`
- `New Chat` action
- optional `Add Existing` when standalone chats exist

Project Sources:

- `No Sources`
- `Add Files` action

Project Tools:

- explain that project tool defaults are inherited by new/project chats until overridden
- distinguish globally disabled MCP servers from project-disabled servers

## Interaction rules

- Project card click opens detail.
- `New Chat` never requires opening detail first.
- Back navigation returns to Projects home without dismissing the utility sheet.
- Opening a chat dismisses the utility sheet and navigates to the chat, preserving current behavior.
- Deleting a project keeps chats and moves them back to standalone chats, preserving current storage semantics.
- No storage migration is required for this redesign.

## Implementation phases

### Phase 1 — shell and navigation

- Replace nested `NavigationSplitView` with flat home/detail state.
- Add project search and management cards.
- Suppress Projects utility footer.
- Add back navigation and project detail header.
- Change tabs to `Overview / Chats / Sources / Tools`.

### Phase 2 — detail surfaces

- Build Overview cards.
- Improve Chats list/search/grouping.
- Move source add/remove management into Sources.
- Move MCP configuration/tool presets into Tools.

### Phase 3 — focused editing

- Replace giant editor as primary UX with focused editors.
- Keep creation sheet compact.
- Reuse existing validation and persistence paths.

### Phase 4 — polish and regression coverage

- Empty/loading/error states.
- Accessibility labels and keyboard behavior.
- Regression tests for project presentation helpers and filtering/grouping.
- Run the macOS deploy/build path through `hoangbkit/cicd`.
