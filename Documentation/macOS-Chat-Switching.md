# macOS chat switching

Sidebar selection and the displayed conversation have separate identities. `MacChatNavigation` prepares a cold selection while the current chat stays visible. A revision check and task cancellation prevent an older request from replacing a newer selection. On failure, the displayed chat remains and the sidebar selection rolls back. Sending, attachments, target selection, and tool sheets use the displayed conversation; completion of an older send does not steal selection.

Preparation hydrates the conversation through the existing storage actors and prepares answer content from its last eight messages. `MacAnswerContentParseCache` caches both structural blocks and MarkdownUI's actual parsed `MarkdownContent`, plus the inline-math routing decision. Parsing runs on the cache actor. A locked synchronous lookup allows prepared rows to render rich content on their initial view evaluation. Older rows and collapsed reasoning prepare on demand. Cancellation is checked between messages and before/after parsing; a parser call already executing cannot be interrupted halfway through.

The shared parse cache is limited to 64 entries and 8 MiB of source text. This byte budget is not a measurement of parsed-tree heap size. Each retained transcript pins its initially prepared answers, including an oversized answer that cannot enter the shared cache. Syntax highlighting keeps using its existing separate cache. Math, Mermaid, AppKit layout, and final view creation are not guaranteed to be ready before the flip.

A `ZStack` retains at most three transcript instances with stable conversation IDs. The header and composer are shared. A returning transcript keeps its scroll-follow state and row-local state for rows that List has retained. List can still recycle offscreen rows. Evicted transcripts reopen using cached data and available parse results and initially scroll to the bottom.

Inactive transcripts use their retained conversation snapshot, stop observing live answer presentation, disable interaction and accessibility exposure, and suspend native scroll observation. Composer height changes do not change inactive transcripts' reserved bottom space. App generation continues independently. Returning to an active stream preserves an earlier reading position; a transcript that was following the latest response follows it again.

Native row anchors associate each transcript with its own enclosing scroll view. That connection survives row recycling and inactivity; observation never searches another retained transcript's view hierarchy. Source-message requests are retained in navigation until the destination is presented and applied once per request token.

Concurrent hydration requests share one task per conversation. Unchanged summary refreshes do not republish sidebar state. The existing hydrated conversation data cache is unchanged; the three-entry limit applies to retained transcripts, not all conversation data in memory.

## Timing

The `ChatSwitch` signpost category contains:

- `Chat Selection`: selection processing, including cold preparation.
- `Prepare Conversation`: hydration and initial answer preparation.
- `Prepare Markdown`: a cache miss requiring structural/Markdown parsing.
- `Display Prepared Chat`: the displayed conversation is committed.
- `Transcript Geometry Ready`: the native transcript reports its first geometry after activation.

The geometry marker is not a GPU presentation timestamp. Compare first opens with repeat switches, using short chats and long table-heavy chats, and repeat while another chat streams. No runtime speedup or memory measurements have been established yet.

## Regression coverage

Tests cover late selection completion, new-chat supersession, preparation failure, bounded retention and reuse, deferred source navigation, unchanged sidebar summaries, parsed-content reuse/invalidation, cache eviction and input-byte limits, and suspension/resumption of native scroll observation. Build and test execution are left to the user as requested.
