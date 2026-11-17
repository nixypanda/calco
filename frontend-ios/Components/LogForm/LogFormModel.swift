import Foundation

public enum LogFormValidationError: Equatable, Sendable {
    case amountRequired
    case amountInvalid
}

public extension LogFormValidationError {
    var message: String {
        switch self {
        case .amountRequired:
            return String(localized: "foodDetail.error.amountRequired")
        case .amountInvalid:
            return String(localized: "foodDetail.error.amountInvalid")
        }
    }
}

public func validateLogAmount(_ amount: String) -> LogFormValidationError? {
    let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .amountRequired
    }
    guard let value = Double(trimmed), value.isFinite, value > 0 else {
        return .amountInvalid
    }
    return nil
}
