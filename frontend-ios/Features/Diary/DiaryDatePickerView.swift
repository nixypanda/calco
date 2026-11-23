import SwiftUI

/// A small sheet that lets the user jump to any day up to and including today.
/// Selection is applied only on Done so dismissing never changes the diary date.
public struct DiaryDatePickerView: View {
    @Environment(\.dismiss) private var dismiss

    private let today: LocalDiaryDate
    private let todayDate: Date
    private let onSelect: (LocalDiaryDate) async -> Void

    @State private var pickedDate: Date
    @State private var didCommit = false

    public init(
        selection: LocalDiaryDate,
        today: LocalDiaryDate,
        onSelect: @escaping (LocalDiaryDate) async -> Void
    ) {
        self.today = today
        self.todayDate = DiaryDateConversion.date(from: today) ?? Date()
        self.onSelect = onSelect
        let initial = min(selection, today)
        _pickedDate = State(
            initialValue: DiaryDateConversion.date(from: initial) ?? todayDate
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DatePicker(
                        String(localized: "diary.datePicker.title"),
                        selection: $pickedDate,
                        in: ...todayDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("diary.datePicker")
                }
                .padding()
            }
            .navigationTitle(String(localized: "diary.calendar"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "diary.common.cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("diary.datePicker.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "diary.datePicker.done")) {
                        // Commit once. Dismiss immediately; the network-backed
                        // selection runs after the sheet is gone so a slow fetch
                        // can never hold the calendar on screen.
                        guard !didCommit else { return }
                        didCommit = true
                        let day = min(
                            DiaryDateConversion.day(from: pickedDate) ?? today,
                            today
                        )
                        dismiss()
                        Task { await onSelect(day) }
                    }
                    .disabled(didCommit)
                    .accessibilityIdentifier("diary.datePicker.done")
                }
            }
        }
#if os(iOS)
        // Full-height sheet keeps the graphical calendar from being clipped on
        // small phones and in landscape on iPad mini.
        .presentationDetents([.large])
#endif
    }
}
