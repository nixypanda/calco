import Foundation

public enum LogFormValidationError: Equatable, Sendable {
    case amountRequired
    case amountInvalid
}

/// Strictly bounded positive decimal input shared by the log form, builders,
/// and journal validation. It accepts one comma or dot decimal separator for
/// keypad locale compatibility, but rejects exponent/hex/leading-sign forms and
/// amounts above the catalog's sane UI bound.
public func parsePositiveLogAmount(_ raw: String) -> Decimal? {
    guard let value = CatalogDecimal.parseNonNegative(raw),
          value > 0,
          value <= Decimal(1_000_000) else {
        return nil
    }
    return value
}

public extension LogFormValidationError {
    var message: String {
        switch self {
        case .amountRequired: String(localized: "foodDetail.error.amountRequired")
        case .amountInvalid: String(localized: "foodDetail.error.amountInvalid")
        }
    }
}

public func validateLogAmount(_ amount: String) -> LogFormValidationError? {
    let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .amountRequired
    }
    guard parsePositiveLogAmount(trimmed) != nil else {
        return .amountInvalid
    }
    return nil
}
