import Foundation

/// Presentation-only rounding. Never use these strings for calculations or requests.
public enum DisplayNumberFormat {
    public static func decimal(_ value: Decimal, fixed: Bool = false) -> String {
        guard !value.isNaN else { return "—" }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        var text = rounded == 0 ? "0" : NSDecimalNumber(decimal: rounded).stringValue
        if fixed {
            if !text.contains(".") { text += "." }
            let fractionCount = text.split(separator: ".", omittingEmptySubsequences: false)
                .last?.count ?? 0
            text += String(repeating: "0", count: max(0, 2 - fractionCount))
        }
        return text
    }

    public static func decimal(_ raw: String, fixed: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            return "—"
        }
        return decimal(value, fixed: fixed)
    }

    public static func decimal(_ value: Double, fixed: Bool = false) -> String {
        guard value.isFinite else { return "—" }
        return decimal(String(value), fixed: fixed)
    }
}
