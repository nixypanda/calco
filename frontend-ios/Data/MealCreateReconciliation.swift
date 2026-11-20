// Durable, account-scoped safety record for an uncertain meal create.
//
// `POST /api/meals` is not idempotent and the backend currently exposes no
// operation key for it. The intent is persisted before sending. If the response
// is lost, every window and later launch blocks another create until the user
// explicitly reconciles a matching meal from the server or discards the record
// after a warning.

import Foundation

public struct MealCreateAttempt: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let request: MealWriteRequest
    /// Meals observed before this create. A reconciled match must be new.
    public let baselineMealIDs: [String]
    public let createdAt: Date
    public let message: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        accountID: String,
        request: MealWriteRequest,
        baselineMealIDs: [String],
        createdAt: Date = Date(),
        message: String = MealCreateAttempt.uncertainMessage
    ) {
        self.id = id
        self.accountID = accountID
        self.request = request
        self.baselineMealIDs = baselineMealIDs
        self.createdAt = createdAt
        self.message = message
    }

    public static var uncertainMessage: String {
        String(localized: "meals.reconcile.uncertainMessage")
    }

    public var displayName: String {
        request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Server meals that exactly match the attempted editable aggregate and
    /// were not present before the create was sent. The user still confirms.
    public func matches(in meals: [Meal]) -> [Meal] {
        let baseline = Set(baselineMealIDs)
        return meals.filter { meal in
            !baseline.contains(meal.id) && Self.matches(meal: meal, request: request)
        }
    }

    public static func matches(meal: Meal, request: MealWriteRequest) -> Bool {
        guard meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
                == request.name.trimmingCharacters(in: .whitespacesAndNewlines),
              normalizedNotes(meal.notes) == normalizedNotes(request.notes),
              quantityMatches(meal.totalQuantity, request.totalQuantity),
              meal.components.count == request.components.count else {
            return false
        }

        // Server component order is not guaranteed and amounts may be
        // re-scaled ("50.0" vs "50"). Compare an unordered multiset so
        // duplicate products still require the same multiplicity.
        var expectedKeys: [String] = []
        for expected in request.components {
            guard expected.item.itemType == .product,
                  let key = componentKey(
                      productID: expected.item.id,
                      quantity: expected.quantity
                  ) else {
                return false
            }
            expectedKeys.append(key)
        }

        var actualKeys: [String] = []
        for component in meal.components {
            guard component.item.itemType == .product,
                  let key = componentKey(
                      productID: component.item.id,
                      quantity: component.quantity
                  ) else {
                return false
            }
            actualKeys.append(key)
        }
        return actualKeys.sorted() == expectedKeys.sorted()
    }

    private static func componentKey(
        productID: String,
        quantity: NutritionQuantity
    ) -> String? {
        guard let amount = normalizedDecimalText(quantity.amount) else { return nil }
        let unit = quantity.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty else { return nil }
        return "\(productID)|\(unit)|\(amount)"
    }

    private static func normalizedDecimalText(_ raw: String) -> String? {
        let normalized = MealQuantityRules.normalizedPositiveDecimal(raw)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private static func normalizedNotes(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func quantityMatches(
        _ lhs: NutritionQuantity?,
        _ rhs: NutritionQuantity?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs?, let rhs?):
            guard let lhsAmount = normalizedDecimalText(lhs.amount),
                  let rhsAmount = normalizedDecimalText(rhs.amount) else {
                return false
            }
            return lhsAmount == rhsAmount
                && lhs.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                    == rhs.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return false
        }
    }
}

public enum MealCreateReconciliationStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case invalidAttempt
    /// Another window replaced or cleared the attempt this caller still holds.
    case staleAttempt
    case unreadable(String)
    case persistence(String)
}

public protocol MealCreateReconciliationPersisting: Sendable {
    func load(accountID: String) throws -> Data?
    func save(_ data: Data, accountID: String) throws
    func remove(accountID: String) throws
    func quarantine(accountID: String, reason: String)
}

public struct FileMealCreateReconciliationPersistence:
    MealCreateReconciliationPersisting
{
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
                .appendingPathComponent("MealCreateReconciliation", isDirectory: true)
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
            .appendingPathComponent("meal-create-\(encoded).json")
    }
}

@MainActor
public final class MealCreateReconciliationStore {
    public static let maxBytes = 128 * 1024
    public static let shared = MealCreateReconciliationStore()

    private let persistence: any MealCreateReconciliationPersisting
    private var cache: [String: MealCreateAttempt] = [:]
    private var unreadableAccounts: [String: MealCreateReconciliationStoreError] = [:]

    public init(
        persistence: any MealCreateReconciliationPersisting =
            FileMealCreateReconciliationPersistence()
    ) {
        self.persistence = persistence
    }

    public func attempt(accountID: String) throws -> MealCreateAttempt? {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MealCreateReconciliationStoreError.invalidAccount
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
            let attempt = try JSONDecoder().decode(MealCreateAttempt.self, from: data)
            guard attempt.accountID == accountID else {
                throw MealCreateReconciliationStoreError.invalidAttempt
            }
            cache[accountID] = attempt
            return attempt
        } catch let error as MealCreateReconciliationStoreError {
            // Leave the file in place until an explicit reset. Moving it during
            // detection would unblock a duplicate create in a new process.
            unreadableAccounts[accountID] = error
            throw error
        } catch {
            let storeError = MealCreateReconciliationStoreError.unreadable(
                error.localizedDescription
            )
            unreadableAccounts[accountID] = storeError
            throw storeError
        }
    }

    /// Atomically reserve the account's only create attempt. On a shared store
    /// this serializes two windows on the main actor; the loser receives the
    /// already-reserved attempt instead of overwriting it.
    public func reserve(_ candidate: MealCreateAttempt) throws -> MealCreateAttempt {
        if let existing = try attempt(accountID: candidate.accountID) {
            return existing
        }
        try save(candidate)
        return candidate
    }

    public func save(_ attempt: MealCreateAttempt) throws {
        guard !attempt.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MealCreateReconciliationStoreError.invalidAccount
        }
        if let error = unreadableAccounts[attempt.accountID] {
            throw error
        }
        do {
            let data = try JSONEncoder().encode(attempt)
            guard data.count <= Self.maxBytes else {
                throw MealCreateReconciliationStoreError.invalidAttempt
            }
            try persistence.save(data, accountID: attempt.accountID)
            cache[attempt.accountID] = attempt
        } catch let error as MealCreateReconciliationStoreError {
            throw error
        } catch {
            throw MealCreateReconciliationStoreError.persistence(error.localizedDescription)
        }
    }

    /// Compare-and-swap clear. A stale editor must not erase a newer attempt
    /// created by another window.
    public func clearIfCurrent(accountID: String, attemptID: String) throws {
        guard let current = try attempt(accountID: accountID) else { return }
        guard current.id == attemptID else {
            throw MealCreateReconciliationStoreError.staleAttempt
        }
        try clear(accountID: accountID)
    }

    public func clear(accountID: String) throws {
        do {
            try persistence.remove(accountID: accountID)
            cache.removeValue(forKey: accountID)
            unreadableAccounts.removeValue(forKey: accountID)
        } catch {
            throw MealCreateReconciliationStoreError.persistence(error.localizedDescription)
        }
    }

    /// Explicit last resort for unreadable state. The corrupt file is moved
    /// aside rather than overwritten.
    public func reset(accountID: String) throws {
        if let data = try? persistence.load(accountID: accountID),
           (try? JSONDecoder().decode(MealCreateAttempt.self, from: data)) != nil {
            throw MealCreateReconciliationStoreError.staleAttempt
        }
        persistence.quarantine(accountID: accountID, reason: "explicit reset")
        cache.removeValue(forKey: accountID)
        unreadableAccounts.removeValue(forKey: accountID)
    }
}
