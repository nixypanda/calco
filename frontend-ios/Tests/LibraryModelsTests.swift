import XCTest

@testable import CalCo

final class LibraryModelsTests: XCTestCase {
    private let definitions: [NutrientDefinition] = [
        NutrientDefinition(code: "ENERGY_KCAL", name: "Energy", unit: "kcal", category: "energy"),
        NutrientDefinition(code: "PROTEIN_G", name: "Protein", unit: "g", category: "macro"),
        NutrientDefinition(code: "CARBS_G", name: "Carbohydrates", unit: "g", category: "macro"),
        NutrientDefinition(code: "FAT_G", name: "Fat", unit: "g", category: "macro"),
        NutrientDefinition(code: "FIBER_G", name: "Fiber", unit: "g", category: "macro"),
    ]

    private func requiredEditor(
        energy: String = "100",
        protein: String = "5",
        carbs: String = "10",
        fat: String = "2.5"
    ) -> NutrientEditorState {
        var editor = NutrientEditorState(definitions: definitions)
        editor.setAmount(energy, for: "ENERGY_KCAL")
        editor.setAmount(protein, for: "PROTEIN_G")
        editor.setAmount(carbs, for: "CARBS_G")
        editor.setAmount(fat, for: "FAT_G")
        return editor
    }

    private func form(
        name: String = "  Oats  ",
        servings: [CustomFoodServingInput] = [],
        defaultQuantity: String = "",
        defaultUnit: String = "",
        editor: NutrientEditorState? = nil
    ) -> CustomFoodFormValues {
        CustomFoodFormValues(
            name: name,
            brand: "  ",
            categoriesText: " Breakfast, breakfast, Oats ",
            defaultQuantity: defaultQuantity,
            defaultUnit: defaultUnit,
            servings: servings,
            nutrientEditor: editor ?? requiredEditor()
        )
    }

    // MARK: Create/edit distinctions

    func testCreateValidatesRequiredNutrientsWithoutServingsOrDefault() throws {
        let request = try form().validate().get()

        XCTAssertEqual(request.name, "Oats")
        XCTAssertNil(request.brand)
        XCTAssertEqual(request.categories, ["breakfast", "oats"])
        XCTAssertNil(request.defaultQuantity)
        XCTAssertNil(request.defaultUnit)
        XCTAssertTrue(request.servings.isEmpty)
        XCTAssertEqual(request.nutrients.map(\.code).sorted(), [
            "CARBS_G", "ENERGY_KCAL", "FAT_G", "PROTEIN_G",
        ])
    }

    func testZeroRequiredNutrientsAreSentButEmptyOptionalIsOmitted() throws {
        var editor = requiredEditor(energy: "0", protein: "0", carbs: "0", fat: "0")
        editor.addOptional(code: "FIBER_G")
        let request = try form(editor: editor).validate().get()

        XCTAssertEqual(request.nutrients.count, 4)
        XCTAssertTrue(request.nutrients.allSatisfy { $0.amountPer100g == 0 })
        XCTAssertFalse(request.nutrients.contains { $0.code == "FIBER_G" })

        editor.setAmount("0", for: "FIBER_G")
        let withZeroFiber = try form(editor: editor).validate().get()
        XCTAssertTrue(withZeroFiber.nutrients.contains { $0.code == "FIBER_G" })
    }

    func testMalformedAndNegativeNutrientsAreRejectedPerCode() {
        var editor = requiredEditor(energy: "-2")
        guard case .failure(.nutrients(.invalidAmount(let code))) =
            form(editor: editor).validate()
        else {
            return XCTFail("negative energy must be rejected")
        }
        XCTAssertEqual(code, "ENERGY_KCAL")

        editor.setAmount("1,2,3", for: "ENERGY_KCAL")
        guard case .failure(.nutrients(.invalidAmount(let commaCode))) =
            form(editor: editor).validate()
        else {
            return XCTFail("multiple separators must be rejected")
        }
        XCTAssertEqual(commaCode, "ENERGY_KCAL")
    }

    func testMissingRequiredNutrientsAreListed() {
        var editor = NutrientEditorState(definitions: definitions)
        editor.setAmount("1", for: "ENERGY_KCAL")
        guard case .failure(.nutrients(.missingRequired(let codes))) =
            form(editor: editor).validate()
        else {
            return XCTFail("missing nutrients must be rejected")
        }
        XCTAssertEqual(Set(codes), ["PROTEIN_G", "CARBS_G", "FAT_G"])
    }

    func testEmptyCatalogUsesCanonicalRequiredUnitsAndStillBlocksOptionalUnknown() throws {
        let editor = NutrientEditorState(
            definitions: [],
            initial: [
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "100", unit: ""),
                NutrientAmountValue(code: "PROTEIN_G", amount: "5", unit: "bogus"),
                NutrientAmountValue(code: "CARBS_G", amount: "10", unit: "bogus"),
                NutrientAmountValue(code: "FAT_G", amount: "2.5", unit: "bogus"),
            ]
        )

        XCTAssertEqual(editor.rows.map(\.code), CustomFoodNutrientCodes.required)
        XCTAssertEqual(editor.unit(for: "ENERGY_KCAL"), "kcal")
        XCTAssertEqual(editor.unit(for: "PROTEIN_G"), "g")
        XCTAssertEqual(editor.unit(for: "CARBS_G"), "g")
        XCTAssertEqual(editor.unit(for: "FAT_G"), "g")
        let request = try form(editor: editor).validate().get()
        XCTAssertEqual(
            Set(request.nutrients.map(\.code)),
            Set(CustomFoodNutrientCodes.required)
        )

        var withUnknown = NutrientEditorState(
            definitions: [],
            initial: [
                NutrientAmountValue(code: "MYSTERY", amount: "1", unit: "g"),
            ]
        )
        withUnknown.setAmount("100", for: "ENERGY_KCAL")
        withUnknown.setAmount("5", for: "PROTEIN_G")
        withUnknown.setAmount("10", for: "CARBS_G")
        withUnknown.setAmount("2.5", for: "FAT_G")
        guard case .failure(.nutrients(.unknownNutrient(let code))) =
            form(editor: withUnknown).validate()
        else {
            return XCTFail("optional unknown nutrients must remain blocked")
        }
        XCTAssertEqual(code, "MYSTERY")
    }

    func testUnknownInitialNutrientBlocksSaveInsteadOfBeingDropped() {
        var editor = requiredEditor()
        editor = NutrientEditorState(
            definitions: definitions,
            initial: (editor.validated().successValue ?? [])
                + [NutrientAmountValue(code: "MYSTERY", amount: "1", unit: "g")]
        )
        guard case .failure(.nutrients(.unknownNutrient(let code))) =
            form(editor: editor).validate()
        else {
            return XCTFail("unknown nutrient must be rejected")
        }
        XCTAssertEqual(code, "MYSTERY")
    }

    func testServingValidationAndDefaultUnitRule() throws {
        let duplicate = form(
            servings: [
                .init(unit: "cup", gramsPerUnit: "40"),
                .init(unit: "cup", gramsPerUnit: "50"),
            ]
        )
        guard case .failure(.servingUnitDuplicate("cup")) = duplicate.validate()
        else { return XCTFail("duplicate serving unit must fail") }

        let zero = form(servings: [.init(unit: "cup", gramsPerUnit: "0")])
        guard case .failure(.servingGramsInvalid("cup")) = zero.validate()
        else { return XCTFail("zero grams must fail") }

        let badDefault = form(
            servings: [.init(unit: "cup", gramsPerUnit: "40")],
            defaultQuantity: "1",
            defaultUnit: "bowl"
        )
        guard case .failure(.defaultUnitUnsupported("bowl")) = badDefault.validate()
        else { return XCTFail("unsupported default unit must fail") }

        let good = try form(
            servings: [.init(unit: "cup", gramsPerUnit: "40")],
            defaultQuantity: "1",
            defaultUnit: "cup"
        ).validate().get()
        XCTAssertEqual(good.defaultQuantity, 1)
        XCTAssertEqual(good.defaultUnit, "cup")
        XCTAssertEqual(good.servings.count, 1)
    }

    // MARK: Ad-hoc totals and save-and-log derivation

    func testAdHocSendsAbsoluteNutrientsIncludingKnownZero() throws {
        var editor = requiredEditor(
            energy: "250",
            protein: "10",
            carbs: "40",
            fat: "5"
        )
        editor.addOptional(code: "FIBER_G")
        editor.setAmount("0", for: "FIBER_G")
        let values = AdHocLogFormValues(
            name: "  Bowl  ",
            brand: " Cafe ",
            date: LocalDiaryDate(year: 2026, month: 11, day: 19),
            mealSlot: .lunch,
            amount: "1",
            unit: "bowl",
            notes: " note ",
            nutrientEditor: editor
        )
        let draft = try values.validate(timeZone: "Asia/Kolkata").get()

        XCTAssertEqual(draft.item, .adHoc(name: "Bowl", brand: "Cafe"))
        XCTAssertEqual(draft.amount, "1")
        XCTAssertEqual(draft.unit, "bowl")
        XCTAssertEqual(draft.mealSlot, .lunch)
        XCTAssertEqual(draft.notes, "note")
        XCTAssertEqual(draft.timeZone, "Asia/Kolkata")
        XCTAssertEqual(draft.nutrients?.count, 5)
        XCTAssertEqual(
            draft.nutrients?.first { $0.code == "ENERGY_KCAL" }?.amount,
            "250"
        )
    }

    func testAdHocRequiresPositiveQuantityAndCoreNutrients() {
        let values = AdHocLogFormValues(
            name: "Bowl",
            date: LocalDiaryDate(year: 2026, month: 11, day: 19),
            amount: "0",
            unit: "bowl",
            nutrientEditor: requiredEditor()
        )
        guard case .failure(.quantityInvalid) = values.validate(timeZone: "UTC")
        else { return XCTFail("zero quantity must fail") }

        let noCore = AdHocLogFormValues(
            name: "Bowl",
            date: LocalDiaryDate(year: 2026, month: 11, day: 19),
            amount: "1",
            unit: "bowl",
            nutrientEditor: NutrientEditorState(definitions: definitions)
        )
        guard case .failure(.nutrients(.missingRequired)) =
            noCore.validate(timeZone: "UTC")
        else { return XCTFail("missing core nutrients must fail") }
    }

    func testGramSaveAndLogDerivesPer100gWithoutServing() throws {
        let values = AdHocLogFormValues(
            name: "Oats",
            date: LocalDiaryDate(year: 2026, month: 11, day: 19),
            amount: "250",
            unit: "g",
            nutrientEditor: requiredEditor(
                energy: "250",
                protein: "10",
                carbs: "40",
                fat: "5"
            )
        )
        let request = try values.makeCustomFoodWriteRequest(
            portionWeightText: "ignored-for-grams"
        ).get()

        XCTAssertEqual(request.defaultQuantity, 250)
        XCTAssertEqual(request.defaultUnit, "g")
        XCTAssertTrue(request.servings.isEmpty)
        XCTAssertEqual(
            request.nutrients.first { $0.code == "ENERGY_KCAL" }?.amountPer100g,
            100
        )
        XCTAssertEqual(
            request.nutrients.first { $0.code == "PROTEIN_G" }?.amountPer100g,
            4
        )
    }

    func testNonGramSaveAndLogDerivesServingAndRequiresWeight() throws {
        let values = AdHocLogFormValues(
            name: "Curry bowl",
            date: LocalDiaryDate(year: 2026, month: 11, day: 19),
            amount: "2",
            unit: "bowl",
            nutrientEditor: requiredEditor(
                energy: "400",
                protein: "20",
                carbs: "40",
                fat: "10"
            )
        )
        guard case .failure(.portionWeightRequired) =
            values.makeCustomFoodWriteRequest(portionWeightText: "")
        else { return XCTFail("non-gram save must require portion weight") }

        let request = try values.makeCustomFoodWriteRequest(
            portionWeightText: "300"
        ).get()
        XCTAssertEqual(request.defaultQuantity, 2)
        XCTAssertEqual(request.defaultUnit, "bowl")
        XCTAssertEqual(request.servings, [
            CustomFoodServingWrite(unit: "bowl", gramsPerUnit: 150),
        ])
        XCTAssertEqual(
            request.nutrients.first { $0.code == "ENERGY_KCAL" }?.amountPer100g,
            133.333333
        )
    }

    // MARK: Reconciliation matching

    func testCandidateMatchingNormalizesOrderAndScaleAndExcludesBaseline() {
        let draft = CustomFoodWriteRequest(
            name: "Oats",
            categories: ["oats", "breakfast"],
            nutrients: [
                .init(code: "PROTEIN_G", amountPer100g: 4),
                .init(code: "ENERGY_KCAL", amountPer100g: 100),
            ],
            servings: []
        )
        let product = ProductDetail(
            id: "new-food",
            source: "USER",
            visibility: "global",
            name: "Oats",
            categories: ["breakfast", "oats"],
            nutrients: [
                ProductNutrient(code: "ENERGY_KCAL", amountPer100g: "100.000000", unit: "kcal"),
                ProductNutrient(code: "PROTEIN_G", amountPer100g: "4.000000", unit: "g"),
            ]
        )
        let attempt = CustomFoodCreateAttempt(
            accountID: "account",
            draft: draft,
            baselineFoodIDs: ["old-food"],
            message: "uncertain"
        )

        XCTAssertEqual(attempt.matches(in: [CustomFood(product: product)]).map(\.id), [
            "new-food",
        ])
        let baselineFood = CustomFood(product: product)
        let withBaseline = CustomFoodCreateAttempt(
            accountID: "account",
            draft: draft,
            baselineFoodIDs: ["new-food"],
            message: "uncertain"
        )
        XCTAssertTrue(withBaseline.matches(in: [baselineFood]).isEmpty)
    }

    func testCatalogDecimalCanonicalizesAndRejectsMalformedInput() {
        XCTAssertEqual(CatalogDecimal.parseNonNegative("1,5"), Decimal(string: "1.5"))
        XCTAssertEqual(CatalogDecimal.parseNonNegative("-1"), nil)
        XCTAssertEqual(CatalogDecimal.parseNonNegative("1.2.3"), nil)
        XCTAssertEqual(CatalogDecimal.parseNonNegative("abc"), nil)
        XCTAssertEqual(CatalogDecimal.canonical(Decimal(string: "1.5000000")!), "1.5")
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
