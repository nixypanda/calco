// Durable, account-scoped store for uncertain custom-food creates and the
// explicit reconciliation workflow that replaces blind retries.

import Foundation

public enum CustomFoodReconciliationStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case invalidAttempt
    /// Another window replaced or cleared the attempt this caller still holds.
    case staleAttempt
    /// The retained log intent belongs to another server origin.
    case serverChanged
    case unreadable(String)
    case persistence(String)
}

public protocol CustomFoodReconciliationPersisting: Sendable {
    func load(accountID: String) throws -> Data?
    func save(_ data: Data, accountID: String) throws
    func remove(accountID: String) throws
    func quarantine(accountID: String, reason: String)
}

public struct FileCustomFoodReconciliationPersistence: CustomFoodReconciliationPersisting {
    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directoryURL = support
                .appendingPathComponent("CalCo", isDirectory: true)
                .appendingPathComponent("CustomFoodReconciliation", isDirectory: true)
        }
    }

    public func load(accountID: String) throws -> Data? {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data, accountID: String) throws {
        try createDirectoryIfNeeded()
        let url = fileURL(accountID: accountID)
        try data.write(to: url, options: [.atomic])
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    public func remove(accountID: String) throws {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func quarantine(accountID: String, reason: String) {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let suffix = UUID().uuidString.lowercased()
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(suffix)")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directoryURL
        try? directory.setResourceValues(values)
    }

    private func fileURL(accountID: String) -> URL {
        let encoded = Data(accountID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return directoryURL
            .appendingPathComponent("custom-food-\(encoded).json")
    }
}

@MainActor
public final class CustomFoodReconciliationStore {
    public static let maxBytes = 128 * 1024
    public static let shared = CustomFoodReconciliationStore()

    private let persistence: any CustomFoodReconciliationPersisting
    private var cache: [String: CustomFoodCreateAttempt] = [:]
    private var unreadableAccounts: [String: CustomFoodReconciliationStoreError] = [:]

    public init(
        persistence: any CustomFoodReconciliationPersisting =
            FileCustomFoodReconciliationPersistence()
    ) {
        self.persistence = persistence
    }

    public func attempt(accountID: String) throws -> CustomFoodCreateAttempt? {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomFoodReconciliationStoreError.invalidAccount
        }
        if let error = unreadableAccounts[accountID] {
            throw error
        }
        if let cached = cache[accountID] {
            return cached
        }
        do {
            guard let data = try persistence.load(accountID: accountID) else {
                return nil
            }
            let attempt = try JSONDecoder().decode(CustomFoodCreateAttempt.self, from: data)
            guard attempt.accountID == accountID else {
                throw CustomFoodReconciliationStoreError.invalidAttempt
            }
            cache[accountID] = attempt
            return attempt
        } catch let error as CustomFoodReconciliationStoreError {
            // Leave the file in place. A new store or process must remain
            // blocked by the same unreadable record until an explicit reset.
            unreadableAccounts[accountID] = error
            throw error
        } catch {
            let storeError = CustomFoodReconciliationStoreError.unreadable(
                error.localizedDescription
            )
            // Do not move the corrupt file during automatic detection: moving
            // it would make a relaunch observe "no attempt" and allow a
            // duplicate non-idempotent create.
            unreadableAccounts[accountID] = storeError
            throw storeError
        }
    }

    /// Atomically reserves the account's only create attempt. The loser gets
    /// the already-reserved attempt instead of overwriting it.
    public func reserve(_ candidate: CustomFoodCreateAttempt) throws -> CustomFoodCreateAttempt {
        if let existing = try attempt(accountID: candidate.accountID) {
            return existing
        }
        try save(candidate)
        return candidate
    }

    public func saveIfCurrent(
        _ candidate: CustomFoodCreateAttempt,
        accountID: String,
        expectedAttemptID: String
    ) throws -> CustomFoodCreateAttempt {
        guard candidate.accountID == accountID, candidate.id == expectedAttemptID else {
            throw CustomFoodReconciliationStoreError.invalidAttempt
        }
        if let error = unreadableAccounts[accountID] {
            throw error
        }
        guard let current = try attempt(accountID: accountID) else {
            throw CustomFoodReconciliationStoreError.staleAttempt
        }
        guard current.id == expectedAttemptID else {
            throw CustomFoodReconciliationStoreError.staleAttempt
        }
        try save(candidate)
        return candidate
    }

    /// Compare-and-swap clear. A stale window with an older attempt must never
    /// erase a newer safety record created by another window.
    public func clearIfCurrent(accountID: String, attemptID: String) throws {
        guard let current = try attempt(accountID: accountID) else { return }
        guard current.id == attemptID else {
            throw CustomFoodReconciliationStoreError.staleAttempt
        }
        try clear(accountID: accountID)
    }

    public func save(_ attempt: CustomFoodCreateAttempt) throws {
        guard !attempt.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomFoodReconciliationStoreError.invalidAccount
        }
        if let error = unreadableAccounts[attempt.accountID] {
            throw error
        }
        do {
            let data = try JSONEncoder().encode(attempt)
            guard data.count <= Self.maxBytes else {
                throw CustomFoodReconciliationStoreError.invalidAttempt
            }
            try persistence.save(data, accountID: attempt.accountID)
            cache[attempt.accountID] = attempt
        } catch let error as CustomFoodReconciliationStoreError {
            throw error
        } catch {
            throw CustomFoodReconciliationStoreError.persistence(error.localizedDescription)
        }
    }

    public func clear(accountID: String) throws {
        do {
            try persistence.remove(accountID: accountID)
            cache.removeValue(forKey: accountID)
            unreadableAccounts.removeValue(forKey: accountID)
        } catch {
            throw CustomFoodReconciliationStoreError.persistence(error.localizedDescription)
        }
    }

    /// Explicit last resort for unreadable state. The corrupt file is moved
    /// aside for diagnosis rather than overwritten.
    public func reset(accountID: String) throws {
        // Never erase a newer valid record that another window wrote after
        // this UI observed an unreadable one.
        if let data = try? persistence.load(accountID: accountID),
           (try? JSONDecoder().decode(CustomFoodCreateAttempt.self, from: data)) != nil {
            throw CustomFoodReconciliationStoreError.staleAttempt
        }
        persistence.quarantine(accountID: accountID, reason: "explicit reset")
        cache.removeValue(forKey: accountID)
        unreadableAccounts.removeValue(forKey: accountID)
    }
}

// MARK: - Creation and reconciliation engine

public enum CustomFoodCreateResult: Equatable, Sendable {
    case saved(foodID: String)
    case needsReconciliation(CustomFoodCreateAttempt)
    case failed(CustomFoodServiceError)
    /// The safety record could not be written or read, so no create was sent.
    case blocked(String)
}

@MainActor
public final class CustomFoodReconciliationEngine {
    public static let uncertainMessage = String(
        localized: "library.reconcile.uncertainMessage"
    )

    private let service: any LibraryServicing
    private let store: CustomFoodReconciliationStore
    private let accountID: String

    public init(
        service: any LibraryServicing,
        store: CustomFoodReconciliationStore,
        accountID: String
    ) {
        self.service = service
        self.store = store
        self.accountID = accountID
    }

    public func loadAttempt() throws -> CustomFoodCreateAttempt? {
        try store.attempt(accountID: accountID)
    }

    /// Persists the intent before sending, then sends exactly once. An
    /// ambiguous result leaves the durable attempt in place; a definitive
    /// rejection clears it.
    public func create(
        draft: CustomFoodWriteRequest,
        baselineFoodIDs: [String],
        logIntent: CustomFoodLogIntent? = nil,
        logBaseURL: URL? = nil,
        journalOperationID: String = UUID().uuidString.lowercased()
    ) async -> CustomFoodCreateResult {
        let operationID = logIntent == nil ? nil : journalOperationID
        let attempt = CustomFoodCreateAttempt(
            accountID: accountID,
            draft: draft,
            baselineFoodIDs: baselineFoodIDs,
            logIntent: logIntent,
            journalOperationID: operationID,
            journalBaseURLString: logIntent == nil
                ? nil
                : logBaseURL?.absoluteString,
            message: Self.uncertainMessage
        )
        do {
            let reserved = try store.reserve(attempt)
            guard reserved.id == attempt.id else {
                return .needsReconciliation(reserved)
            }
        } catch {
            return .blocked(String(localized: "library.reconcile.storeUnavailable"))
        }

        do {
            let foodID = try await service.createCustomFood(draft)
            guard !foodID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .needsReconciliation(attempt)
            }
            if logIntent == nil {
                do {
                    try store.clearIfCurrent(
                        accountID: accountID,
                        attemptID: attempt.id
                    )
                    return .saved(foodID: foodID)
                } catch {
                    // The catalog committed but the durable clear failed.
                    // Surface the created food through reconciliation rather
                    // than reporting a false clean result.
                    return .needsReconciliation(
                        attempt.withReturnedFoodID(foodID)
                    )
                }
            }
            do {
                let returned = attempt.withReturnedFoodID(foodID)
                let updated: CustomFoodCreateAttempt
                if let logIntent,
                   let journalRequest = makeJournalRequest(
                    foodID: foodID,
                    intent: logIntent,
                    operationID: attempt.journalOperationID,
                    baseURLString: attempt.journalBaseURLString
                ) {
                    updated = returned.withJournalRequest(journalRequest)
                } else {
                    updated = returned
                }
                _ = try store.saveIfCurrent(
                    updated,
                    accountID: accountID,
                    expectedAttemptID: attempt.id
                )
                return .saved(foodID: foodID)
            } catch {
                // The catalog committed but the returned ID could not be made
                // durable. Keep the original attempt and require explicit
                // reconciliation rather than losing the owed log.
                return .needsReconciliation(attempt)
            }
        } catch let error as CustomFoodServiceError {
            switch error {
            case .uncertain:
                return .needsReconciliation(attempt)
            case .unauthorized, .notFound, .failed, .conflict, .rateLimited:
                // The server definitively did not create the food.
                do {
                    try store.clearIfCurrent(
                        accountID: accountID,
                        attemptID: attempt.id
                    )
                    return .failed(error)
                } catch {
                    // The clear failed; retain the safety record and surface
                    // explicit recovery instead of claiming a clean failure.
                    return .needsReconciliation(attempt)
                }
            }
        } catch {
            return .needsReconciliation(attempt)
        }
    }

    public func candidates(
        for attempt: CustomFoodCreateAttempt
    ) async throws -> [CustomFood] {
        let foods = try await service.listCustomFoods()
        return attempt.matches(in: foods)
    }

    /// Returns the retained attempt when a log is still owed. For a plain
    /// create, the attempt is cleared and nil is returned.
    @discardableResult
    public func resolve(
        attempt: CustomFoodCreateAttempt,
        food: CustomFood
    ) throws -> CustomFoodCreateAttempt? {
        guard attempt.accountID == accountID else {
            throw CustomFoodReconciliationStoreError.invalidAccount
        }
        if let intent = attempt.logIntent {
            let returned = attempt.withReturnedFoodID(food.id)
            let updated: CustomFoodCreateAttempt
            if let journalRequest = makeJournalRequest(
                foodID: food.id,
                intent: intent,
                operationID: attempt.journalOperationID,
                baseURLString: attempt.journalBaseURLString
            ) {
                updated = returned.withJournalRequest(journalRequest)
            } else {
                updated = returned
            }
            return try store.saveIfCurrent(
                updated,
                accountID: accountID,
                expectedAttemptID: attempt.id
            )
        }
        try store.clearIfCurrent(accountID: accountID, attemptID: attempt.id)
        return nil
    }

    /// Only after an explicit user confirmation that the library was checked.
    public func discard(attempt: CustomFoodCreateAttempt) throws {
        guard attempt.accountID == accountID else {
            throw CustomFoodReconciliationStoreError.invalidAccount
        }
        try store.clearIfCurrent(accountID: accountID, attemptID: attempt.id)
    }

    public func currentAttempt() throws -> CustomFoodCreateAttempt? {
        try loadAttempt()
    }

    /// Clears only this exact operation after the shared log journal has
    /// definitely reserved the owed log. Stale windows fail closed.
    public func completeLogHandoff(attemptID: String) throws {
        try store.clearIfCurrent(accountID: accountID, attemptID: attemptID)
    }

    public func requireCurrentAttempt(id: String) throws -> CustomFoodCreateAttempt {
        guard let current = try loadAttempt(), current.id == id else {
            throw CustomFoodReconciliationStoreError.staleAttempt
        }
        return current
    }

    /// Persists the exact journal request before any reservation/network call.
    /// The operation key is never regenerated for an existing attempt.
    public func prepareJournalRequest(
        attemptID: String,
        currentBaseURL: URL?
    ) throws -> CustomFoodJournalRequest {
        let attempt = try requireCurrentAttempt(id: attemptID)
        guard let foodID = attempt.foodID,
              let intent = attempt.logIntent,
              let operationID = attempt.journalOperationID,
              !operationID.isEmpty else {
            throw CustomFoodReconciliationStoreError.invalidAttempt
        }
        if let storedBase = attempt.journalBaseURLString,
           let currentBase = currentBaseURL?.absoluteString,
           storedBase != currentBase {
            throw CustomFoodReconciliationStoreError.serverChanged
        }
        if let existing = attempt.journalRequest {
            return existing
        }
        guard let request = makeJournalRequest(
            foodID: foodID,
            intent: intent,
            operationID: operationID,
            baseURLString: currentBaseURL?.absoluteString
                ?? attempt.journalBaseURLString
        ) else {
            throw CustomFoodReconciliationStoreError.invalidAttempt
        }
        let updated = attempt.withJournalRequest(request)
        _ = try store.saveIfCurrent(
            updated,
            accountID: accountID,
            expectedAttemptID: attempt.id
        )
        return request
    }

    public func resetUnreadableState() throws {
        try store.reset(accountID: accountID)
    }

    private func makeJournalRequest(
        foodID: String,
        intent: CustomFoodLogIntent,
        operationID: String?,
        baseURLString: String?
    ) -> CustomFoodJournalRequest? {
        guard let operationID, !operationID.isEmpty else { return nil }
        let draft = intent.logSubmissionDraft(productID: foodID)
        let baseURL = baseURLString.flatMap(URL.init(string:))
        guard let prepared = try? LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: baseURL,
            idempotencyKey: operationID
        ) else {
            return nil
        }
        return CustomFoodJournalRequest(
            operationID: operationID,
            requestPath: prepared.request.requestPath,
            body: prepared.request.body,
            baseURLString: prepared.request.baseURLString
        )
    }
}
