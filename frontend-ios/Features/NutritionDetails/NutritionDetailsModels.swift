// Nutrition-details feature port, error vocabulary, and localized copy.

import Foundation

public enum NutritionDetailsServiceError: Error, Equatable, Sendable {
    case unauthorized
    case cancelled
    case networkUnavailable
    case server(String)
    case invalidResponse
    case unknown
}

public protocol NutritionDetailsServicing: Sendable {
    func fetchNutritionDetails(for date: LocalDiaryDate) async throws -> NutritionDetailsReport
}

public func isUnauthorizedNutritionDetailsError(_ error: Error) -> Bool {
    if let serviceError = error as? NutritionDetailsServiceError {
        return serviceError == .unauthorized
    }
    if let apiError = error as? CalCoAPIError {
        return apiError.isUnauthorized
    }
    return (error as NSError).code == 401
}

public func isCancelledNutritionDetailsError(_ error: Error) -> Bool {
    if let serviceError = error as? NutritionDetailsServiceError {
        return serviceError == .cancelled
    }
    if error is CancellationError {
        return true
    }
    if let apiError = error as? CalCoAPIError, apiError == .cancelled {
        return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

public func nutritionDetailsErrorMessage(_ error: Error) -> String {
    let generic = String(localized: "nutrition.error.generic")
    if let serviceError = error as? NutritionDetailsServiceError {
        switch serviceError {
        case .unauthorized:
            return String(localized: "nutrition.error.sessionExpired")
        case .cancelled:
            return generic
        case .networkUnavailable:
            return String(localized: "nutrition.error.network")
        case .server(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? generic : trimmed
        case .invalidResponse:
            return String(localized: "nutrition.error.invalidResponse")
        case .unknown:
            return generic
        }
    }

    if isUnauthorizedNutritionDetailsError(error) {
        return String(localized: "nutrition.error.sessionExpired")
    }
    if isCancelledNutritionDetailsError(error) {
        return generic
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
            return String(localized: "nutrition.error.network")
        default:
            break
        }
    }
    if (error as NSError).domain == NSURLErrorDomain {
        return String(localized: "nutrition.error.network")
    }
    return generic
}

/// All catalog keys used by the feature. Keeping copy in one place makes the
/// server's guidance branches explicit and keeps view code free of grammar.
enum NutritionDetailsCopy {
    static var title: String {
        String(localized: "nutrition.title")
    }

    static var loading: String {
        String(localized: "nutrition.loading")
    }

    static var previousDay: String {
        String(localized: "nutrition.previousDay")
    }

    static var nextDay: String {
        String(localized: "nutrition.nextDay")
    }

    static var retry: String {
        String(localized: "nutrition.retry")
    }

    static var overviewTitle: String {
        String(localized: "nutrition.overview")
    }

    static var overviewEmpty: String {
        String(localized: "nutrition.overview.empty")
    }

    static var sectionEmpty: String {
        String(localized: "nutrition.section.empty")
    }

    static var noData: String {
        String(localized: "nutrition.noData")
    }

    static var knownMinimum: String {
        String(localized: "nutrition.knownMinimum")
    }

    static var partialData: String {
        String(localized: "nutrition.partialData")
    }

    static var noKnownAmount: String {
        String(localized: "nutrition.noKnownAmount")
    }

    static var noDailyReference: String {
        String(localized: "nutrition.noDailyReference")
    }

    static var referenceReached: String {
        String(localized: "nutrition.referenceReached")
    }

    static var aboutReferences: String {
        String(localized: "nutrition.aboutReferences")
    }

    static var viewReferenceSource: String {
        String(localized: "nutrition.reference.source")
    }

    static var referenceSourceMissing: String {
        String(localized: "nutrition.reference.sourceMissing")
    }

    static var unknown: String {
        String(localized: "nutrition.unknown")
    }

    static var progressLabel: String {
        String(localized: "nutrition.progress.label")
    }

    static var progressOfReference: String {
        String(localized: "nutrition.progress.ofReference")
    }

    static var sessionExpiredTitle: String {
        String(localized: "nutrition.sessionExpired.title")
    }

    static var sessionExpiredMessage: String {
        String(localized: "nutrition.error.sessionExpired")
    }

    static var invalidResponse: String {
        String(localized: "nutrition.error.invalidResponse")
    }

    static func sectionTitle(_ section: NutritionDetailsSection) -> String {
        switch section {
        case .overview: String(localized: "nutrition.overview")
        case .carbohydrates: String(localized: "nutrition.section.carbohydrates")
        case .fats: String(localized: "nutrition.section.fats")
        case .limits: String(localized: "nutrition.section.limits")
        case .vitaminsMinerals: String(localized: "nutrition.section.vitaminsMinerals")
        }
    }

    static func coverageNotice(_ notice: NutritionDetailsNotice) -> String {
        switch notice {
        case .noItemsLogged:
            return String(localized: "nutrition.coverage.noItems")
        case .partialCoverage:
            return String(localized: "nutrition.coverage.partial")
        case .missingNutrients:
            return String(localized: "nutrition.coverage.missing")
        case .includedItems(let count):
            return String(
                format: String(localized: "nutrition.coverage.includedCount"),
                Int64(count)
            )
        }
    }

    static func amountDisplay(
        _ display: NutritionDetailsAmountDisplay,
        includeUnit: Bool = true
    ) -> String {
        switch display {
        case .unknown:
            return "\u{2014}"
        case .value(let amount, let unit):
            return NutritionDetailsFormat.amount(amount, unit: includeUnit ? unit : "")
        case .currentAndReference(let current, let reference, let unit):
            return "\(NutritionDetailsFormat.decimal(current)) / "
                + NutritionDetailsFormat.amount(reference, unit: includeUnit ? unit : "")
        case .unknownOfReference(let reference, let unit):
            return String(
                format: String(localized: "nutrition.unknownOfReference"),
                NutritionDetailsFormat.amount(reference, unit: includeUnit ? unit : "")
            )
        }
    }

    static func accessibilityAmountDisplay(_ display: NutritionDetailsAmountDisplay) -> String {
        switch display {
        case .unknown:
            return unknown
        case .unknownOfReference(let reference, let unit):
            return String(
                format: String(localized: "nutrition.unknownOfReferenceAccessibility"),
                NutritionDetailsFormat.amount(reference, unit: unit)
            )
        case .value, .currentAndReference:
            return amountDisplay(display)
        }
    }

    static func guidance(_ guidance: NutritionDetailsGuidance, unit: String) -> String {
        switch guidance {
        case .noData:
            return noData
        case .noKnownAmount:
            return noKnownAmount
        case .knownMinimum(let amount):
            return String(
                format: String(localized: "nutrition.knownMinimumAmount"),
                NutritionDetailsFormat.amount(amount, unit: unit)
            )
        case .noDailyReference:
            return noDailyReference
        case .referenceReached:
            return referenceReached
        case .toReference(let amount):
            return String(
                format: String(localized: "nutrition.toReference"),
                NutritionDetailsFormat.amount(amount, unit: unit)
            )
        case .overLimit(let amount):
            return String(
                format: String(localized: "nutrition.overLimit"),
                NutritionDetailsFormat.amount(amount, unit: unit)
            )
        case .withinLimit(let amount):
            return String(
                format: String(localized: "nutrition.remaining"),
                NutritionDetailsFormat.amount(amount, unit: unit)
            )
        }
    }

    static func overviewCaption(for coverage: NutritionDetailsCoverage) -> String? {
        switch coverage {
        case .none: noData
        case .partial: knownMinimum
        case .complete: nil
        }
    }

    static func advice(for code: String) -> String {
        switch code {
        case "FIBER_G":
            return String(localized: "nutrition.advice.fiber")
        case "SUGAR_G":
            return String(localized: "nutrition.advice.sugar")
        case "ADDED_SUGAR_G":
            return String(localized: "nutrition.advice.addedSugar")
        case "SATURATED_FAT_G":
            return String(localized: "nutrition.advice.saturatedFat")
        case "TRANS_FAT_G":
            return String(localized: "nutrition.advice.transFat")
        case "MONOUNSATURATED_FAT_G", "POLYUNSATURATED_FAT_G":
            return String(localized: "nutrition.advice.unsaturatedFats")
        case "SODIUM_MG":
            return String(localized: "nutrition.advice.sodium")
        case "CHOLESTEROL_MG":
            return String(localized: "nutrition.advice.cholesterol")
        case "POTASSIUM_MG":
            return String(localized: "nutrition.advice.potassium")
        case "CALCIUM_MG":
            return String(localized: "nutrition.advice.calcium")
        case "IRON_MG":
            return String(localized: "nutrition.advice.iron")
        case "MAGNESIUM_MG":
            return String(localized: "nutrition.advice.magnesium")
        case "VITAMIN_D_UG":
            return String(localized: "nutrition.advice.vitaminD")
        case "VITAMIN_B12_UG":
            return String(localized: "nutrition.advice.vitaminB12")
        default:
            return String(localized: "nutrition.advice.default")
        }
    }

    static func referenceDescription(_ reference: NutritionDetailsReference) -> String {
        String(
            format: String(localized: "nutrition.references.description"),
            reference.name,
            reference.authority,
            reference.jurisdiction,
            reference.populationLabel
        )
    }

    static func progressAccessibility(percent: Double) -> String {
        guard percent.isFinite else { return unknown }
        let formatted = (percent / 100).formatted(
            .percent.precision(.fractionLength(2))
        )
        return "\(formatted) \(progressOfReference)"
    }
}
