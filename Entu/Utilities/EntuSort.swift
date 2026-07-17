// Ordinal-then-name sort shared by menus and property lists — matches
// the webapp's `menuSorter` / `propsSorter`.

import Foundation

/// Sort matching the webapp's `menuSorter` / `propsSorter`.
///
/// Rules:
/// 1. Items without ordinal (nil or 0) come before items with ordinal.
/// 2. Items with ordinal are sorted by ordinal value.
/// 3. Ties broken alphabetically by name.
func entuSort(_ aOrd: Double?, _ aName: String?, _ bOrd: Double?, _ bName: String?) -> Bool {
    let aHasOrd = aOrd != nil && aOrd != 0
    let bHasOrd = bOrd != nil && bOrd != 0

    if aHasOrd && bHasOrd { if aOrd! != bOrd! { return aOrd! < bOrd! } }
    if !aHasOrd && bHasOrd { return true }
    if aHasOrd && !bHasOrd { return false }

    let aStr = aName ?? ""
    let bStr = bName ?? ""
    return aStr.localizedCompare(bStr) == .orderedAscending
}
