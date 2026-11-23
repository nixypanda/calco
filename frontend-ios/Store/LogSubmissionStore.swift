// Account-scoped, write-ahead journal for single food-log submissions.

import Combine
import Foundation

public protocol LogSubmissionPersisting: Sendable {
    func load(accountID: String) throws -> Data?
    func save(_ data: Data, accountID: String) throws
    func quarantine(accountID: String, reason: String)
}

public enum LogSubmissionStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case invalidRequest
    case bodyTooLarge
    case tooManyEntries
    case missingEntry
    /// A matching request is still being sent by this process. Deleting the
    /// log now would let that late POST recreate it, so the delete must wait.
    case submissionInFlight
    /// The journal cannot be read or was quarantined. Until the app starts
    /// with a readable journal, no POST may be sent and the unreadable file
    /// must not be overwritten.
    case unreadableJournal(String)
    case persistence(String)
}

public struct FileLogSubmissionPersistence: LogSubmissionPersisting {
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
                .appendingPathComponent("LogSubmissions", isDirectory: true)
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
            .appendingPathComponent("log-submissions-\(encoded).json")
    }
}

@MainActor
public final class LogSubmissionStore: ObservableObject {
    private struct Envelope: Codable {
        let schemaVersion: Int
        var entries: [PendingLogSubmission]
    }

    /// Used only to tell a newer, unsupported journal apart from a corrupt
    /// schema-1 file. Newer journals are quarantined without replay and without
    /// blocking the legacy single-food journal.
    private struct EnvelopeSchemaProbe: Decodable {
        let schemaVersion: Int
    }

    public static let maxEntriesPerAccount = 20
    public static let maxBodyBytes = LogCreateRequestBuilder.maxBodyBytes
    /// One journal cache per app process. Every AppShell window must use this
    /// instance (or an explicitly injected test store) so two windows cannot
    /// act on divergent in-memory views of the same journal file.
    public static let shared = LogSubmissionStore()

    @Published public private(set) var revision: UInt64 = 0

    private let persistence: any LogSubmissionPersisting
    private let now: () -> Date
    private var cache: [String: [PendingLogSubmission]] = [:]
    /// Once a journal is unreadable or quarantined, all writes for that account
    /// fail closed until a new store can load a readable file.
    private var unreadableAccounts: [String: LogSubmissionStoreError] = [:]
    /// In-flight rows that this process is actively sending. Other in-flight
    /// rows are crash leftovers and still need attention.
    private var liveSubmissionIDs: Set<String> = []
    /// Entries whose log was deleted during this process. The barrier is
    /// installed before persistence so a failed journal write cannot leave a
    /// retry control active for an attempt that might recreate the log.
    private var retryBlockedIDs: Set<String> = []

    public init(
        persistence: any LogSubmissionPersisting = FileLogSubmissionPersistence(),
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.now = now
    }

    public func entries(accountID: String) -> [PendingLogSubmission] {
        ((try? loadEntries(accountID: accountID)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Recovery UI only invites the user to act on entries whose outcome is
    /// already ambiguous. A live in-flight request must not appear as a stale
    /// problem in the global banner.
    public func attentionEntries(accountID: String) -> [PendingLogSubmission] {
        entries(accountID: accountID).filter {
            guard !retryBlockedIDs.contains($0.id) else { return false }
            return $0.state == .uncertain
                || $0.state == .conflicted
                || ($0.state == .inFlight && !liveSubmissionIDs.contains($0.id))
        }
    }

    /// Every non-terminal entry matching this draft context, including a live
    /// in-flight attempt. Normal Log must not mint a second key beside one.
    public func unresolved(
        accountID: String,
        foodID: String,
        date: LocalDiaryDate
    ) -> [PendingLogSubmission] {
        entries(accountID: accountID).filter {
            guard !retryBlockedIDs.contains($0.id) else { return false }
            return $0.draft.foodID == foodID
                && $0.draft.date == date
                && ($0.state == .inFlight
                    || $0.state == .uncertain
                    || $0.state == .conflicted)
        }
    }

    public func entry(id: String, accountID: String) -> PendingLogSubmission? {
        ((try? loadEntries(accountID: accountID)) ?? []).first { $0.id == id }
    }

    /// Throws instead of returning nil so callers cannot accidentally send a
    /// request whose journal row is missing or whose journal is unreadable.
    public func requireEntry(id: String, accountID: String) throws -> PendingLogSubmission {
        guard let entry = try loadEntries(accountID: accountID).first(where: { $0.id == id })
        else { throw LogSubmissionStoreError.missingEntry }
        return entry
    }

    public func journalError(accountID: String) -> LogSubmissionStoreError? {
        unreadableAccounts[accountID]
    }

    public func isLiveSubmission(id: String) -> Bool {
        liveSubmissionIDs.contains(id)
    }

    /// True after a successful log deletion made this attempt unsafe to
    /// replay, even if the journal write itself failed.
    public func isRetryBlocked(id: String) -> Bool {
        retryBlockedIDs.contains(id)
    }

    @discardableResult
    public func reserve(
        accountID: String,
        foodName: String,
        draft: LogSubmissionDraft,
        request: FoodLogCreateRequest,
        body: Data
    ) throws -> PendingLogSubmission {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogSubmissionStoreError.invalidAccount
        }
        guard let key = request.idempotencyKey, !key.isEmpty else {
            throw LogSubmissionStoreError.invalidRequest
        }
        guard body.count <= Self.maxBodyBytes else {
            throw LogSubmissionStoreError.bodyTooLarge
        }

        var entries = try loadEntries(accountID: accountID)
        entries.removeAll {
            $0.state == .succeeded || $0.state == .rejected || $0.state == .invalidated
        }
        guard entries.count < Self.maxEntriesPerAccount else {
            throw LogSubmissionStoreError.tooManyEntries
        }
        let timestamp = now()
        let entry = PendingLogSubmission(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            foodName: foodName,
            draft: draft,
            idempotencyKey: key,
            body: body,
            baseURLString: request.baseURLString ?? "",
            state: .inFlight,
            attemptCount: 0,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        entries.append(entry)
        try persistAndCache(entries, accountID: accountID)
        return entry
    }

    public func markInFlight(id: String, accountID: String) throws {
        // Mark live before persisting: revision observers run synchronously
        // and must not briefly classify this request as stale attention.
        liveSubmissionIDs.insert(id)
        var marked = false
        do {
            try update(id: id, accountID: accountID) { entry in
                guard entry.state != .succeeded,
                      entry.state != .conflicted,
                      entry.state != .invalidated,
                      !self.retryBlockedIDs.contains(entry.id)
                else { return }
                entry.state = .inFlight
                entry.attemptCount += 1
                entry.updatedAt = self.now()
                marked = true
            }
        } catch {
            liveSubmissionIDs.remove(id)
            throw error
        }
        if !marked {
            // A barrier landed before this send began. Do not leave a phantom
            // live flag that would block every later delete.
            liveSubmissionIDs.remove(id)
        }
    }

    public func markUncertain(
        id: String,
        accountID: String,
        status: Int?,
        message: String,
        retryAfterSeconds: Int? = nil
    ) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .conflicted,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            entry.state = .uncertain
            entry.lastStatus = status
            entry.lastMessage = message
            entry.retryAfterSeconds = retryAfterSeconds
            entry.updatedAt = self.now()
        }
    }

    public func markSucceeded(
        id: String,
        accountID: String,
        logID: String?,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        replayed: Bool
    ) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            entry.state = .succeeded
            entry.body = nil
            entry.resultLogID = logID
            entry.resultDate = date
            entry.resultMealSlot = mealSlot
            entry.replayed = replayed
            entry.lastStatus = replayed ? 200 : 201
            entry.lastMessage = nil
            entry.updatedAt = self.now()
        }
    }

    public func markRejected(
        id: String,
        accountID: String,
        status: Int?,
        message: String
    ) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            entry.state = .rejected
            entry.lastStatus = status
            entry.lastMessage = message
            entry.updatedAt = self.now()
        }
    }

    public func markConflicted(id: String, accountID: String, message: String) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            entry.state = .conflicted
            entry.body = nil
            entry.lastStatus = 409
            entry.lastMessage = message
            entry.updatedAt = self.now()
        }
    }

    /// Terminalizes every unresolved attempt that could have produced the log
    /// being deleted. Matching is deliberately conservative: product and date
    /// are required, while meal slot, quantity and notes are ignored because
    /// the user may have edited the log before deleting it.
    ///
    /// This variant is also used after an out-of-band deletion is discovered
    /// while a POST is live, so the live sender's late success cannot overwrite
    /// the barrier. It must not be used to prepare an in-app DELETE; use
    /// `blockBeforeDeleting` for that so a live POST is allowed to finish first.
    ///
    /// This does not erase unrelated entries. Each match becomes `.invalidated`
    /// with a user-facing reason and its body removed so no retry can resurrect
    /// a removed log after the backend frees its idempotency key.
    @discardableResult
    public func invalidateUnresolved(
        accountID: String,
        foodID: String,
        date: LocalDiaryDate,
        reason: String
    ) throws -> [PendingLogSubmission] {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogSubmissionStoreError.invalidAccount
        }
        let entries = try loadEntries(accountID: accountID)
        let matching = Self.unresolvedMatches(in: entries, foodID: foodID, date: date)
        return try invalidate(entries: entries, matching: matching, accountID: accountID, reason: reason)
    }

    /// Durably blocks every unresolved attempt that could recreate the log
    /// before the backend DELETE is sent.
    ///
    /// A successful return means the barrier is durable and the DELETE may
    /// proceed. Any thrown error means the DELETE must not be sent. A matching
    /// live POST throws `.submissionInFlight` because a late success could
    /// recreate the log after deletion.
    @discardableResult
    public func blockBeforeDeleting(
        accountID: String,
        foodID: String,
        date: LocalDiaryDate,
        reason: String
    ) throws -> [PendingLogSubmission] {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogSubmissionStoreError.invalidAccount
        }
        let entries = try loadEntries(accountID: accountID)
        let matching = Self.unresolvedMatches(in: entries, foodID: foodID, date: date)
        guard !matching.isEmpty else { return [] }
        guard !matching.contains(where: { self.liveSubmissionIDs.contains($0.id) }) else {
            throw LogSubmissionStoreError.submissionInFlight
        }
        return try invalidate(entries: entries, matching: matching, accountID: accountID, reason: reason)
    }

    private static func unresolvedMatches(
        in entries: [PendingLogSubmission],
        foodID: String,
        date: LocalDiaryDate
    ) -> [PendingLogSubmission] {
        entries.filter { entry in
            entry.draft.foodID == foodID
                && entry.draft.date == date
                && (entry.state == .inFlight
                    || entry.state == .uncertain
                    || entry.state == .conflicted)
        }
    }

    private func invalidate(
        entries: [PendingLogSubmission],
        matching: [PendingLogSubmission],
        accountID: String,
        reason: String
    ) throws -> [PendingLogSubmission] {
        guard !matching.isEmpty else { return [] }
        let matchingIDs = Set(matching.map(\.id))

        // Install the in-memory barrier before writing so observers cannot
        // briefly see a retry control for an attempt that is being blocked.
        // If persistence fails, roll the in-memory barrier back: the DELETE
        // was not sent, so allowing a later retry to try the write again is
        // safe and avoids a process-wide block with no durable record.
        let previousRetryBlocked = retryBlockedIDs
        let previousLive = liveSubmissionIDs
        retryBlockedIDs.formUnion(matchingIDs)
        liveSubmissionIDs.subtract(matchingIDs)
        var updated = entries
        let timestamp = now()
        for index in updated.indices where matchingIDs.contains(updated[index].id) {
            updated[index].state = .invalidated
            updated[index].body = nil
            updated[index].lastStatus = nil
            updated[index].retryAfterSeconds = nil
            updated[index].lastMessage = reason
            updated[index].updatedAt = timestamp
        }
        do {
            try persistAndCache(updated, accountID: accountID)
        } catch {
            retryBlockedIDs = previousRetryBlocked
            liveSubmissionIDs = previousLive
            revision &+= 1
            throw error
        }
        return updated.filter { matchingIDs.contains($0.id) }
    }

    public func remove(id: String, accountID: String) throws {
        defer {
            liveSubmissionIDs.remove(id)
            retryBlockedIDs.remove(id)
        }
        var entries = try loadEntries(accountID: accountID)
        entries.removeAll { $0.id == id }
        try persistAndCache(entries, accountID: accountID)
    }

    private func loadEntries(accountID: String) throws -> [PendingLogSubmission] {
        if let failure = unreadableAccounts[accountID] {
            throw failure
        }
        if let cached = cache[accountID] {
            return cached
        }
        let data: Data?
        do {
            data = try persistence.load(accountID: accountID)
        } catch {
            let failure = LogSubmissionStoreError.unreadableJournal(
                error.localizedDescription
            )
            unreadableAccounts[accountID] = failure
            throw failure
        }
        guard let data else {
            cache[accountID] = []
            return []
        }
        if let probe = try? JSONDecoder().decode(EnvelopeSchemaProbe.self, from: data),
           probe.schemaVersion > 1 {
            // A journal written by a newer build may contain multi-item
            // operations that cannot be replayed by this legacy single-log
            // journal. Quarantine it instead of replaying or overwriting it.
            persistence.quarantine(
                accountID: accountID,
                reason: "unsupported-newer-schema-\(probe.schemaVersion)"
            )
            cache[accountID] = []
            return []
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1,
              envelope.entries.allSatisfy({
                  $0.accountID == accountID && Self.isValid($0)
              })
        else {
            persistence.quarantine(accountID: accountID, reason: "invalid-envelope")
            let failure = LogSubmissionStoreError.unreadableJournal(
                "The pending submission journal was quarantined."
            )
            unreadableAccounts[accountID] = failure
            throw failure
        }

        var entries = envelope.entries
        var changed = false
        let timestamp = now()
        for index in entries.indices where entries[index].state == .inFlight {
            entries[index].state = .uncertain
            entries[index].updatedAt = timestamp
            changed = true
        }
        let beforePrune = entries.count
        entries.removeAll { Self.shouldPrune($0, now: timestamp) }
        changed = changed || entries.count != beforePrune

        cache[accountID] = entries
        if changed {
            try? persist(entries, accountID: accountID)
        }
        return entries
    }

    private func update(
        id: String,
        accountID: String,
        mutate: (inout PendingLogSubmission) -> Void
    ) throws {
        var entries = try loadEntries(accountID: accountID)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw LogSubmissionStoreError.missingEntry
        }
        mutate(&entries[index])
        try persistAndCache(entries, accountID: accountID)
    }

    /// Publish the new in-memory state before the synchronous `revision`
    /// notification so observers never read the previous entry state.
    private func persistAndCache(
        _ entries: [PendingLogSubmission],
        accountID: String
    ) throws {
        let previous = cache[accountID]
        cache[accountID] = entries
        do {
            try persist(entries, accountID: accountID)
        } catch {
            cache[accountID] = previous
            throw error
        }
    }

    private func persist(_ entries: [PendingLogSubmission], accountID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Envelope(schemaVersion: 1, entries: entries))
            try persistence.save(data, accountID: accountID)
            revision &+= 1
        } catch {
            throw LogSubmissionStoreError.persistence(error.localizedDescription)
        }
    }

    private static func isValid(_ entry: PendingLogSubmission) -> Bool {
        guard !entry.accountID.isEmpty,
              !entry.id.isEmpty,
              !entry.idempotencyKey.isEmpty,
              entry.idempotencyKey.count <= 128,
              !entry.idempotencyKey.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ),
              entry.requestPath == "/api/logs"
        else { return false }
        if let body = entry.body, body.count > maxBodyBytes {
            return false
        }
        return true
    }

    private static func shouldPrune(_ entry: PendingLogSubmission, now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.updatedAt)
        switch entry.state {
        case .succeeded:
            return age > 60 * 60
        case .rejected, .conflicted, .invalidated:
            return age > 7 * 24 * 60 * 60
        case .uncertain:
            return age > 30 * 24 * 60 * 60
        case .inFlight:
            return false
        }
    }
}
