import Foundation
import XCTest

@testable import CalCo

@MainActor
final class DiaryCalendarAndMacroTests: XCTestCase {
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 17)

    private actor EmptyDiaryService: DiaryServicing {
        func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
            DiaryDay(date: date)
        }
    }

    // MARK: - Calendar picker bridge

    func testDateRoundTripsThroughGregorianCalendar() throws {
        for day in [
            LocalDiaryDate(year: 2026, month: 1, day: 1),
            today,
            LocalDiaryDate(year: 2024, month: 2, day: 29),
            LocalDiaryDate(year: 2026, month: 12, day: 31),
        ] {
            let date = try XCTUnwrap(DiaryDateConversion.date(from: day))
            XCTAssertEqual(DiaryDateConversion.day(from: date), day)
        }
    }

    func testPickerNeverYieldsDateBeyondTodayForClampedSelection() throws {
        let future = today.addingDays(3)
        let clamped = min(future, today)
        XCTAssertEqual(clamped, today)

        let date = try XCTUnwrap(DiaryDateConversion.date(from: clamped))
        XCTAssertEqual(DiaryDateConversion.day(from: date), today)
        XCTAssertLessThanOrEqual(date, try XCTUnwrap(DiaryDateConversion.date(from: today)))
    }

    // MARK: - Macro grams / percent display

    func testMacroDisplayShowsGramsAndPercent() {
        let progress = DiaryGoalProgress(current: 30, target: 120)

        XCTAssertEqual(
            DiaryMacroDisplay.text(for: progress, mode: .grams),
            "30 / 120 g"
        )
        XCTAssertEqual(
            DiaryMacroDisplay.text(for: progress, mode: .percent),
            "25%"
        )
    }

    func testMacroPercentIsClampedAndHandlesMissingTarget() {
        XCTAssertEqual(
            DiaryMacroDisplay.text(
                for: DiaryGoalProgress(current: 300, target: 100),
                mode: .percent
            ),
            "100%"
        )
        XCTAssertEqual(
            DiaryMacroDisplay.text(
                for: DiaryGoalProgress(current: 0, target: 100),
                mode: .percent
            ),
            "0%"
        )
        XCTAssertEqual(
            DiaryMacroDisplay.text(
                for: DiaryGoalProgress(current: 100, target: 0),
                mode: .percent
            ),
            "—"
        )
        XCTAssertEqual(
            DiaryMacroDisplay.text(
                for: DiaryGoalProgress(current: 100, target: .nan),
                mode: .grams
            ),
            "100 g"
        )
    }

    func testMacroKindsProvideCompactAndAccessibleLabels() {
        XCTAssertEqual(DiaryMacroKind.protein.shortLabel, "P")
        XCTAssertEqual(DiaryMacroKind.carbs.shortLabel, "C")
        XCTAssertEqual(DiaryMacroKind.fat.shortLabel, "F")

        XCTAssertEqual(DiaryMacroKind.protein.fullLabel, "Protein")
        XCTAssertEqual(DiaryMacroKind.carbs.fullLabel, "Carbs")
        XCTAssertEqual(DiaryMacroKind.fat.fullLabel, "Fat")
        XCTAssertNotEqual(
            DiaryMacroKind.protein.fullLabel,
            String(localized: "diary.macros")
        )
    }

    func testMacroVoiceOverLabelIncludesFullNameAndValue() {
        let grams = DiaryMacroKind.protein.voiceOverLabel(
            progress: DiaryGoalProgress(current: 30, target: 120),
            mode: .grams
        )
        XCTAssertTrue(grams.contains(DiaryMacroKind.protein.fullLabel))
        XCTAssertTrue(grams.contains("30 / 120 g"))

        let percent = DiaryMacroKind.carbs.voiceOverLabel(
            progress: DiaryGoalProgress(current: 60, target: 240),
            mode: .percent
        )
        XCTAssertTrue(percent.contains(DiaryMacroKind.carbs.fullLabel))
        XCTAssertTrue(percent.contains("25%"))
    }

    func testMacroModeDefaultsToGramsAndCanBeToggled() {
        let vm = DiaryViewModel(service: EmptyDiaryService(), today: today)
        XCTAssertEqual(vm.macroMode, .grams)

        vm.setMacroMode(.percent)
        XCTAssertEqual(vm.macroMode, .percent)

        vm.setMacroMode(.percent)
        XCTAssertEqual(vm.macroMode, .percent)
    }

    // MARK: - Opening the editor from a diary row

    func testOpenLogEditorNotifiesWithSelectedDateAndLogID() async {
        let yesterday = today.addingDays(-1)
        let log = DiaryLog(id: "log-7", title: "Oats", quantity: NutritionQuantity(amount: "50", unit: "g"))
        let service = HistoricalDiaryService(log: log)
        let vm = DiaryViewModel(service: service, today: today, initialDate: yesterday)
        await vm.load()
        XCTAssertEqual(vm.selectedDate, yesterday)
        XCTAssertEqual(vm.log(withID: "log-7")?.quantity?.amount, "50")

        var opened: [(String, LocalDiaryDate)] = []
        vm.onOpenLogEditor = { id, date in opened.append((id, date)) }
        vm.openLogEditor(logID: "log-7")

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "log-7")
        XCTAssertEqual(opened.first?.1, yesterday)

        vm.openLogEditor(logID: "missing")
        XCTAssertEqual(opened.count, 1)
    }
}

private struct HistoricalDiaryService: DiaryServicing {
    let log: DiaryLog

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        DiaryDay(date: date, logs: [log])
    }
}
