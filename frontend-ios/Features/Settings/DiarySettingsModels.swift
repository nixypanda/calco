// Settings wire service and pure goal validation.

import Foundation

public enum DiarySettingsServiceError: Error, Equatable, Sendable {
    case unauthorized
    case networkUnavailable
    /// A transport/server outcome that may or may not have applied.
    case server(String)
    /// A definitive client rejection (validation, rate limit, conflict).
    case rejected(String)
    /// Cancellation before/while sending. A save remains ambiguous because the
    /// request may already have reached the server.
    case cancelled
    case unknown
}

public protocol DiarySettingsServicing: Sendable {
    func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot
    func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot
    func fetchDiaryPreferences() async throws -> DiaryPreferences
    func updateDiaryPreferences(_ preferences: DiaryPreferences) async throws -> DiaryPreferences
}

public func isUnauthorizedDiarySettingsError(_ error: Error) -> Bool {
    if let serviceError = error as? DiarySettingsServiceError {
        return serviceError == .unauthorized
    }
    return (error as NSError).code == 401
}

/// A failed PUT that may still have reached the server. Definitive rejections
/// and auth failures are excluded; callers should reconcile ambiguous writes.
public func isAmbiguousDiarySettingsError(_ error: Error) -> Bool {
    if let serviceError = error as? DiarySettingsServiceError {
        switch serviceError {
        case .unauthorized, .rejected:
            return false
        case .networkUnavailable, .server, .cancelled, .unknown:
            return true
        }
    }
    if isUnauthorizedDiarySettingsError(error) {
        return false
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
    return true
}

public func diarySettingsErrorMessage(_ error: Error) -> String {
    if let serviceError = error as? DiarySettingsServiceError {
        switch serviceError {
        case .unauthorized:
            return String(localized: "diary.error.sessionExpired")
        case .networkUnavailable:
            return String(localized: "diary.error.network")
        case .server(let message), .rejected(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "settings.error.generic") : trimmed
        case .cancelled:
            return String(localized: "settings.error.cancelled")
        case .unknown:
            return String(localized: "settings.error.generic")
        }
    }

    if isUnauthorizedDiarySettingsError(error) {
        return String(localized: "diary.error.sessionExpired")
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return String(localized: "diary.error.network")
        default:
            break
        }
    }
    return String(localized: "settings.error.generic")
}

public enum DiaryGoalValidationError: Error, Equatable, Sendable {
    case invalidNumbers
    case caloriesNotPositive
    case macrosNegative
    case formulaMismatch

    public var message: String {
        switch self {
        case .invalidNumbers:
            return String(localized: "settings.goals.error.invalidNumbers")
        case .caloriesNotPositive:
            return String(localized: "settings.goals.error.caloriesPositive")
        case .macrosNegative:
            return String(localized: "settings.goals.error.macrosNonNegative")
        case .formulaMismatch:
            return String(localized: "settings.goals.error.formula")
        }
    }
}

public enum DiaryGoalForm {
    public static let maximumMagnitude = Decimal(1_000_000_000)
    public static let maximumFractionDigits = 5

    public static func validate(
        calories: String,
        protein: String,
        carbs: String,
        fat: String,
        locale: Locale = .current
    ) -> Result<GoalTargetsDecimal, DiaryGoalValidationError> {
        guard let calorieValue = decimal(calories, locale: locale),
              let proteinValue = decimal(protein, locale: locale),
              let carbsValue = decimal(carbs, locale: locale),
              let fatValue = decimal(fat, locale: locale) else {
            return .failure(.invalidNumbers)
        }
        guard calorieValue > 0 else {
            return .failure(.caloriesNotPositive)
        }
        guard proteinValue >= 0, carbsValue >= 0, fatValue >= 0 else {
            return .failure(.macrosNegative)
        }

        let expectedCalories = proteinValue * 4 + carbsValue * 4 + fatValue * 9
        guard calorieValue == expectedCalories else {
            return .failure(.formulaMismatch)
        }

        return .success(GoalTargetsDecimal(
            calorieTarget: calorieValue,
            proteinTargetG: proteinValue,
            carbsTargetG: carbsValue,
            fatTargetG: fatValue
        ))
    }

    /// Plain decimal input only for the current locale. Grouping separators,
    /// spaces, and mixed separators are rejected rather than truncated.
    public static func decimal(
        _ raw: String,
        locale: Locale = .current
    ) -> Decimal? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator
        if let groupingSeparator,
           !groupingSeparator.isEmpty,
           groupingSeparator != decimalSeparator,
           value.contains(groupingSeparator) {
            return nil
        }
        if value.contains(where: { $0.isWhitespace }) {
            return nil
        }

        var body = value
        if body.first == "+" || body.first == "-" {
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }

        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        let parts = body.components(separatedBy: decimalSeparator)
        guard parts.count <= 2 else { return nil }
        guard parts.allSatisfy({ part in
            part.unicodeScalars.allSatisfy { asciiDigits.contains($0) }
        }) else {
            return nil
        }
        if parts.count == 2 {
            guard !parts[0].isEmpty || !parts[1].isEmpty else { return nil }
            guard !parts[1].isEmpty else { return nil }
            guard parts[1].count <= maximumFractionDigits else { return nil }
        } else {
            guard !parts[0].isEmpty else { return nil }
        }
        guard parts.joined().contains(where: { $0.isNumber }) else { return nil }

        let normalized = decimalSeparator == "."
            ? value
            : value.replacingOccurrences(of: decimalSeparator, with: ".")
        guard let parsed = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            return nil
        }
        let magnitude = parsed < 0 ? -parsed : parsed
        guard magnitude <= maximumMagnitude else { return nil }
        return parsed
    }

    /// Locale-consistent, grouping-free formatting. Never force-unwraps or
    /// converts through a fixed-width integer, and never rounds unsupported
    /// precision silently.
    public static func text(for value: Double, locale: Locale = .current) -> String {
        guard let decimal = GoalDecimalMath.exactDecimal(for: value) else { return "" }
        return text(forDecimal: decimal, locale: locale)
    }

    public static func text(forDecimal value: Decimal, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 28
        formatter.generatesDecimalNumbers = true
        let ascii = formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
        let decimalSeparator = locale.decimalSeparator ?? "."
        guard decimalSeparator != "." else { return ascii }
        return ascii.replacingOccurrences(of: ".", with: decimalSeparator)
    }

    public static func isSupported(_ value: Double, locale: Locale = .current) -> Bool {
        guard let decimal = GoalDecimalMath.exactDecimal(for: value) else { return false }
        return isSupportedDecimal(decimal)
    }

    public static func isSupportedDecimal(_ value: Decimal) -> Bool {
        let magnitude = value < 0 ? -value : value
        guard magnitude <= maximumMagnitude else { return false }
        let text = text(forDecimal: value, locale: Locale(identifier: "en_US_POSIX"))
        guard let separatorIndex = text.firstIndex(of: ".") else { return true }
        let fractional = text[text.index(after: separatorIndex)...]
        return fractional.count <= maximumFractionDigits
    }

    /// Compare a server Double target with an exact edited Decimal target.
    public static func matches(
        _ value: Double,
        _ exact: Decimal,
        locale: Locale = .current
    ) -> Bool {
        guard let parsed = decimal(text(for: value, locale: locale), locale: locale) else {
            return false
        }
        return parsed == exact
    }
}
