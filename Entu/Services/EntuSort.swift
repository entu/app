// Sort function matching the webapp's menuSorter/propsSorter logic.
// Used for sorting menu items, property groups, and properties within groups.
//
// Rules (matching the JavaScript implementation):
//   1. Items without ordinal (nil or 0) come before items with ordinal
//   2. Items with ordinal are sorted by ordinal value
//   3. Ties broken alphabetically by name

import Foundation

/// Sort matching the webapp's menuSorter/propsSorter: no-ordinal first, then by ordinal, then by name.
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
