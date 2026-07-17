// UI-plugin model — a plugin entity attached to an entity type, rendered
// as an extra web-view tab in the edit sheet.

import Foundation

/// A UI plugin attached to an entity type. Plugins are themselves entities
/// of `_type = "plugin"` (account-wide definitions); an entity type activates
/// one by carrying a `plugin` reference to it. Rendered as an extra tab in the
/// edit sheet, hosting the plugin's `url` in a web view.
///
/// Mirrors the webapp's plugin shape in `stores/entity-type.js::fetchType`.
/// Only the two UI slots are modeled here — webhook plugins
/// (`entity-*-webhook`) fire server-side and need no client support.
struct Plugin: Identifiable, Hashable {
    let _id: String
    let name: String

    /// Trigger slot: `entity-add` (shown when creating) or `entity-edit`
    /// (shown when editing an existing entity).
    let type: String

    /// The web page loaded in the plugin tab. Always `https` — non-secure
    /// URLs are dropped at fetch time to satisfy App Transport Security.
    let url: String

    var id: String { _id }

    /// The two UI slots. Webhook slots are intentionally excluded — they are
    /// handled entirely by the API on entity lifecycle events.
    static let addSlot = "entity-add"
    static let editSlot = "entity-edit"
}
