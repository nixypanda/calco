// Shared fixtures for the nutrition-details tests. All values mirror the
// server contract; no network, database, or live diary is used.

import Foundation

@testable import CalCo

enum NutritionDetailsTestFixtures {
    static let day = LocalDiaryDate(year: 2026, month: 8, day: 14)
    static let yesterday = LocalDiaryDate(year: 2026, month: 8, day: 13)
    static let today = LocalDiaryDate(year: 2026, month: 8, day: 15)

    static func decimal(_ raw: String) -> Decimal {
        Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))!
    }

    static func reference() -> NutritionDetailsReference {
        NutritionDetailsReference(
            code: "us_fda_dv_adult_2020",
            name: "FDA Nutrition Facts Daily Values",
            authority: "U.S. Food and Drug Administration",
            jurisdiction: "US",
            populationLabel: "Adults and children 4 years and older",
            sourceURL: "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels"
        )
    }

    static func nutrient(
        code: String = "FIBER_G",
        name: String = "Dietary Fiber",
        section: NutritionDetailsSection = .carbohydrates,
        knownAmount: Decimal? = nil,
        unit: String = "g",
        referenceAmount: Decimal? = nil,
        guidanceKind: NutritionDetailsGuidanceKind = .adequacy,
        itemsWithData: Int = 1,
        coverage: NutritionDetailsCoverage = .partial,
        status: NutritionDetailsStatus = .partialData
    ) -> NutritionDetailsNutrient {
        NutritionDetailsNutrient(
            code: code,
            name: name,
            section: section,
            knownAmount: knownAmount,
            unit: unit,
            referenceAmount: referenceAmount,
            guidanceKind: guidanceKind,
            itemsWithData: itemsWithData,
            coverage: coverage,
            status: status
        )
    }

    static func report(
        date: LocalDiaryDate = day,
        loggedItems: Int = 1,
        nutrients: [NutritionDetailsNutrient]? = nil
    ) -> NutritionDetailsReport {
        NutritionDetailsReport(
            date: date,
            reference: reference(),
            loggedItems: loggedItems,
            nutrients: nutrients ?? [
                nutrient(
                    code: "FIBER_G",
                    knownAmount: decimal("18"),
                    referenceAmount: decimal("28"),
                    itemsWithData: 1,
                    coverage: .complete,
                    status: .belowReference
                )
            ]
        )
    }

    /// Server response fixture exercising every section, all guidance kinds,
    /// all coverage values, all statuses, decimal strings, JSON numbers, zero,
    /// null, a missing reference, and a zero reference.
    static let sampleJSON = #"""
    {
      "date": "2026-08-14",
      "reference": {
        "code": "us_fda_dv_adult_2020",
        "name": "FDA Nutrition Facts Daily Values",
        "authority": "U.S. Food and Drug Administration",
        "jurisdiction": "US",
        "population_label": "Adults and children 4 years and older",
        "source_url": "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels"
      },
      "logged_items": 2,
      "nutrients": [
        {
          "code": "ENERGY_KCAL",
          "name": "Energy",
          "section": "overview",
          "known_amount": "0",
          "unit": "kcal",
          "reference_amount": null,
          "guidance_kind": "informational",
          "items_with_data": 1,
          "coverage": "partial",
          "status": "partial_data"
        },
        {
          "code": "PROTEIN_G",
          "name": "Protein",
          "section": "overview",
          "known_amount": 10,
          "unit": "g",
          "reference_amount": null,
          "guidance_kind": "informational",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "available"
        },
        {
          "code": "FIBER_G",
          "name": "Dietary Fiber",
          "section": "carbohydrates",
          "known_amount": null,
          "unit": "g",
          "reference_amount": "28",
          "guidance_kind": "adequacy",
          "items_with_data": 0,
          "coverage": "none",
          "status": "no_data"
        },
        {
          "code": "SUGAR_G",
          "name": "Total Sugars",
          "section": "carbohydrates",
          "known_amount": "5",
          "unit": "g",
          "reference_amount": null,
          "guidance_kind": "informational",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "available"
        },
        {
          "code": "ADDED_SUGAR_G",
          "name": "Added Sugars",
          "section": "carbohydrates",
          "known_amount": "0",
          "unit": "g",
          "reference_amount": "50",
          "guidance_kind": "maximum",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "within_limit"
        },
        {
          "code": "SATURATED_FAT_G",
          "name": "Saturated Fat",
          "section": "fats",
          "known_amount": "25",
          "unit": "g",
          "reference_amount": 20,
          "guidance_kind": "maximum",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "over_limit"
        },
        {
          "code": "TRANS_FAT_G",
          "name": "Trans Fat",
          "section": "fats",
          "known_amount": "0",
          "unit": "g",
          "reference_amount": null,
          "guidance_kind": "informational",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "available"
        },
        {
          "code": "SODIUM_MG",
          "name": "Sodium",
          "section": "limits",
          "known_amount": "2400",
          "unit": "mg",
          "reference_amount": "2300",
          "guidance_kind": "maximum",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "over_limit"
        },
        {
          "code": "POTASSIUM_MG",
          "name": "Potassium",
          "section": "vitamins_minerals",
          "known_amount": "4700",
          "unit": "mg",
          "reference_amount": "4700",
          "guidance_kind": "adequacy",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "met_reference"
        },
        {
          "code": "MAGNESIUM_MG",
          "name": "Magnesium",
          "section": "vitamins_minerals",
          "known_amount": "184.2",
          "unit": "mg",
          "reference_amount": "420",
          "guidance_kind": "adequacy",
          "items_with_data": 1,
          "coverage": "partial",
          "status": "partial_data"
        },
        {
          "code": "VITAMIN_D_UG",
          "name": "Vitamin D",
          "section": "vitamins_minerals",
          "known_amount": "5",
          "unit": "ug",
          "reference_amount": null,
          "guidance_kind": "adequacy",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "below_reference"
        },
        {
          "code": "CALCIUM_MG",
          "name": "Calcium",
          "section": "vitamins_minerals",
          "known_amount": "10",
          "unit": "mg",
          "reference_amount": "0",
          "guidance_kind": "adequacy",
          "items_with_data": 2,
          "coverage": "complete",
          "status": "below_reference"
        }
      ]
    }
    """#
}
