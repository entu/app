// Markdown rendering — `Text(markdown:)` with a verbatim fallback, used
// for entity and type description blocks.

import SwiftUI

extension Text {
    /// Render `source` as Markdown, falling back to verbatim text when it
    /// can't be parsed. Used for entity/type description blocks.
    init(markdown source: String) {
        if let attributed = try? AttributedString(markdown: source) {
            self.init(attributed)
        } else {
            self.init(verbatim: source)
        }
    }
}
