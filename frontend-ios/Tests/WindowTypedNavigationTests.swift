import ComposableArchitecture
import XCTest

@testable import CalCo

/// Contract tests for the whole-port typed navigation authority owned by
/// `WindowFeature`. Every typed payload must be generation/account guarded and
/// request-identity deduplicated so a stale or wrong-account callback can never
/// navigate or clear a newer presentation.
@MainActor
final class WindowTypedNavigationTests: XCTestCase {
    private let generation = UInt64(7)
    private let accountID = "acct-1"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)

    private func context(
        generation: UInt64? = nil,
        accountID: String? = nil,
        presentationID: UUID
    ) -> WindowCaptureContext {
        WindowCaptureContext(
            date: date,
            slot: .breakfast,
            accountID: accountID ?? self.accountID,
            generation: generation ?? self.generation,
            origin: .diary,
            presentationID: presentationID
        )
    }

    private func makeStore() -> TestStore<WindowFeature.State, WindowFeature.Action> {
        TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                sessionAccountID: accountID
            )
        ) {
            WindowFeature()
        }
    }

    func testPushDestinationAppendsWithCapturedContext() async {
        let store = makeStore()
        let presentationID = UUID()
        let destination = WindowDestination.logEditor(
            id: "log-1",
            context: context(presentationID: presentationID)
        )

        await store.send(.pushDestination(destination)) {
            $0.destinationStack = [destination]
        }
        await store.finish()
    }

    func testPushDestinationRejectsStaleGeneration() async {
        let store = makeStore()
        let destination = WindowDestination.foodDetail(
            id: "food-1",
            context: context(generation: generation - 1, presentationID: UUID())
        )
        await store.send(.pushDestination(destination))
        await store.finish()
    }

    func testPushDestinationRejectsWrongAccount() async {
        let store = makeStore()
        let destination = WindowDestination.meals(
            context: context(accountID: "acct-2", presentationID: UUID())
        )
        await store.send(.pushDestination(destination))
        await store.finish()
    }

    func testPushDestinationDedupsPresentationIdentity() async {
        let store = makeStore()
        let presentationID = UUID()
        let destination = WindowDestination.library(
            context: context(presentationID: presentationID)
        )
        await store.send(.pushDestination(destination)) {
            $0.destinationStack = [destination]
        }
        await store.send(.pushDestination(destination))
        await store.finish()
    }

    func testPopAndPopToRoot() async {
        let store = makeStore()
        let first = WindowDestination.library(context: context(presentationID: UUID()))
        let secondID = UUID()
        let second = WindowDestination.meals(context: context(presentationID: secondID))
        await store.send(.pushDestination(first)) {
            $0.destinationStack = [first]
        }
        await store.send(.pushDestination(second)) {
            $0.destinationStack = [first, second]
            if case let .meals(ctx) = second {
                $0.meals = MealsFlowFeature.State(
                    context: MealsCaptureContext(
                        id: secondID,
                        date: ctx.date,
                        mealSlot: ctx.slot,
                        accountID: ctx.accountID,
                        generation: ctx.generation,
                        origin: .sheet
                    )
                )
            }
        }
        await store.send(.popDestination) {
            $0.destinationStack = [first]
        }
        await store.send(.popDestinationToRoot) {
            $0.destinationStack = []
        }
        await store.finish()
    }

    func testSelectTabResetsDestinationStackAndPresentation() async {
        let store = makeStore()
        let settingsID = UUID()
        store.dependencies.uuid = .constant(settingsID)
        let destination = WindowDestination.library(context: context(presentationID: UUID()))
        let presentation = WindowPresentation.barcode(context: context(presentationID: UUID()))
        await store.send(.pushDestination(destination)) {
            $0.destinationStack = [destination]
        }
        await store.send(.present(presentation)) {
            $0.presentation = presentation
            $0.barcode = BarcodeFeature.State(sessionGeneration: self.generation)
        }
        // Settings is a real tab in the restored UX: switching to it creates
        // the one guarded Settings child while clearing the prior stack/sheet.
        await store.send(.selectTab(.account)) {
            $0.selectedTab = .account
            $0.destinationStack = []
            $0.presentation = nil
            $0.barcode = nil
            $0.settings = SettingsFeature.State(
                accountID: self.accountID,
                today: self.today,
                timeZone: .current,
                sessionGeneration: self.generation,
                id: settingsID,
                locale: .current
            )
        }
        await store.finish()
    }

    func testDismissPresentationRequiresMatchingIdentity() async {
        let store = makeStore()
        let presentationID = UUID()
        let presentation = WindowPresentation.quickAdd(
            context: context(presentationID: presentationID)
        )
        await store.send(.present(presentation)) {
            $0.presentation = presentation
        }
        await store.send(.dismissPresentation(expectedPresentationID: UUID()))
        await store.send(.dismissPresentation(expectedPresentationID: presentationID)) {
            $0.presentation = nil
        }
        await store.finish()
    }

    func testPresentRejectsStaleGeneration() async {
        let store = makeStore()
        let presentation = WindowPresentation.assistant(
            context: context(generation: generation + 1, presentationID: UUID())
        )
        await store.send(.present(presentation))
        await store.finish()
    }

    func testDesiredPrefixDropsMultipleLevelsAndRejectsStaleOrForeignPaths() async {
        let first = WindowDestination.library(context: context(presentationID: UUID()))
        let second = WindowDestination.search(context: context(presentationID: UUID()))
        let third = WindowDestination.logEditor(id: "missing", context: context(presentationID: UUID()))
        let stack = [first, second, third]
        let store = TestStore(initialState: WindowFeature.State(
            sessionGeneration: generation, today: today, sessionAccountID: accountID,
            destinationStack: stack
        )) { WindowFeature() }
        await store.send(.requestPathChange(WindowPathChange(tab: .search, expected: stack, desired: [])))
        await store.send(.requestPathChange(WindowPathChange(tab: .diary, expected: stack, desired: [second])))
        let change = WindowPathChange(tab: .diary, expected: stack, desired: [first])
        await store.send(.requestPathChange(change))
        await store.receive(\.applyPathChange, change) { $0.destinationStack = [first] }
        await store.send(.requestPathChange(change))
        let root = WindowPathChange(tab: .diary, expected: [first], desired: [])
        await store.send(.requestPathChange(root))
        await store.receive(\.applyPathChange, root) { $0.destinationStack = [] }
        await store.finish()
    }

    func testMixedLibraryPopDefersEntirePrefixUntilDiscardAndBusyBlocksIt() async {
        let editorContext = context(presentationID: UUID())
        let first = WindowDestination.search(context: context(presentationID: UUID()))
        let editorRoute = WindowDestination.logEditor(id: "log-1", context: editorContext)
        var editor = LogEditorFeature.State(
            log: DiaryLog(id: "log-1", mealSlot: .breakfast, title: "Oats", calories: 300,
                          quantity: NutritionQuantity(amount: "150", unit: "g")),
            date: date, accountID: accountID, sessionGeneration: generation,
            presentationID: editorContext.presentationID
        )
        editor.amount = "275"
        var initial = WindowFeature.State(
            sessionGeneration: generation, today: today, sessionAccountID: accountID,
            selectedTab: .library, destinationStack: [first, editorRoute], logEditor: editor
        )
        initial.libraryHubPath = [.foods]
        let change = WindowPathChange(tab: .library, expected: [first, editorRoute], desired: [],
                                      expectedHub: [.foods], desiredHub: [])
        let store = TestStore(initialState: initial) { WindowFeature() }
        await store.send(.requestPathChange(change)) { $0.pendingEditorDiscard = .path(change) }
        await store.send(.cancelEditorDiscard) { $0.pendingEditorDiscard = nil }
        await store.send(.requestPathChange(change)) { $0.pendingEditorDiscard = .path(change) }
        await store.send(.confirmEditorDiscard) { $0.pendingEditorDiscard = nil }
        await store.receive(\.applyPathChange, change) {
            $0.destinationStack = []
            $0.libraryHubPath = []
            $0.logEditor = nil
        }
        await store.finish()
        for phase in [LogEditorFeature.Phase.saving(requestID: UUID()), .deleting(requestID: UUID())] {
            var busy = initial
            busy.logEditor?.phase = phase
            let busyStore = TestStore(initialState: busy) { WindowFeature() }
            await busyStore.send(.requestPathChange(change))
            await busyStore.finish()
        }
    }

    func testLibraryGlobalPopPreservesHubAndSupportsNextRealPush() async {
        let first = WindowDestination.library(context: context(presentationID: UUID()))
        let second = WindowDestination.logEditor(id: "missing", context: context(presentationID: UUID()))
        var initial = WindowFeature.State(
            sessionGeneration: generation, today: today, sessionAccountID: accountID,
            selectedTab: .library, destinationStack: [first, second]
        )
        initial.libraryHubPath = [.foods]
        let store = TestStore(initialState: initial) { WindowFeature() }
        let change = WindowPathChange(tab: .library, expected: [first, second], desired: [],
                                      expectedHub: [.foods], desiredHub: [.foods])
        await store.send(.requestPathChange(change))
        await store.receive(\.applyPathChange, change) { $0.destinationStack = [] }
        await store.send(.pushDestination(first)) { $0.destinationStack = [first] }
        await store.send(.pushDestination(second)) { $0.destinationStack = [first, second] }
        await store.finish()
    }
}
