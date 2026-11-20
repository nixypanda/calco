import Foundation

/// State for a single log-editing session. Every failure path is explicit:
/// transport/server failures surface a retryable message, cancellation returns
/// to editing, and a 401 marks the session expired and notifies the coordinator.
@MainActor
public final class LogEditorViewModel: ObservableObject {
    public enum EditorState: Equatable, Sendable {
        case editing
        case saving
        case deleting
        case saved
        case deleted
        case failed(String)
        case sessionExpired

        var isBusy: Bool {
            switch self {
            case .saving, .deleting: return true
            default: return false
            }
        }
    }

    public let logID: String
    public let date: LocalDiaryDate
    public let title: String
    public let subtitle: String?
    /// Product identity retained for source compatibility with existing editor
    /// tests. Typed identity below also covers meals and ad-hoc logs.
    public let productID: String?
    /// Conservative identity used to invalidate journal attempts if this log is
    /// deleted. Nil only for legacy rows that carry no item reference.
    public let submissionItem: LogSubmissionItem?
    /// Captured when the editor is created so a delete that outlives a session
    /// change still blocks the journal for the account that owned the log.
    public let accountID: String

    @Published public var amount: String
    @Published public var unit: String
    @Published public var mealSlot: MealSlot?
    @Published public var notes: String
    @Published public private(set) var units: [FoodUnit]
    @Published public private(set) var state: EditorState = .editing
    @Published public var isDeleteConfirmationPresented = false
    /// Last authoritative PUT response. The coordinator applies it to the
    /// diary immediately so a failed or stale refetch cannot hide the save.
    @Published public private(set) var lastSavedLog: DiaryLog?
    /// Number of journal attempts durably blocked by this editor's delete
    /// attempts. It accumulates across retries so a later successful DELETE
    /// still explains why retry is not offered for those attempts.
    @Published public private(set) var blockedPendingCount = 0

    private let service: any DiaryServicing
    private let matchingPendingCount: () -> Int
    private let submissionStore: LogSubmissionStore?
    private let initialAmount: String
    private let initialUnit: String
    private let initialMealSlot: MealSlot?
    private let initialNotes: String

    public var onSaved: ((LocalDiaryDate) -> Void)?
    public var onDeleted: ((LocalDiaryDate) -> Void)?
    public var onSessionExpired: (() -> Void)?

    private var successDelivered = false
    private var sessionExpiryDelivered = false

    public init(
        log: DiaryLog,
        date: LocalDiaryDate,
        service: any DiaryServicing,
        units: [FoodUnit] = [],
        accountID: String = "",
        submissionStore: LogSubmissionStore? = nil,
        matchingPendingCount: @escaping () -> Int = { 0 }
    ) {
        self.logID = log.id
        self.date = date
        let initialAmount = log.quantity?.amount ?? "100"
        let initialUnit = log.quantity?.unit ?? "g"
        self.title = log.title
        self.subtitle = log.brand
        self.productID = log.productID
        self.submissionItem = log.submissionItem
        self.accountID = accountID
        self.service = service
        self.submissionStore = submissionStore
        self.matchingPendingCount = matchingPendingCount
        self.amount = initialAmount
        self.unit = initialUnit
        self.mealSlot = log.mealSlot
        self.notes = log.notes ?? ""
        self.initialAmount = initialAmount
        self.initialUnit = initialUnit
        self.initialMealSlot = log.mealSlot
        self.initialNotes = log.notes ?? ""
        self.units = Self.fallbackUnits(including: initialUnit, supplied: units)
    }

    /// Dirty means the form differs from the values it was opened with. Saving
    /// and deleting states remain dirty until the coordinator leaves the
    /// editor, so a back/row-switch cannot silently discard an in-flight edit.
    public var hasUnsavedChanges: Bool {
        amount != initialAmount
            || unit != initialUnit
            || mealSlot != initialMealSlot
            || notes != initialNotes
    }

    /// Terminal editors are safe to replace on a later diary tap. Editing,
    /// saving, deleting and failed editors must be preserved.
    public var isTerminal: Bool {
        switch state {
        case .saved, .deleted: return true
        case .editing, .saving, .deleting, .failed, .sessionExpired: return false
        }
    }

    public var validationMessage: String? {
        validateLogAmount(amount)?.message
    }

    /// When an unresolved attempt matches this product/date, deleting the found
    /// log must warn that retrying it is about to be disabled rather than only
    /// showing the normal "cannot be undone" copy.
    public var deleteConfirmationMessage: String {
        if matchingPendingCount() > 0 {
            return String(localized: "diary.editor.delete.confirmWithPending")
        }
        return String(localized: "diary.editor.delete.confirm")
    }

    public var errorMessage: String? {
        switch state {
        case .failed(let message): return message
        case .sessionExpired: return String(localized: "diary.error.sessionExpired")
        default: return nil
        }
    }

    public var canEdit: Bool {
        switch state {
        case .editing, .failed: return true
        default: return false
        }
    }

    public var isBusy: Bool {
        state.isBusy
    }

    public var busyMessage: String {
        switch state {
        case .saving: return String(localized: "diary.editor.saving")
        case .deleting: return String(localized: "diary.editor.deleting")
        default: return ""
        }
    }

    /// Units are a convenience, not a correctness requirement. A failure here
    /// must never block editing the log's own unit.
    public func loadUnits() async {
        do {
            let fetched = try await service.fetchUnits()
            if !fetched.isEmpty {
                units = Self.fallbackUnits(including: unit, supplied: fetched)
            }
        } catch {
            // Keep the local fallback list.
        }
    }

    public func retry() {
        guard case .failed = state else { return }
        state = .editing
    }

    public func save() async {
        guard canEdit, validationMessage == nil else { return }
        state = .saving

        // Match the create flow: trim and treat whitespace-only notes as cleared.
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = UpdateLogRequest(
            mealSlot: mealSlot.map { OptionalField<MealSlot>.value($0) } ?? .null,
            quantity: NutritionQuantity(amount: amount, unit: unit),
            notes: trimmedNotes.isEmpty ? .null : .value(trimmedNotes)
        )

        do {
            let updated = try await service.updateLog(id: logID, request: request)
            lastSavedLog = updated
            state = .saved
            deliverSuccess { onSaved?(date) }
        } catch {
            handle(error)
        }
    }

    public func requestDelete() {
        guard canEdit else { return }
        isDeleteConfirmationPresented = true
    }

    public func cancelDelete() {
        isDeleteConfirmationPresented = false
    }

    public func delete() async {
        guard canEdit else { return }
        isDeleteConfirmationPresented = false
        state = .deleting

        // Fail closed before the backend DELETE. The journal barrier must be
        // durable first; otherwise a late POST replay could recreate the log.
        // Only after the user confirms (or calls delete directly) is it safe
        // to invalidate matching attempts.
        if let submissionItem, let submissionStore {
            do {
                let invalidated = try submissionStore.blockBeforeDeleting(
                    accountID: accountID,
                    item: submissionItem,
                    date: date,
                    reason: String(localized: "foodDetail.pending.invalidated")
                )
                blockedPendingCount += invalidated.count
            } catch {
                state = .failed(deleteSafetyMessage(for: error))
                return
            }
        }

        do {
            try await service.deleteLog(id: logID)
            state = .deleted
            deliverSuccess { onDeleted?(date) }
        } catch {
            handleDeleteFailure(error)
        }
    }

    private func handleDeleteFailure(_ error: Error) {
        if isUnauthorizedDiaryError(error) {
            state = .sessionExpired
            if !sessionExpiryDelivered {
                sessionExpiryDelivered = true
                onSessionExpired?()
            }
            return
        }

        if isCancelledDiaryError(error) || error is CancellationError {
            state = .failed(
                blockedPendingCount > 0
                    ? String(localized: "diary.editor.delete.cancelledWithBarrier")
                    : String(localized: "diary.editor.delete.cancelled")
            )
            return
        }

        let message = diaryErrorMessage(error)
        if blockedPendingCount > 0 {
            state = .failed(String(
                format: String(localized: "diary.editor.delete.failedWithBarrier"),
                message
            ))
        } else {
            state = .failed(message)
        }
    }

    private func deleteSafetyMessage(for error: Error) -> String {
        guard let storeError = error as? LogSubmissionStoreError else {
            return String(localized: "diary.editor.delete.blockedFallback")
        }
        switch storeError {
        case .unreadableJournal:
            return String(localized: "diary.editor.delete.journalUnavailable")
        case .persistence:
            return String(localized: "diary.editor.delete.persistenceFailed")
        case .submissionInFlight:
            return String(localized: "diary.editor.delete.liveSubmission")
        case .invalidAccount:
            return String(localized: "diary.editor.delete.accountUnavailable")
        case .missingEntry, .invalidRequest, .bodyTooLarge, .tooManyEntries,
             .idempotencyConflict, .preparedIntentUnavailable,
             .preparedIntentCancelled, .preparedIntentPending:
            return String(localized: "diary.editor.delete.blockedFallback")
        }
    }

    private func handle(_ error: Error) {
        if isUnauthorizedDiaryError(error) {
            state = .sessionExpired
            if !sessionExpiryDelivered {
                sessionExpiryDelivered = true
                onSessionExpired?()
            }
        } else if isCancelledDiaryError(error) || error is CancellationError {
            state = .editing
        } else {
            state = .failed(diaryErrorMessage(error))
        }
    }

    private func deliverSuccess(_ callback: () -> Void) {
        guard !successDelivered else { return }
        successDelivered = true
        callback()
    }

    private static func fallbackUnits(including current: String, supplied: [FoodUnit]) -> [FoodUnit] {
        let defaults = [
            FoodUnit(code: "g", name: "Gram", kind: "mass"),
            FoodUnit(code: "kg", name: "Kilogram", kind: "mass"),
            FoodUnit(code: "oz", name: "Ounce", kind: "mass"),
            FoodUnit(code: "ml", name: "Millilitre", kind: "volume"),
            FoodUnit(code: "l", name: "Litre", kind: "volume"),
            FoodUnit(code: "serving", name: "Serving", kind: "serving"),
        ]
        var seen = Set<String>()
        var result: [FoodUnit] = []
        func append(_ unit: FoodUnit) {
            guard !unit.code.isEmpty, seen.insert(unit.code).inserted else { return }
            result.append(unit)
        }
        for unit in defaults { append(unit) }
        for unit in supplied { append(unit) }
        append(FoodUnit(code: current, name: current, kind: "unit"))
        return result
    }
}
