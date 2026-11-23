// Per-day nutrition-details state. The report always belongs to `selectedDate`;
// late responses, cancellations, and wrong-day payloads never replace a newer
// selection. A 401 expires the session and stops further fetches until the app
// creates a new session-scoped instance.

import Combine
import Foundation

@MainActor
public final class NutritionDetailsViewModel: ObservableObject, Identifiable {
    public let id = UUID()

    @Published public private(set) var selectedDate: LocalDiaryDate
    @Published public private(set) var today: LocalDiaryDate
    @Published public private(set) var state: NutritionDetailsLoadState = .loading
    @Published public private(set) var expandedNutrientCodes: Set<String> = []

    public var onSessionExpired: (() -> Void)?

    private let service: any NutritionDetailsServicing
    private var requestToken = 0
    private var hasRequestedInitialLoad = false
    private var sessionExpiryDelivered = false

    public init(
        date: LocalDiaryDate,
        today: LocalDiaryDate,
        service: any NutritionDetailsServicing,
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.today = today
        self.selectedDate = min(date, today)
        self.service = service
        self.onSessionExpired = onSessionExpired
    }

    public var report: NutritionDetailsReport? {
        if case .loaded(let report) = state { return report }
        return nil
    }

    public var isLoading: Bool {
        state == .loading
    }

    public var isSessionExpired: Bool {
        state == .sessionExpired
    }

    public var errorMessage: String? {
        switch state {
        case .failed(let message):
            return message
        case .sessionExpired:
            return String(localized: "nutrition.error.sessionExpired")
        case .loading, .loaded:
            return nil
        }
    }

    public var canGoNext: Bool {
        selectedDate < today && !isSessionExpired
    }

    /// The view calls this once when it appears. A cancelled initial request is
    /// retryable on the next appearance; an explicit failure stays settled
    /// until the user taps Retry.
    public func loadIfNeeded() async {
        guard !hasRequestedInitialLoad, !isSessionExpired else { return }
        hasRequestedInitialLoad = true
        await load(for: selectedDate)
    }

    public func load() async {
        hasRequestedInitialLoad = true
        await load(for: selectedDate)
    }

    public func refresh() async {
        await load()
    }

    public func retry() async {
        await load()
    }

    public func previousDay() async {
        guard !isSessionExpired else { return }
        await selectDate(selectedDate.addingDays(-1))
    }

    public func nextDay() async {
        guard canGoNext else { return }
        await selectDate(selectedDate.addingDays(1))
    }

    public func selectDate(_ date: LocalDiaryDate) async {
        guard !isSessionExpired else { return }
        let clamped = min(date, today)
        guard clamped != selectedDate else {
            switch state {
            case .loading, .loaded:
                return
            case .failed, .sessionExpired:
                await load(for: clamped)
                return
            }
        }

        selectedDate = clamped
        expandedNutrientCodes = []
        await load(for: clamped)
    }

    public func isGuidanceExpanded(for code: String) -> Bool {
        expandedNutrientCodes.contains(code)
    }

    public func setGuidanceExpanded(_ expanded: Bool, for code: String) {
        guard report?.nutrients.contains(where: { $0.code == code }) == true else {
            return
        }
        if expanded {
            expandedNutrientCodes.insert(code)
        } else {
            expandedNutrientCodes.remove(code)
        }
    }

    public func toggleGuidance(for code: String) {
        setGuidanceExpanded(!isGuidanceExpanded(for: code), for: code)
    }

    /// Called by the app shell when session-scoped feature state is discarded.
    /// It invalidates any request that is still in flight and clears content.
    public func resetForSessionChange() {
        requestToken += 1
        hasRequestedInitialLoad = false
        sessionExpiryDelivered = false
        expandedNutrientCodes = []
        state = .loading
    }

    private func load(for date: LocalDiaryDate) async {
        guard !isSessionExpired else { return }
        guard date == selectedDate else { return }

        let token = nextToken()
        state = .loading

        do {
            let report = try await service.fetchNutritionDetails(for: date)
            guard token == requestToken,
                  date == selectedDate,
                  !isSessionExpired else {
                return
            }
            if Task.isCancelled {
                hasRequestedInitialLoad = false
                return
            }
            guard report.date == date else {
                state = .failed(NutritionDetailsCopy.invalidResponse)
                return
            }
            expandedNutrientCodes = []
            state = .loaded(report)
        } catch {
            guard token == requestToken, date == selectedDate else { return }

            if Task.isCancelled || isCancelledNutritionDetailsError(error) {
                // A cancelled request is not a user-visible failure. Leave the
                // spinner and allow the next appearance to request again.
                hasRequestedInitialLoad = false
                return
            }

            if isUnauthorizedNutritionDetailsError(error) {
                expireSession()
                return
            }

            state = .failed(nutritionDetailsErrorMessage(error))
        }
    }

    private func expireSession() {
        requestToken += 1
        expandedNutrientCodes = []
        state = .sessionExpired
        guard !sessionExpiryDelivered else { return }
        sessionExpiryDelivered = true
        onSessionExpired?()
    }

    private func nextToken() -> Int {
        requestToken += 1
        return requestToken
    }
}
