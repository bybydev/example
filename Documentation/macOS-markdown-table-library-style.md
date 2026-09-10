# macOS Markdown Table Styling

## Scope

Polish macOS Markdown tables while keeping MarkdownUI as the sole Markdown/GFM parser and table renderer.

## Constraints

- Do not add a custom table parser.
- Do not add a custom table view.
- Do not split Markdown source around tables.
- Apply presentation only through MarkdownUI's `.table` and `.tableCell` theme hooks.
- Keep table overflow isolated from the chat transcript.
- Let MarkdownUI's native `Grid` own table structure and GFM column alignment.
- Prefer intrinsic/library-controlled column sizing over fixed or hand-measured widths.

## Styling target

- horizontal scrolling for genuinely wide tables;
- visible scroll indicators;
- subtle border and alternating row backgrounds;
- semibold header row;
- compact cell padding and line spacing;
- multiline cells remain vertically stable.
