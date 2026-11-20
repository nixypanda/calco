import Combine
import Foundation
import SwiftUI

public enum FoodDetailLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

private enum FoodDetailResolvedState: Equatable, Sendable {
    case loading
    case loaded(FoodDetail)
    case failed(String)
}

public enum FoodDetailSubmitState: Equatable, Sendable {
    case idle
    case submitting
    case failed(String)
    case uncertain(String)
    case conflict(String)
    case rateLimited(String)
    case succeeded
}

public enum FoodDetailRecoveryState: Equatable, Sendable {
    case idle
    case retrying(String)
    case succeeded(String)
    case failed(String)
    case conflicted(String)
}

@MainActor
public final class FoodDetailViewModel: ObservableObject {
    @Published private var resolvedState: FoodDetailResolvedState = .loading
    @Published public var units: [FoodUnit] = []
    @Published public var amount: String = "" {
        didSet { if amount != oldValue { formDidChange() } }
    }
    @Published public var unit: String = "" {
        didSet { if unit != oldValue { formDidChange() } }
    }
    @Published public var mealSlot: MealSlot? {
        didSet { if mealSlot != oldValue { formDidChange() } }
    }
    @Published public var notes: String = "" {
        didSet { if notes != oldValue { formDidChange() } }
    }
    @Published public var submitState: FoodDetailSubmitState = .idle
    @Published public private(set) var recoveryState: FoodDetailRecoveryState = .idle
    @Published public private(set) var pendingSubmissions: [PendingLogSubmission] = []
    @Published public private(set) var hidesPendingNotice = false
    /// Explains a visible fallback when the last-used amount could not be
    /// applied (for example, an unavailable unit). Nil when no fallback.
    @Published public private(set) var lastUsedNotice: String?
    /// Set when normal Log was refused because an unresolved journal entry
    /// matches this draft. The only way past it is an explicit retry or an
    /// explicitly confirmed new logical submission.
    @Published public private(set) var newSubmissionConfirmation: PendingLogSubmission?

    public let foodID: String
    public let originDate: LocalDiaryDate
    public let originMealSlot: MealSlot?
    public let accountID: String
    public private(set) var lastSubmissionSuccess: FoodLogSubmissionSuccess?

    private let service: FoodDetailServicing
    private let onSuccess: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void
    private let onSubmissionSuccess: ((FoodLogSubmissionSuccess) -> Void)?
    private let onCheckDiary: ((LocalDiaryDate) -> Void)?
    private let displayFoodName: String?
    private let baseURL: URL?
    private let submissionStore: LogSubmissionStore?
    private let timeZoneProvider: () -> String
    private let idGenerator: () -> String
    private let singleCapabilityEnsure: () async -> Bool
    private let durableContextProvider: FoodDetailSubmissionContextProvider?

    // In-memory handle for the current logical attempt. Any form edit clears
    // it, so A -> B -> A never silently revives A's key. Persisted entries stay
    // in the journal for explicit recovery.
    private var currentAttempt: PendingLogSubmission?
    private var boundSubmissionContext: LogSubmissionSessionContext?
    private var frozenTimeZone: String?
    private var lastPendingIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var quantityWasEdited = false
    private var formWasEdited = false
    private var isApplyingDefaultQuantity = false
    private var hasAttemptedSubmission = false
    private var lastUsedTask: Task<Void, Never>?

    /// Legacy/offline initializer retained for existing fakes and tests. It has
    /// no authoritative session-context binding; production must use the
    /// `submissionContextProvider` initializer below.
    public init(
        foodID: String,
        originDate: LocalDiaryDate,
        originMealSlot: MealSlot? = nil,
        service: FoodDetailServicing,
        onSuccess: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        onSubmissionSuccess: ((FoodLogSubmissionSuccess) -> Void)? = nil,
        onCheckDiary: ((LocalDiaryDate) -> Void)? = nil,
        accountID: String = "",
        foodName: String? = nil,
        baseURL: URL? = nil,
        submissionStore: LogSubmissionStore? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        idGenerator: @escaping () -> String = { UUID().uuidString.lowercased() },
        singleCapabilityEnsure: (() async -> Bool)? = nil,
        singleCapabilityReady: @escaping () -> Bool = { true }
    ) {
        self.foodID = foodID
        self.originDate = originDate
        self.originMealSlot = originMealSlot
        self.service = service
        self.onSuccess = onSuccess
        self.onSessionExpired = onSessionExpired
        self.onSubmissionSuccess = onSubmissionSuccess
        self.onCheckDiary = onCheckDiary
        self.accountID = accountID
        self.displayFoodName = foodName
        self.baseURL = baseURL
        self.submissionStore = submissionStore
        self.timeZoneProvider = timeZoneProvider
        self.idGenerator = idGenerator
        self.singleCapabilityEnsure = singleCapabilityEnsure ?? { singleCapabilityReady() }
        self.durableContextProvider = nil
        self.mealSlot = originMealSlot

        submissionStore?.$revision
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshRecoveryEntries()
            }
            .store(in: &cancellables)
    }

    /// Durable context-bound submission used by production. The captured
    /// shared session context is authoritative; the legacy initializer above
    /// is retained only for offline/legacy test doubles.
    public init(
        foodID: String,
        originDate: LocalDiaryDate,
        originMealSlot: MealSlot? = nil,
        service: FoodDetailServicing,
        onSuccess: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        onSubmissionSuccess: ((FoodLogSubmissionSuccess) -> Void)? = nil,
        onCheckDiary: ((LocalDiaryDate) -> Void)? = nil,
        accountID: String,
        foodName: String? = nil,
        baseURL: URL? = nil,
        submissionStore: LogSubmissionStore,
        submissionContextProvider: @escaping FoodDetailSubmissionContextProvider,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        idGenerator: @escaping () -> String = { UUID().uuidString.lowercased() },
        singleCapabilityEnsure: @escaping () async -> Bool
    ) {
        self.foodID = foodID
        self.originDate = originDate
        self.originMealSlot = originMealSlot
        self.service = service
        self.onSuccess = onSuccess
        self.onSessionExpired = onSessionExpired
        self.onSubmissionSuccess = onSubmissionSuccess
        self.onCheckDiary = onCheckDiary
        self.accountID = accountID
        self.displayFoodName = foodName
        self.baseURL = baseURL
        self.submissionStore = submissionStore
        self.timeZoneProvider = timeZoneProvider
        self.idGenerator = idGenerator
        self.singleCapabilityEnsure = singleCapabilityEnsure
        self.durableContextProvider = submissionContextProvider
        self.mealSlot = originMealSlot

        submissionStore.$revision
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshRecoveryEntries()
            }
            .store(in: &cancellables)
    }

    public var isDurableSubmission: Bool {
        durableContextProvider != nil
    }

    public var loadState: FoodDetailLoadState {
        switch resolvedState {
        case .loading: return .loading
        case .loaded: return .loaded
        case .failed(let message): return .failed(message)
        }
    }

    public var food: FoodDetail? {
        if case .loaded(let food) = resolvedState { return food }
        return nil
    }

    public var availableUnits: [FoodUnit] {
        sourceUnits(food: food, units: units)
    }

    public var amountValidationMessage: String? {
        validateLogAmount(amount)?.message
    }

    public var submitErrorMessage: String? {
        if case .failed(let message) = submitState { return message }
        return nil
    }

    public var submitWarningMessage: String? {
        switch submitState {
        case .uncertain(let message), .conflict(let message), .rateLimited(let message):
            return message
        case .idle, .submitting, .failed, .succeeded:
            return nil
        }
    }

    public var isSubmitting: Bool {
        if case .submitting = submitState { return true }
        return false
    }

    public var isRetryingPending: Bool {
        if case .retrying = recoveryState { return true }
        return false
    }

    public var isBusy: Bool { isSubmitting || isRetryingPending }

    public var didSubmitSuccessfully: Bool {
        if case .succeeded = submitState { return true }
        return false
    }

    /// Once this form has logged successfully, its draft is final. The user
    /// starts a fresh detail flow for another logical log.
    public var isFormEditable: Bool {
        !isBusy && !didSubmitSuccessfully
    }

    public var requiresNewSubmissionConfirmation: Bool {
        newSubmissionConfirmation != nil
    }

    public var pendingRecoverySubmission: PendingLogSubmission? {
        visiblePendingSubmissions.first
    }

    public var visiblePendingSubmissions: [PendingLogSubmission] {
        guard !didSubmitSuccessfully else { return [] }
        guard !hidesPendingNotice else { return [] }
        // A live in-flight attempt is current work, not a stale recovery item.
        // An abandoned in-flight row (no live sender) still needs review.
        return pendingSubmissions.filter { pending in
            guard pending.state == .inFlight else { return true }
            guard let submissionStore else { return false }
            return !submissionStore.isLiveSubmission(id: pending.id)
        }
    }

    public var nutritionPreview: [NutrientAmount]? {
        guard case .loaded(let food) = resolvedState else { return nil }
        return makeNutritionPreview(for: food, amount: amount, unit: unit)
    }

    public func load() async {
        lastUsedTask?.cancel()
        lastUsedTask = nil
        resolvedState = .loading
        lastUsedNotice = nil
        quantityWasEdited = false
        formWasEdited = false
        isApplyingDefaultQuantity = false
        hasAttemptedSubmission = false
        boundSubmissionContext = nil
        if durableContextProvider != nil {
            guard let captured = captureSubmissionContext() else {
                resolvedState = .failed(String(localized: "foodDetail.error.sessionExpired"))
                onSessionExpired()
                return
            }
            boundSubmissionContext = captured
        }
        do {
            let loadedFood: FoodDetail
            let loadedUnits: [FoodUnit]
            if let boundSubmissionContext {
                async let foodTask = service.fetchFoodDetail(
                    id: foodID,
                    expectedAccountID: boundSubmissionContext.requestAccountID
                )
                async let unitsTask = service.fetchUnits(
                    expectedAccountID: boundSubmissionContext.requestAccountID
                )
                (loadedFood, loadedUnits) = try await (foodTask, unitsTask)
            } else {
                async let foodTask = service.fetchFoodDetail(id: foodID)
                async let unitsTask = service.fetchUnits()
                (loadedFood, loadedUnits) = try await (foodTask, unitsTask)
            }
            if let boundSubmissionContext,
               !submissionContextIsCurrent(boundSubmissionContext) {
                resolvedState = .failed(String(localized: "foodDetail.error.sessionExpired"))
                onSessionExpired()
                return
            }

            units = loadedUnits
            let defaultLogQuantity = loadedFood.defaultLogQuantity
            isApplyingDefaultQuantity = true
            amount = defaultLogQuantity.amount
            unit = defaultLogQuantity.unit
            if mealSlot == nil {
                mealSlot = originMealSlot
            }
            isApplyingDefaultQuantity = false
            resolvedState = .loaded(loadedFood)
            startLastUsedPrefill(food: loadedFood, units: loadedUnits)
        } catch {
            isApplyingDefaultQuantity = false
            if isUnauthorizedFoodDetailError(error) {
                onSessionExpired()
                resolvedState = .failed(String(localized: "foodDetail.error.sessionExpired"))
            } else {
                resolvedState = .failed(foodDetailErrorMessage(error))
            }
        }
        refreshRecoveryEntries()
    }

    /// Fetched after the food is visible so it never blocks the detail screen.
    /// A user edit, recovery entry, or submission wins over a late response.
    private func startLastUsedPrefill(food: FoodDetail, units: [FoodUnit]) {
        let durableContext: LogSubmissionSessionContext?
        if durableContextProvider != nil {
            guard let boundSubmissionContext,
                  submissionContextIsCurrent(boundSubmissionContext) else {
                onSessionExpired()
                return
            }
            durableContext = boundSubmissionContext
        } else {
            durableContext = nil
        }

        lastUsedTask = Task { [weak self] in
            guard let self else { return }
            if let durableContext,
               !self.submissionContextIsCurrent(durableContext) {
                self.onSessionExpired()
                return
            }
            let lastUsed: RecentLogItem?
            do {
                if let durableContext {
                    lastUsed = try await self.service.lastUsed(
                        for: .product(id: self.foodID),
                        date: self.originDate,
                        mealSlot: self.originMealSlot,
                        expectedAccountID: durableContext.requestAccountID
                    )
                } else {
                    lastUsed = try await self.service.lastUsed(
                        for: .product(id: self.foodID),
                        date: self.originDate,
                        mealSlot: self.originMealSlot
                    )
                }
            } catch {
                if isUnauthorizedFoodDetailError(error) {
                    self.onSessionExpired()
                }
                return
            }
            guard !Task.isCancelled else { return }
            if let durableContext,
               !self.submissionContextIsCurrent(durableContext) {
                self.onSessionExpired()
                return
            }
            guard !self.formWasEdited,
                  !self.hasAttemptedSubmission,
                  self.currentAttempt == nil,
                  self.pendingSubmissions.isEmpty,
                  self.newSubmissionConfirmation == nil else { return }
            self.applyLastUsed(lastUsed, food: food, units: units)
        }
    }

    private func applyLastUsed(
        _ lastUsed: RecentLogItem?,
        food: FoodDetail,
        units: [FoodUnit]
    ) {
        guard !formWasEdited,
              !hasAttemptedSubmission,
              currentAttempt == nil,
              pendingSubmissions.isEmpty,
              newSubmissionConfirmation == nil,
              let quantity = lastUsed?.quantity,
              !quantityWasEdited,
              positiveAmount(quantity.amount) != nil else { return }
        let allowed = sourceUnits(food: food, units: units)
        guard allowed.isEmpty || allowed.contains(where: { $0.code == quantity.unit }) else {
            lastUsedNotice = String(localized: "foodDetail.lastUsed.unavailableUnit")
            return
        }
        isApplyingDefaultQuantity = true
        amount = quantity.amount
        unit = quantity.unit
        isApplyingDefaultQuantity = false
    }

    public func dismissLastUsedNotice() {
        guard lastUsedNotice != nil else { return }
        lastUsedNotice = nil
    }

    public func amountChanged(_ value: String) {
        quantityWasEdited = true
        amount = value
    }

    public func unitChanged(_ value: String) {
        quantityWasEdited = true
        unit = value
    }

    public func mealSlotChanged(_ value: MealSlot?) {
        mealSlot = value
    }

    public func notesChanged(_ value: String) {
        notes = value
    }

    public func refreshRecoveryEntries() {
        var entries = submissionStore?.unresolved(
            accountID: accountID,
            foodID: foodID,
            date: originDate
        ) ?? []
        if let currentAttempt,
           currentAttempt.state == .inFlight
            || currentAttempt.state == .uncertain
            || currentAttempt.state == .conflicted
            || currentAttempt.state == .serverChanged
            || currentAttempt.state == .reconciliationOnly {
            if let submissionStore {
                if submissionStore.isRetryBlocked(id: currentAttempt.id) {
                    self.currentAttempt = nil
                } else if let stored = submissionStore.entry(
                    id: currentAttempt.id,
                    accountID: accountID
                ) {
                    if stored.state == .inFlight
                        || stored.state == .uncertain
                        || stored.state == .conflicted
                        || stored.state == .serverChanged
                        || stored.state == .reconciliationOnly {
                        self.currentAttempt = stored
                        if !entries.contains(where: { $0.id == stored.id }) {
                            entries.insert(stored, at: 0)
                        }
                    } else {
                        self.currentAttempt = nil
                    }
                } else {
                    self.currentAttempt = nil
                }
            } else if !entries.contains(where: { $0.id == currentAttempt.id }) {
                entries.insert(currentAttempt, at: 0)
            }
        }
        let IDs = Set(entries.map(\.id))
        if IDs != lastPendingIDs {
            // “Not now” applies to the entries the user saw, never to a
            // different entry that arrives later.
            hidesPendingNotice = false
            lastPendingIDs = IDs
        }
        if let confirmation = newSubmissionConfirmation,
           !entries.contains(where: { $0.id == confirmation.id }) {
            newSubmissionConfirmation = nil
        }
        pendingSubmissions = entries
    }

    public func submit() async {
        await submit(authorizingNewLogicalSubmission: false)
    }

    /// Called only after the user explicitly confirms, in a separate dialog,
    /// that another logical log should be created despite a matching
    /// unresolved entry. It deliberately does not alter or retry that entry.
    public func confirmCreateNewSubmission() async {
        guard newSubmissionConfirmation != nil else { return }
        newSubmissionConfirmation = nil
        await submit(authorizingNewLogicalSubmission: true)
    }

    private func submit(authorizingNewLogicalSubmission: Bool) async {
        if isBusy || didSubmitSuccessfully { return }
        guard case .loaded = resolvedState else { return }
        if let validationMessage = amountValidationMessage {
            submitState = .failed(validationMessage)
            return
        }
        let durableContext: LogSubmissionSessionContext?
        if durableContextProvider != nil {
            guard let bound = boundSubmissionContext,
                  submissionContextIsCurrent(bound) else {
                submitState = .failed(String(localized: "foodDetail.error.sessionExpired"))
                onSessionExpired()
                return
            }
            durableContext = bound
        } else {
            durableContext = nil
        }

        refreshRecoveryEntries()
        let attemptTimeZone = currentAttempt?.draft.timeZone
        if var attempt = currentAttempt {
            if submissionStore != nil {
                guard let stored = submissionStore?.entry(
                    id: attempt.id,
                    accountID: accountID
                ) else {
                    // The journal row vanished or became unreadable. Sending
                    // the in-memory copy could duplicate an unverifiable log.
                    currentAttempt = nil
                    submitState = .failed(String(localized: "foodDetail.error.saveFailed"))
                    return
                }
                attempt = stored
            }
            if attempt.state == .succeeded {
                deliverStoredSuccess(attempt, recovery: false)
                return
            }
            if attempt.state == .invalidated {
                currentAttempt = nil
                submitState = .failed(blockedDeletionMessage(attempt))
                return
            }
            if attempt.state != .rejected {
                currentAttempt = attempt
                if !authorizingNewLogicalSubmission {
                    blockForUnresolved(attempt)
                    return
                }
            }
            currentAttempt = nil
        }

        let draft = makeDraft(
            timeZone: frozenTimeZone ?? attemptTimeZone ?? timeZoneProvider()
        )
        if !authorizingNewLogicalSubmission,
           let matching = pendingSubmissions.first {
            blockForUnresolved(matching)
            return
        }

        newSubmissionConfirmation = nil
        guard await singleCapabilityEnsure(), !Task.isCancelled else {
            submitState = .failed(String(localized: "foodDetail.error.capabilityUnavailable"))
            return
        }
        if let durableContext, !submissionContextIsCurrent(durableContext) {
            submitState = .failed(String(localized: "foodDetail.error.sessionExpired"))
            onSessionExpired()
            return
        }
        guard !Task.isCancelled, !didSubmitSuccessfully, !isBusy else { return }
        hasAttemptedSubmission = true
        frozenTimeZone = draft.timeZone
        let key = idGenerator()
        do {
            let prepared = try LogCreateRequestBuilder.prepare(
                foodID: foodID,
                foodName: foodNameForDisplay,
                date: originDate,
                mealSlot: draft.mealSlot,
                amount: draft.amount,
                unit: draft.unit,
                notes: draft.notes,
                timeZoneIdentifier: draft.timeZone,
                baseURL: baseURL,
                idempotencyKey: key
            )
            let entry = try reserve(
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body
            )
            currentAttempt = entry
            await send(entry, recovery: false, context: durableContext)
        } catch let error as LogSubmissionStoreError {
            currentAttempt = nil
            submitState = .failed(storeFailureMessage(error))
        } catch let error as LogCreateRequestBuilderError {
            currentAttempt = nil
            submitState = .failed(builderFailureMessage(error))
        } catch {
            currentAttempt = nil
            submitState = .failed(String(localized: "foodDetail.error.saveFailed"))
        }
    }

    public func retryPending(_ entry: PendingLogSubmission? = nil) async {
        guard !isBusy, !didSubmitSuccessfully else { return }
        guard let requested = entry ?? pendingRecoverySubmission,
              requested.accountID == accountID
        else { return }

        let durableContext: LogSubmissionSessionContext?
        if durableContextProvider != nil {
            guard let bound = boundSubmissionContext,
                  submissionContextIsCurrent(bound) else {
                let message = String(localized: "foodDetail.error.sessionExpired")
                recoveryState = .failed(message)
                submitState = .failed(message)
                onSessionExpired()
                return
            }
            durableContext = bound
        } else {
            durableContext = nil
        }

        let attempt: PendingLogSubmission
        if let store = submissionStore {
            do {
                attempt = try store.requireEntry(
                    id: requested.id,
                    accountID: accountID
                )
            } catch {
                // A missing or unreadable journal row must never be replaced
                // by the in-memory copy and sent.
                recoveryState = .failed(String(localized: "foodDetail.error.saveFailed"))
                submitState = .failed(String(localized: "foodDetail.error.saveFailed"))
                return
            }
        } else {
            attempt = requested
        }
        if attempt.state == .succeeded {
            deliverStoredSuccess(attempt, recovery: true)
            return
        }
        if attempt.state == .invalidated
            || submissionStore?.isRetryBlocked(id: attempt.id) == true {
            let message = blockedDeletionMessage(attempt)
            recoveryState = .failed(message)
            submitState = .failed(message)
            refreshRecoveryEntries()
            return
        }
        if attempt.state == .reconciliationOnly {
            let message = attempt.lastMessage
                ?? String(localized: "submission.reconciliationOnly")
            recoveryState = .failed(message)
            submitState = .failed(message)
            return
        }
        if attempt.state == .serverChanged {
            let message = attempt.lastMessage
                ?? String(localized: "foodDetail.error.differentServer")
            recoveryState = .failed(message)
            submitState = .failed(message)
            return
        }
        guard attempt.capabilityVersion == 2 else {
            let message = String(localized: "submission.reconciliationOnly")
            if let store = submissionStore {
                do {
                    try store.markReconciliationOnly(
                        id: attempt.id,
                        accountID: accountID,
                        message: message
                    )
                } catch {
                    recoveryState = .failed(
                        String(localized: "foodDetail.error.journalUnavailable")
                    )
                    submitState = .failed(
                        String(localized: "foodDetail.error.journalUnavailable")
                    )
                    return
                }
            }
            recoveryState = .failed(message)
            submitState = .failed(message)
            refreshRecoveryEntries()
            return
        }
        if attempt.state == .conflicted || attempt.body == nil {
            recoveryState = .conflicted(
                attempt.lastMessage ?? String(localized: "foodDetail.error.conflict")
            )
            submitState = .conflict(
                attempt.lastMessage ?? String(localized: "foodDetail.error.conflict")
            )
            return
        }
        if attempt.state == .inFlight {
            if let store = submissionStore, store.isLiveSubmission(id: attempt.id) {
                recoveryState = .failed(String(localized: "foodDetail.error.saveFailed"))
                return
            }
            // An abandoned in-flight row is safe to replay with its original
            // key; a genuine live sender is refused above.
        }
        guard attempt.state != .rejected else {
            recoveryState = .failed(String(localized: "foodDetail.error.saveFailed"))
            return
        }
        guard await singleCapabilityEnsure(), !Task.isCancelled else {
            let message = String(localized: "foodDetail.error.capabilityUnavailable")
            recoveryState = .failed(message)
            submitState = .failed(message)
            return
        }
        if let durableContext, !submissionContextIsCurrent(durableContext) {
            let message = String(localized: "foodDetail.error.sessionExpired")
            recoveryState = .failed(message)
            submitState = .failed(message)
            onSessionExpired()
            return
        }
        guard !Task.isCancelled, !didSubmitSuccessfully else { return }

        // Retrying the earlier row is a separate explicit action from creating
        // a new logical submission.
        newSubmissionConfirmation = nil
        recoveryState = .retrying(attempt.id)
        await send(attempt, recovery: true, context: durableContext)
    }

    /// Removes a definitively conflicted journal row. The view asks for an
    /// explicit confirmation before calling this; normal submission cannot.
    public func discardPending(_ entry: PendingLogSubmission) {
        guard entry.accountID == accountID,
              entry.state == .conflicted
                || entry.state == .serverChanged
                || entry.state == .reconciliationOnly else { return }
        do {
            if let submissionStore {
                try submissionStore.remove(id: entry.id, accountID: accountID)
            }
        } catch {
            recoveryState = .failed(String(localized: "foodDetail.error.saveFailed"))
            return
        }
        if currentAttempt?.id == entry.id {
            currentAttempt = nil
        }
        if newSubmissionConfirmation?.id == entry.id {
            newSubmissionConfirmation = nil
        }
        pendingSubmissions.removeAll { $0.id == entry.id }
        if case .conflict = submitState {
            submitState = .idle
        }
        refreshRecoveryEntries()
    }

    public func checkDiary() {
        let date = pendingRecoverySubmission?.draft.date ?? originDate
        onCheckDiary?(date)
    }

    public func dismissPendingNotice() {
        // “Not now” only hides the recovery UI. It is not consent to create a
        // second logical submission while a matching entry remains unresolved.
        hidesPendingNotice = true
    }

    private var foodNameForDisplay: String {
        food?.name ?? displayFoodName ?? foodID
    }

    private func formDidChange() {
        guard !didSubmitSuccessfully else { return }
        guard !isApplyingDefaultQuantity else { return }
        formWasEdited = true
        currentAttempt = nil
        frozenTimeZone = nil
        newSubmissionConfirmation = nil
        switch submitState {
        case .failed, .uncertain, .conflict, .rateLimited:
            submitState = .idle
        case .idle, .submitting, .succeeded:
            break
        }
    }

    private func blockForUnresolved(_ entry: PendingLogSubmission) {
        newSubmissionConfirmation = entry
        // The user needs the recovery row visible again, even if they chose
        // “Not now” earlier.
        hidesPendingNotice = false
        switch entry.state {
        case .conflicted:
            submitState = .conflict(
                entry.lastMessage ?? String(localized: "foodDetail.error.conflict")
            )
        case .inFlight, .uncertain:
            submitState = .uncertain(
                entry.lastMessage ?? String(localized: "foodDetail.error.uncertain")
            )
        case .serverChanged:
            submitState = .failed(
                entry.lastMessage ?? String(localized: "foodDetail.error.differentServer")
            )
        case .reconciliationOnly:
            submitState = .failed(
                entry.lastMessage ?? String(localized: "submission.reconciliationOnly")
            )
        case .invalidated:
            submitState = .failed(blockedDeletionMessage(entry))
        case .succeeded, .rejected:
            break
        }
    }

    private func makeDraft(timeZone: String) -> LogSubmissionDraft {
        LogCreateRequestBuilder.makeDraft(
            foodID: foodID,
            date: originDate,
            mealSlot: mealSlot,
            amount: amount,
            unit: unit,
            notes: notes,
            timeZoneIdentifier: timeZone
        )
    }

    private func reserve(
        draft: LogSubmissionDraft,
        request: FoodLogCreateRequest,
        body: Data
    ) throws -> PendingLogSubmission {
        if let submissionStore {
            return try submissionStore.reserve(
                accountID: accountID,
                foodName: foodNameForDisplay,
                draft: draft,
                request: request,
                body: body,
                capabilityVersion: 2
            )
        }
        let timestamp = Date()
        return PendingLogSubmission(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            foodName: foodNameForDisplay,
            draft: draft,
            capabilityVersion: 2,
            idempotencyKey: request.idempotencyKey ?? "",
            body: body,
            baseURLString: request.baseURLString ?? "",
            state: .inFlight,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func send(
        _ entry: PendingLogSubmission,
        recovery: Bool,
        context: LogSubmissionSessionContext?
    ) async {
        var attempt = entry
        do {
            if let submissionStore {
                let claimed = try submissionStore.claimSubmission(
                    id: entry.id,
                    accountID: accountID
                )
                guard claimed else {
                    let current = submissionStore.entry(
                        id: entry.id,
                        accountID: accountID
                    )
                    if let current, current.state == .succeeded {
                        deliverStoredSuccess(current, recovery: recovery)
                        return
                    }
                    let message: String
                    if let current, current.state == .invalidated {
                        message = blockedDeletionMessage(current)
                    } else {
                        message = String(localized: "submission.pendingExists")
                    }
                    currentAttempt = nil
                    submitState = .failed(message)
                    if recovery { recoveryState = .failed(message) }
                    refreshRecoveryEntries()
                    return
                }
                // Never send an in-memory fallback if the durable row vanished.
                attempt = try submissionStore.requireEntry(
                    id: entry.id,
                    accountID: accountID
                )
            } else {
                attempt.state = .inFlight
                attempt.attemptCount += 1
                attempt.updatedAt = Date()
            }
        } catch {
            if recovery {
                recoveryState = .failed(String(localized: "foodDetail.error.saveFailed"))
            } else {
                submitState = .failed(String(localized: "foodDetail.error.saveFailed"))
            }
            refreshRecoveryEntries()
            return
        }

        if attempt.state == .invalidated
            || submissionStore?.isRetryBlocked(id: attempt.id) == true {
            let message = blockedDeletionMessage(attempt)
            currentAttempt = nil
            submitState = .failed(message)
            if recovery { recoveryState = .failed(message) }
            refreshRecoveryEntries()
            return
        }

        if !recovery {
            submitState = .submitting
            currentAttempt = attempt
        }
        guard let request = attempt.request else {
            let message = String(localized: "foodDetail.error.saveFailed")
            guard markUncertain(
                attempt,
                status: nil,
                message: message
            ) else { return }
            if recovery {
                recoveryState = .failed(message)
            } else {
                submitState = .failed(message)
            }
            refreshRecoveryEntries()
            return
        }

        if let context, !submissionContextIsCurrent(context) {
            retainUncertainForStaleContext(attempt, recovery: recovery)
            return
        }

        do {
            let created: CreatedFoodLog
            if let context {
                created = try await service.createLog(
                    request,
                    expectedAccountID: context.requestAccountID
                )
            } else {
                created = try await service.createLog(request)
            }
            if let context, !submissionContextIsCurrent(context) {
                retainUncertainForStaleContext(attempt, recovery: recovery)
                return
            }
            if let submissionStore,
               submissionStore.isRetryBlocked(id: attempt.id)
                || submissionStore.entry(id: attempt.id, accountID: accountID)?
                    .state == .invalidated {
                let message = blockedDeletionMessage(attempt)
                currentAttempt = nil
                submitState = .failed(message)
                if recovery { recoveryState = .failed(message) }
                refreshRecoveryEntries()
                return
            }
            let success = FoodLogSubmissionSuccess(
                submissionID: attempt.id,
                accountID: attempt.accountID,
                foodID: attempt.draft.foodID,
                foodName: attempt.foodName,
                date: attempt.draft.date,
                mealSlot: created.mealSlot ?? attempt.draft.mealSlot,
                logID: created.id,
                replayed: created.replayed
            )
            if let submissionStore {
                do {
                    try submissionStore.markSucceeded(
                        id: attempt.id,
                        accountID: accountID,
                        logID: created.id,
                        date: success.date,
                        mealSlot: success.mealSlot,
                        replayed: created.replayed
                    )
                } catch {
                    let message = String(localized: "foodDetail.error.journalUnavailable")
                    currentAttempt = attempt
                    submitState = .failed(message)
                    if recovery {
                        recoveryState = .failed(message)
                    }
                    refreshRecoveryEntries()
                    return
                }
            } else {
                currentAttempt = nil
            }
            currentAttempt = nil
            newSubmissionConfirmation = nil
            lastSubmissionSuccess = success
            submitState = .succeeded
            if recovery {
                recoveryState = .succeeded(attempt.id)
            }
            refreshRecoveryEntries()
            onSuccess(success.date, success.mealSlot)
            onSubmissionSuccess?(success)
        } catch {
            handleFailure(error, entry: attempt, recovery: recovery)
        }
    }

    private func handleFailure(
        _ error: Error,
        entry: PendingLogSubmission,
        recovery: Bool
    ) {
        let serviceError = error as? FoodDetailServiceError
        switch serviceError {
        case .unauthorized:
            guard markUncertain(
                entry,
                status: 401,
                message: String(localized: "foodDetail.error.sessionExpired")
            ) else { return }
            submitState = .failed(String(localized: "foodDetail.error.sessionExpired"))
            if recovery {
                recoveryState = .failed(String(localized: "foodDetail.error.sessionExpired"))
            }
            onSessionExpired()
        case .uncertain(let message):
            guard markUncertain(entry, status: nil, message: message) else { return }
            submitState = .uncertain(message)
            if recovery { recoveryState = .failed(message) }
        case .conflict(let message):
            guard markConflicted(entry, message: message) else { return }
            submitState = .conflict(message)
            if recovery { recoveryState = .conflicted(message) }
        case .rateLimited(let retryAfter):
            let message = String(localized: "foodDetail.error.rateLimited")
            guard markUncertain(
                entry,
                status: 429,
                message: message,
                retryAfter: retryAfter
            ) else { return }
            submitState = .rateLimited(message)
            if recovery { recoveryState = .failed(message) }
        case .failed(let message):
            if !entry.baseURLString.isEmpty,
               let baseURL,
               entry.baseURLString != baseURL.absoluteString {
                guard markUncertain(entry, status: nil, message: message) else { return }
                submitState = .uncertain(message)
                if recovery { recoveryState = .failed(message) }
                break
            }
            guard markRejected(entry, message: message) else { return }
            submitState = .failed(message)
            if recovery { recoveryState = .failed(message) }
            if submissionStore != nil {
                // Adapter-classified definitive rejections are not ambiguous and
                // must not be replayed unchanged. A new submit is a new attempt.
                currentAttempt = nil
            }
        case nil:
            let message = error.localizedDescription
            guard markUncertain(entry, status: nil, message: message) else { return }
            submitState = .uncertain(message)
            if recovery { recoveryState = .failed(message) }
        }
        refreshRecoveryEntries()
    }

    private func deliverStoredSuccess(
        _ entry: PendingLogSubmission,
        recovery: Bool
    ) {
        guard let date = entry.resultDate else { return }
        let success = FoodLogSubmissionSuccess(
            submissionID: entry.id,
            accountID: entry.accountID,
            foodID: entry.draft.foodID,
            foodName: entry.foodName,
            date: date,
            mealSlot: entry.resultMealSlot ?? entry.draft.mealSlot,
            logID: entry.resultLogID,
            replayed: entry.replayed
        )
        currentAttempt = nil
        newSubmissionConfirmation = nil
        lastSubmissionSuccess = success
        submitState = .succeeded
        if recovery { recoveryState = .succeeded(entry.id) }
        refreshRecoveryEntries()
        onSuccess(success.date, success.mealSlot)
        onSubmissionSuccess?(success)
    }

    private func markUncertain(
        _ entry: PendingLogSubmission,
        status: Int?,
        message: String,
        retryAfter: Int? = nil
    ) -> Bool {
        if let submissionStore {
            do {
                try submissionStore.markUncertain(
                    id: entry.id,
                    accountID: accountID,
                    status: status,
                    message: message,
                    retryAfterSeconds: retryAfter
                )
                if let updated = submissionStore.entry(id: entry.id, accountID: accountID) {
                    currentAttempt = updated
                    return true
                }
                journalStateFailure()
                return false
            } catch {
                journalStateFailure()
                return false
            }
        }
        var updated = entry
        updated.state = .uncertain
        updated.lastStatus = status
        updated.lastMessage = message
        updated.retryAfterSeconds = retryAfter
        updated.updatedAt = Date()
        currentAttempt = updated
        return true
    }

    private func markRejected(_ entry: PendingLogSubmission, message: String) -> Bool {
        if let submissionStore {
            do {
                try submissionStore.markRejected(
                    id: entry.id,
                    accountID: accountID,
                    status: 400,
                    message: message
                )
                if let updated = submissionStore.entry(id: entry.id, accountID: accountID) {
                    currentAttempt = updated
                    return true
                }
                journalStateFailure()
                return false
            } catch {
                journalStateFailure()
                return false
            }
        }
        var updated = entry
        updated.state = .rejected
        updated.lastMessage = message
        updated.updatedAt = Date()
        currentAttempt = updated
        return true
    }

    private func markConflicted(_ entry: PendingLogSubmission, message: String) -> Bool {
        if let submissionStore {
            do {
                try submissionStore.markConflicted(
                    id: entry.id,
                    accountID: accountID,
                    message: message
                )
                if let updated = submissionStore.entry(id: entry.id, accountID: accountID) {
                    currentAttempt = updated
                    return true
                }
                journalStateFailure()
                return false
            } catch {
                journalStateFailure()
                return false
            }
        }
        var updated = entry
        updated.state = .conflicted
        updated.body = nil
        updated.lastMessage = message
        updated.updatedAt = Date()
        currentAttempt = updated
        return true
    }

    private func journalStateFailure() {
        let message = String(localized: "foodDetail.error.journalUnavailable")
        submitState = .failed(message)
        recoveryState = .failed(message)
        refreshRecoveryEntries()
    }

    private func blockedDeletionMessage(_ entry: PendingLogSubmission) -> String {
        if entry.state == .invalidated,
           let stored = entry.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return String(localized: "foodDetail.pending.invalidated")
    }

    private func captureSubmissionContext() -> LogSubmissionSessionContext? {
        guard let durableContextProvider,
              let context = durableContextProvider(),
              context.accountID == accountID else {
            return nil
        }
        if let baseURL, context.baseURL != baseURL { return nil }
        return context
    }

    private func submissionContextIsCurrent(
        _ context: LogSubmissionSessionContext
    ) -> Bool {
        guard let durableContextProvider,
              let current = durableContextProvider(),
              current == context,
              current.accountID == accountID else {
            return false
        }
        if let baseURL, current.baseURL != baseURL { return false }
        return true
    }

    private func retainUncertainForStaleContext(
        _ entry: PendingLogSubmission,
        recovery: Bool
    ) {
        if let submissionStore,
           submissionStore.isRetryBlocked(id: entry.id)
            || submissionStore.entry(id: entry.id, accountID: accountID)?
                .state == .invalidated {
            let message = blockedDeletionMessage(entry)
            currentAttempt = nil
            submitState = .failed(message)
            if recovery { recoveryState = .failed(message) }
            refreshRecoveryEntries()
            return
        }
        let message = String(localized: "foodDetail.error.sessionExpired")
        let marked = markUncertain(entry, status: nil, message: message)
        if !marked {
            submissionStore?.abandonLiveSubmission(id: entry.id)
        }
        if let updated = submissionStore?.entry(
            id: entry.id,
            accountID: accountID
        ) {
            currentAttempt = updated
        } else {
            currentAttempt = entry
        }
        submitState = .uncertain(message)
        if recovery { recoveryState = .failed(message) }
        onSessionExpired()
        refreshRecoveryEntries()
    }

    private func storeFailureMessage(_ error: LogSubmissionStoreError) -> String {
        switch error {
        case .unreadableJournal:
            return String(localized: "foodDetail.error.journalUnavailable")
        case .missingEntry, .submissionInFlight:
            return String(localized: "foodDetail.error.saveFailed")
        case .invalidAccount, .invalidRequest, .bodyTooLarge, .tooManyEntries, .persistence,
             .idempotencyConflict, .preparedIntentUnavailable, .preparedIntentCancelled,
             .preparedIntentPending:
            return String(localized: "foodDetail.error.saveFailed")
        }
    }

    private func builderFailureMessage(_ error: LogCreateRequestBuilderError) -> String {
        switch error {
        case .bodyTooLarge:
            return String(localized: "foodDetail.error.notesTooLong")
        case .invalidKey, .invalidItem, .encoding:
            return String(localized: "foodDetail.error.saveFailed")
        }
    }
}
