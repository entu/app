// Shared date-time display format — the same fields as a `datetime`
// property row, for UI text outside the property rows (support access end
// times). Text resolves it against the environment locale, so the in-app
// language picks 12h (EN) or 24h (ET).

import Foundation

extension FormatStyle where Self == Date.FormatStyle {
    /// Date and time with two-digit month, day and minute — webapp's
    /// `d(date, 'datetime')`.
    static var entuDateTime: Date.FormatStyle {
        Date.FormatStyle()
            .year(.defaultDigits)
            .month(.twoDigits)
            .day(.twoDigits)
            .hour(.twoDigits(amPM: .abbreviated))
            .minute(.twoDigits)
    }
}
