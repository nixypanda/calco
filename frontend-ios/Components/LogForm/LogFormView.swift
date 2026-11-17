import SwiftUI

public enum LogFormField: Hashable, Sendable {
    case amount
    case notes
}

public struct LogFormView: View {
    @Binding public var amount: String
    @Binding public var unit: String
    public let units: [FoodUnit]
    @Binding public var mealSlot: MealSlot?
    @Binding public var notes: String

    public var validationMessage: String?
    public var isSubmitting: Bool
    public var focusedField: FocusState<LogFormField?>.Binding

    public init(
        amount: Binding<String>,
        unit: Binding<String>,
        units: [FoodUnit],
        mealSlot: Binding<MealSlot?>,
        notes: Binding<String>,
        focusedField: FocusState<LogFormField?>.Binding,
        validationMessage: String? = nil,
        isSubmitting: Bool = false
    ) {
        _amount = amount
        _unit = unit
        self.units = units
        _mealSlot = mealSlot
        _notes = notes
        self.focusedField = focusedField
        self.validationMessage = validationMessage
        self.isSubmitting = isSubmitting
    }

    public var body: some View {
        mealSection
        amountSection
        notesSection
    }


    private var mealSection: some View {
        Section {
            Picker(String(localized: "foodDetail.mealSlot"), selection: $mealSlot) {
                Text(String(localized: "foodDetail.mealSlot.none")).tag(MealSlot?.none)
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    Text(mealSlotLabel(slot)).tag(MealSlot?.some(slot))
                }
            }
            .disabled(isSubmitting)
            .accessibilityIdentifier("foodDetail.mealSlot.picker")
        }
    }

    private var amountSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "foodDetail.amount"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "foodDetail.amount"), text: $amount)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .focused(focusedField, equals: .amount)
                    .disabled(isSubmitting)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "foodDetail.amount"))
                    .accessibilityIdentifier("foodDetail.amount.field")
            }

            Picker(String(localized: "foodDetail.unit"), selection: $unit) {
                ForEach(units, id: \.code) { unit in
                    Text(unit.name).tag(unit.code)
                }
            }
            .pickerStyle(.menu)
            .disabled(isSubmitting)
            .accessibilityIdentifier("foodDetail.unit.picker")
        } footer: {
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityIdentifier("foodDetail.amount.error")
            }
        }
    }

    private var notesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "foodDetail.notes"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "foodDetail.notes"), text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                    .focused(focusedField, equals: .notes)
                    .disabled(isSubmitting)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "foodDetail.notes"))
                    .accessibilityIdentifier("foodDetail.notes.field")
            }
        }
    }

    private func mealSlotLabel(_ slot: MealSlot) -> String {
        switch slot {
        case .breakfast:
            return String(localized: "foodDetail.mealSlot.breakfast")
        case .lunch:
            return String(localized: "foodDetail.mealSlot.lunch")
        case .dinner:
            return String(localized: "foodDetail.mealSlot.dinner")
        case .snack:
            return String(localized: "foodDetail.mealSlot.snack")
        case .lateNightSnack:
            return String(localized: "foodDetail.mealSlot.lateNightSnack")
        }
    }
}
