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

    public var focusedField: FocusState<LogFormField?>.Binding
    public var validationMessage: String? = nil
    public var isSubmitting = false
    public var mealSlotIdentifier = "foodDetail.mealSlot.picker"
    public var amountIdentifier = "foodDetail.amount.field"
    public var unitIdentifier = "foodDetail.unit.picker"
    public var validationIdentifier = "foodDetail.amount.error"
    public var notesIdentifier = "foodDetail.notes.field"

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
                    Text(DiaryLabels.mealSlotName(slot)).tag(MealSlot?.some(slot))
                }
            }
            .disabled(isSubmitting)
            .accessibilityIdentifier(mealSlotIdentifier)
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
                    .accessibilityIdentifier(amountIdentifier)
            }

            Picker(String(localized: "foodDetail.unit"), selection: $unit) {
                ForEach(units, id: \.code) { unit in
                    Text(unit.name).tag(unit.code)
                }
            }
            .pickerStyle(.menu)
            .disabled(isSubmitting)
            .accessibilityIdentifier(unitIdentifier)
        } footer: {
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityIdentifier(validationIdentifier)
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
                    .accessibilityIdentifier(notesIdentifier)
            }
        }
    }

}
