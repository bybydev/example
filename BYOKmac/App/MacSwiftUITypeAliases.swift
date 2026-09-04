import SwiftUI

// Prefer the SwiftUI alignment type when MarkdownUI is also imported in the
// macOS target. This keeps unqualified TextAlignment references deterministic.
typealias TextAlignment = SwiftUI.TextAlignment
