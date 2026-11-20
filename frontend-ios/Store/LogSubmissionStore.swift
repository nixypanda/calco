// Account-scoped, write-ahead journal for single food-log submissions.

import Combine
import CryptoKit
import Foundation

public protocol LogSubmissionPersisting: Sendable {
    func load(accountID: String) throws -> Data?
    func save(_ data: Data, accountID: String) throws
    func quarantine(accountID: String, reason: String)
    /// A quarantine marker survives relaunch so a missing journal file is never
    /// silently treated as an empty journal.
    func isQuarantined(accountID: String) -> Bool
    func clearQuarantine(accountID: String) throws
    /// Resolves the quarantined source for this account before the marker is
    /// cleared. A persistences that cannot prove the source identity must not
    /// report a clean recovery.
    func finalizeQuarantine(accountID: String) throws
}

public extension LogSubmissionPersisting {
    func isQuarantined(accountID: String) -> Bool { false }
    func clearQuarantine(accountID: String) throws {}
    func finalizeQuarantine(accountID: String) throws {
        guard !isQuarantined(accountID: accountID) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public enum LogSubmissionStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case invalidRequest
    case bodyTooLarge
    case tooManyEntries
    case missingEntry
    /// The same account already reserved this idempotency key with different
    /// request bytes. Reusing the key would make the backend return the old
    /// operation, so the new request must not be sent.
    case idempotencyConflict
    /// A prepared intent is no longer safe to reserve, usually because its log
    /// was deleted while capability verification was in flight.
    case preparedIntentUnavailable
    case preparedIntentCancelled(String)
    case preparedIntentPending
    /// A matching request is still being sent by this process. Deleting the
    /// log now would let that late POST recreate it, so the delete must wait.
    case submissionInFlight
    /// The journal cannot be read or was quarantined. Until the app starts
    /// with a readable journal, no POST may be sent and the unreadable file
    /// must not be overwritten.
    case unreadableJournal(String)
    case persistence(String)
}

/// A synchronous, in-memory claim on a logical log operation. It exists before
/// the async capability probe so a delete barrier can cancel the action, but it
/// is not a journal row and mints no backend key until capability is verified.
public struct PreparedLogSubmissionIntent: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let summary: String
    public let drafts: [LogSubmissionDraft]
    public let itemNames: [String]?
    public let request: LogSubmissionRequest
    public let createdAt: Date
}

public struct FileLogSubmissionPersistence: LogSubmissionPersisting {
    private struct QuarantineMarker: Codable {
        let reason: String
        let size: Int?
        let sha256: String?
    }

    public let directoryURL: URL
    /// Injectable move used while recording a quarantine. Recovery uses a
    /// separate hook so a failed initial move can still be resolved explicitly.
    public var quarantineMove: @Sendable (URL, URL) throws -> Void
    public var recoveryMove: @Sendable (URL, URL) throws -> Void

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
        self.quarantineMove = { try FileManager.default.moveItem(at: $0, to: $1) }
        self.recoveryMove = { try FileManager.default.moveItem(at: $0, to: $1) }
    }

    public func load(accountID: String) throws -> Data? {
        let marker = markerURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: marker.path) {
            throw CocoaError(.fileReadCorruptFile)
        }
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
        let marker = markerURL(accountID: accountID)
        try? createDirectoryIfNeeded()
        if FileManager.default.fileExists(atPath: marker.path) { return }

        let source = try? Data(contentsOf: url)
        let markerValue = QuarantineMarker(
            reason: reason,
            size: source?.count,
            sha256: source.map(Self.sha256)
        )
        let markerData: Data
        do {
            markerData = try JSONEncoder().encode(markerValue)
        } catch {
            return
        }
        do {
            try markerData.write(to: marker, options: [.atomic])
        } catch {
            // Without a durable marker the corrupt source is the only evidence
            // that this account is blocked. Never move or delete it.
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let suffix = UUID().uuidString.lowercased()
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(suffix)")
        try? quarantineMove(url, destination)
    }

    public func isQuarantined(accountID: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(accountID: accountID).path)
    }

    public func clearQuarantine(accountID: String) throws {
        let marker = markerURL(accountID: accountID)
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    /// Moves the exact corrupt source recorded in the marker, then clears the
    /// marker. If the source changed or cannot be moved, the marker and source
    /// remain so the account stays fail-closed.
    public func finalizeQuarantine(accountID: String) throws {
        let marker = markerURL(accountID: accountID)
        guard let markerData = try? Data(contentsOf: marker) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let markerValue = try? JSONDecoder().decode(
            QuarantineMarker.self,
            from: markerData
        )
        let source = fileURL(accountID: accountID)
        let sourceExists = FileManager.default.fileExists(atPath: source.path)
        guard let markerValue else {
            // Legacy plain-text markers cannot prove a source identity. If the
            // source was already moved there is nothing left to delete; never
            // clear a legacy marker while an unverified source still exists.
            guard !sourceExists else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.removeItem(at: marker)
            return
        }

        if sourceExists {
            guard let expectedSize = markerValue.size,
                  let expectedHash = markerValue.sha256,
                  let sourceData = try? Data(contentsOf: source),
                  sourceData.count == expectedSize,
                  Self.sha256(sourceData) == expectedHash
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let suffix = UUID().uuidString.lowercased()
            let destination = source.deletingLastPathComponent()
                .appendingPathComponent("\(source.lastPathComponent).corrupt-\(suffix)")
            try recoveryMove(source, destination)
        }
        try FileManager.default.removeItem(at: marker)
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
        directoryURL
            .appendingPathComponent("log-submissions-\(encodedAccount(accountID)).json")
    }

    private func markerURL(accountID: String) -> URL {
        directoryURL
            .appendingPathComponent(
                "log-submissions-\(encodedAccount(accountID)).quarantined"
            )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func encodedAccount(_ accountID: String) -> String {
        Data(accountID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
public final class LogSubmissionStore: ObservableObject {
    private struct Envelope: Codable {
        let schemaVersion: Int
        var entries: [PendingLogSubmission]
    }

    public static let maxEntriesPerAccount = 20
    public static let maxBodyBytes = LogCreateRequestBuilder.maxBodyBytes
    /// Current journal schema. Version 1 entries decode through the typed-draft
    /// migration and are rewritten as version 2 on the next load.
    public static let schemaVersion = 2
    private static let allowedPaths: Set<String> = [
        LogSubmissionRoute.single.requestPath,
        LogSubmissionRoute.batch.requestPath,
        LogSubmissionRoute.adHoc.requestPath,
    ]
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
    /// Async submissions hold this in-memory claim while capability is being
    /// verified. It is not a journal row, so no key/body is persisted until the
    /// probe succeeds; delete barriers can still cancel it.
    private var preparedIntents: [String: PreparedIntentRecord] = [:]

    private struct PreparedIntentRecord {
        let intent: PreparedLogSubmissionIntent
        var cancelledReason: String?
    }

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
                || $0.state == .serverChanged
                || $0.state == .reconciliationOnly
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
        unresolved(accountID: accountID, item: .product(id: foodID), date: date)
    }

    public func unresolved(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate
    ) -> [PendingLogSubmission] {
        entries(accountID: accountID).filter {
            guard !retryBlockedIDs.contains($0.id) else { return false }
            return $0.allDrafts.contains {
                $0.item == item && $0.date == date
            } && ($0.state == .inFlight
                || $0.state == .uncertain
                || $0.state == .conflicted
                || $0.state == .serverChanged
                || $0.state == .reconciliationOnly)
        }
    }

    public func entry(id: String, accountID: String) -> PendingLogSubmission? {
        ((try? loadEntries(accountID: accountID)) ?? []).first { $0.id == id }
    }

    /// Finds an operation by its durable key, including terminal entries that
    /// are still present in the bounded journal. Callers must not treat a
    /// missing entry as proof that the operation never existed.
    public func entry(
        accountID: String,
        idempotencyKey: String
    ) -> PendingLogSubmission? {
        guard !idempotencyKey.isEmpty else { return nil }
        return ((try? loadEntries(accountID: accountID)) ?? [])
            .first { $0.idempotencyKey == idempotencyKey }
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

    /// Explicit user recovery after confirming the local pending-journal loss.
    /// The exact quarantined source is moved before the marker is cleared; a
    /// failed or stale recovery keeps the account blocked.
    public func recoverQuarantinedJournal(accountID: String) throws {
        guard persistence.isQuarantined(accountID: accountID) else {
            throw unreadableAccounts[accountID]
                ?? LogSubmissionStoreError.unreadableJournal(
                    "The journal is not quarantined."
                )
        }
        do {
            try persistence.finalizeQuarantine(accountID: accountID)
        } catch {
            throw LogSubmissionStoreError.persistence(error.localizedDescription)
        }
        unreadableAccounts.removeValue(forKey: accountID)
        cache[accountID] = []
        revision &+= 1
    }

    public func isLiveSubmission(id: String) -> Bool {
        liveSubmissionIDs.contains(id)
    }

    /// True after a successful log deletion made this attempt unsafe to
    /// replay, even if the journal write itself failed.
    public func isRetryBlocked(id: String) -> Bool {
        retryBlockedIDs.contains(id)
    }

    /// Captures a logical action synchronously before any capability probe.
    /// No journal row or backend key exists until `reservePreparedIntent`.
    public func prepareIntent(
        accountID: String,
        summary: String,
        drafts: [LogSubmissionDraft],
        request: LogSubmissionRequest,
        itemNames: [String]? = nil
    ) throws -> PreparedLogSubmissionIntent {
        let key = try Self.validateReservation(
            accountID: accountID,
            drafts: drafts,
            request: request
        )
        let cutoff = now().addingTimeInterval(-300)
        preparedIntents = preparedIntents.filter {
            $0.value.intent.createdAt >= cutoff
        }
        let entries = try loadEntries(accountID: accountID)
        if let existing = entries.first(where: { $0.idempotencyKey == key }),
           !existing.matchesRequest(request, drafts: drafts) {
            throw LogSubmissionStoreError.idempotencyConflict
        }
        if let prepared = preparedIntents.values.first(where: {
            $0.intent.accountID == accountID
                && $0.intent.request.idempotencyKey == key
        }) {
            guard Self.matches(prepared.intent, drafts: drafts, request: request) else {
                throw LogSubmissionStoreError.idempotencyConflict
            }
            return prepared.intent
        }
        let intent = PreparedLogSubmissionIntent(
            id: UUID().uuidString.lowercased(),
            accountID: accountID,
            summary: summary,
            drafts: drafts,
            itemNames: itemNames,
            request: request,
            createdAt: now()
        )
        preparedIntents[intent.id] = PreparedIntentRecord(
            intent: intent,
            cancelledReason: nil
        )
        return intent
    }

    public func preparedIntentCancellationReason(
        id: String,
        accountID: String
    ) -> String? {
        guard let record = preparedIntents[id],
              record.intent.accountID == accountID else {
            return nil
        }
        return record.cancelledReason
    }

    public func discardPreparedIntent(id: String, accountID: String) {
        guard preparedIntents[id]?.intent.accountID == accountID else { return }
        preparedIntents.removeValue(forKey: id)
    }

    /// Atomically re-checks unresolved work and turns a prepared intent into
    /// the durable journal row. Call only after capability is verified.
    public func reservePreparedIntent(
        id: String,
        accountID: String,
        capabilityVersion: Int?
    ) throws -> PendingLogSubmission {
        guard let record = preparedIntents[id],
              record.intent.accountID == accountID else {
            throw LogSubmissionStoreError.preparedIntentUnavailable
        }
        if let reason = record.cancelledReason {
            throw LogSubmissionStoreError.preparedIntentCancelled(reason)
        }
        if now().timeIntervalSince(record.intent.createdAt) > 300 {
            preparedIntents.removeValue(forKey: id)
            throw LogSubmissionStoreError.preparedIntentUnavailable
        }
        let entries = try loadEntries(accountID: accountID)
        let key = record.intent.request.idempotencyKey
        let hasLaterOverlap = entries.contains { entry in
            guard entry.idempotencyKey != key,
                  !retryBlockedIDs.contains(entry.id),
                  entry.state != .rejected,
                  entry.createdAt >= record.intent.createdAt else {
                return false
            }
            return record.intent.drafts.contains { draft in
                entry.allDrafts.contains {
                    $0.item == draft.item && $0.date == draft.date
                }
            }
        }
        if hasLaterOverlap {
            throw LogSubmissionStoreError.preparedIntentPending
        }
        let hasOtherUnresolved = entries.contains { entry in
            guard entry.idempotencyKey != key,
                  !retryBlockedIDs.contains(entry.id) else { return false }
            let overlapping = record.intent.drafts.contains { draft in
                entry.allDrafts.contains {
                    $0.item == draft.item && $0.date == draft.date
                }
            }
            guard overlapping else { return false }
            switch entry.state {
            case .inFlight, .uncertain, .conflicted, .serverChanged,
                 .reconciliationOnly:
                return true
            case .succeeded, .rejected, .invalidated:
                return false
            }
        }
        if hasOtherUnresolved {
            throw LogSubmissionStoreError.preparedIntentPending
        }
        let entry = try reserve(
            accountID: accountID,
            summary: record.intent.summary,
            drafts: record.intent.drafts,
            request: record.intent.request,
            itemNames: record.intent.itemNames,
            capabilityVersion: capabilityVersion
        )
        preparedIntents.removeValue(forKey: id)
        return entry
    }

    private func cancelPreparedIntents(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate,
        reason: String
    ) -> Bool {
        var cancelled = false
        for (id, record) in preparedIntents where record.intent.accountID == accountID {
            let matches = record.intent.drafts.contains {
                $0.item == item && $0.date == date
            }
            guard matches else { continue }
            var updated = record
            updated.cancelledReason = updated.cancelledReason ?? reason
            preparedIntents[id] = updated
            cancelled = true
        }
        return cancelled
    }

    private static func matches(
        _ intent: PreparedLogSubmissionIntent,
        drafts: [LogSubmissionDraft],
        request: LogSubmissionRequest
    ) -> Bool {
        intent.drafts == drafts
            && intent.request.requestPath == request.requestPath
            && intent.request.idempotencyKey == request.idempotencyKey
            && intent.request.body == request.body
            && intent.request.baseURLString == request.baseURLString
    }

    @discardableResult
    public func reserve(
        accountID: String,
        foodName: String,
        draft: LogSubmissionDraft,
        request: FoodLogCreateRequest,
        body: Data,
        capabilityVersion: Int? = nil
    ) throws -> PendingLogSubmission {
        guard let key = request.idempotencyKey, !key.isEmpty else {
            throw LogSubmissionStoreError.invalidRequest
        }
        return try reserve(
            accountID: accountID,
            summary: foodName,
            drafts: [draft],
            request: LogSubmissionRequest(
                requestPath: "/api/logs",
                idempotencyKey: key,
                body: body,
                baseURLString: request.baseURLString
            ),
            capabilityVersion: capabilityVersion
        )
    }

    /// Reserves one logical operation. Batch drafts preserve their original
    /// order so the stored body and the backend replay describe the same
    /// operation.
    @discardableResult
    public func reserve(
        accountID: String,
        summary: String,
        drafts: [LogSubmissionDraft],
        request: LogSubmissionRequest,
        itemNames: [String]? = nil,
        capabilityVersion: Int? = nil
    ) throws -> PendingLogSubmission {
        let key = try Self.validateReservation(
            accountID: accountID,
            drafts: drafts,
            request: request
        )

        var entries = try loadEntries(accountID: accountID)
        if let existing = entries.first(where: { $0.idempotencyKey == key }) {
            guard existing.matchesRequest(request, drafts: drafts) else {
                throw LogSubmissionStoreError.idempotencyConflict
            }
            return existing
        }
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
            foodName: summary,
            draft: drafts[0],
            batchDrafts: drafts.count > 1 ? drafts : nil,
            itemNames: itemNames,
            capabilityVersion: capabilityVersion,
            idempotencyKey: key,
            body: request.body,
            requestSHA256: LogSubmissionRequest.bodySHA256(request.body),
            baseURLString: request.baseURLString ?? "",
            requestPath: request.requestPath,
            state: .inFlight,
            attemptCount: 0,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        guard Self.isValid(entry) else {
            throw LogSubmissionStoreError.invalidRequest
        }
        entries.append(entry)
        try persistAndCache(entries, accountID: accountID)
        return entry
    }

    private static func validateReservation(
        accountID: String,
        drafts: [LogSubmissionDraft],
        request: LogSubmissionRequest
    ) throws -> String {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogSubmissionStoreError.invalidAccount
        }
        guard !drafts.isEmpty, drafts.count <= 50 else {
            throw LogSubmissionStoreError.invalidRequest
        }
        guard allowedPaths.contains(request.requestPath) else {
            throw LogSubmissionStoreError.invalidRequest
        }
        guard routeMatches(path: request.requestPath, drafts: drafts) else {
            throw LogSubmissionStoreError.invalidRequest
        }
        let key = request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.count <= 128,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw LogSubmissionStoreError.invalidRequest
        }
        guard request.body.count <= maxBodyBytes else {
            throw LogSubmissionStoreError.bodyTooLarge
        }
        return key
    }

    /// Atomically claims the single live send slot for this journal row.
    /// Returns false when another task in this process already owns the POST,
    /// so duplicate handoffs produce one request and a deterministic already
    /// in-flight result.
    public func claimSubmission(id: String, accountID: String) throws -> Bool {
        guard !liveSubmissionIDs.contains(id) else { return false }
        liveSubmissionIDs.insert(id)
        var marked = false
        do {
            try update(id: id, accountID: accountID) { entry in
                guard entry.state != .succeeded,
                      entry.state != .conflicted,
                      entry.state != .invalidated,
                      entry.state != .serverChanged,
                      entry.state != .reconciliationOnly,
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
            liveSubmissionIDs.remove(id)
        }
        return marked
    }

    public func abandonLiveSubmission(id: String) {
        liveSubmissionIDs.remove(id)
    }

    @discardableResult
    public func markInFlight(id: String, accountID: String) throws -> Bool {
        try claimSubmission(id: id, accountID: accountID)
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
            entry.resultLogs = nil
            entry.replayed = replayed
            entry.lastStatus = replayed ? 200 : 201
            entry.lastMessage = nil
            entry.updatedAt = self.now()
        }
    }

    /// Records every log returned by a batch or ad-hoc replay in original
    /// order. The first log remains the compatibility result for the banner.
    public func markSucceeded(
        id: String,
        accountID: String,
        logs: [LogSubmissionCreatedLog],
        replayed: Bool
    ) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            let first = logs.first
            entry.state = .succeeded
            entry.body = nil
            entry.resultLogID = first?.id
            entry.resultDate = first?.date
            entry.resultMealSlot = first?.mealSlot
            entry.resultLogs = logs
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

    /// No request was sent because the configured server identity changed.
    /// Keep the frozen body and key for inspection, but never replay it against
    /// a different host.
    public func markServerChanged(
        id: String,
        accountID: String,
        message: String
    ) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            entry.state = .serverChanged
            entry.lastMessage = message
            entry.updatedAt = self.now()
        }
    }

    /// Terminal for replay purposes but visible for explicit reconciliation.
    /// The exact body is removed so no recovery path can accidentally send it.
    public func markReconciliationOnly(
        id: String,
        accountID: String,
        message: String
    ) throws {
        defer { liveSubmissionIDs.remove(id) }
        try update(id: id, accountID: accountID) { entry in
            guard entry.state != .succeeded,
                  entry.state != .invalidated,
                  !self.retryBlockedIDs.contains(entry.id)
            else { return }
            entry.state = .reconciliationOnly
            entry.body = nil
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
        try invalidateUnresolved(
            accountID: accountID,
            item: .product(id: foodID),
            date: date,
            reason: reason
        )
    }

    /// Invalidates every unresolved operation that contains the deleted item.
    /// A batch is invalidated as a whole because any replay could recreate the
    /// removed log and its sibling rows with a fresh operation.
    @discardableResult
    public func invalidateUnresolved(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate,
        reason: String
    ) throws -> [PendingLogSubmission] {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogSubmissionStoreError.invalidAccount
        }
        _ = cancelPreparedIntents(
            accountID: accountID,
            item: item,
            date: date,
            reason: reason
        )
        let entries = try loadEntries(accountID: accountID)
        let matching = Self.unresolvedMatches(in: entries, item: item, date: date)
        return try invalidate(
            entries: entries,
            matching: matching,
            accountID: accountID,
            reason: reason
        )
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
        try blockBeforeDeleting(
            accountID: accountID,
            item: .product(id: foodID),
            date: date,
            reason: reason
        )
    }

    @discardableResult
    public func blockBeforeDeleting(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate,
        reason: String
    ) throws -> [PendingLogSubmission] {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogSubmissionStoreError.invalidAccount
        }
        let entries = try loadEntries(accountID: accountID)
        let matching = Self.unresolvedMatches(in: entries, item: item, date: date)
        guard !matching.contains(where: { self.liveSubmissionIDs.contains($0.id) }) else {
            throw LogSubmissionStoreError.submissionInFlight
        }
        _ = cancelPreparedIntents(
            accountID: accountID,
            item: item,
            date: date,
            reason: reason
        )
        guard !matching.isEmpty else { return [] }
        return try invalidate(
            entries: entries,
            matching: matching,
            accountID: accountID,
            reason: reason
        )
    }

    private static func unresolvedMatches(
        in entries: [PendingLogSubmission],
        item: LogSubmissionItem,
        date: LocalDiaryDate
    ) -> [PendingLogSubmission] {
        entries.filter { entry in
            entry.allDrafts.contains { $0.item == item && $0.date == date }
                && (entry.state == .inFlight
                    || entry.state == .uncertain
                    || entry.state == .conflicted
                    || entry.state == .serverChanged
                    || entry.state == .reconciliationOnly)
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
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              (1...Self.schemaVersion).contains(envelope.schemaVersion),
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
        var changed = envelope.schemaVersion < Self.schemaVersion
        let timestamp = now()
        for index in entries.indices where entries[index].state == .inFlight {
            entries[index].state = .uncertain
            entries[index].updatedAt = timestamp
            changed = true
        }
        let reconciliationMessage = String(localized: "submission.reconciliationOnly")
        if envelope.schemaVersion < 2 {
            for index in entries.indices {
                switch entries[index].state {
                case .inFlight, .uncertain, .conflicted, .serverChanged:
                    entries[index].state = .reconciliationOnly
                    entries[index].body = nil
                    entries[index].lastMessage = reconciliationMessage
                    entries[index].updatedAt = timestamp
                    changed = true
                case .succeeded, .rejected, .invalidated, .reconciliationOnly:
                    break
                }
            }
        } else {
            for index in entries.indices {
                guard entries[index].capabilityVersion != 2 else { continue }
                switch entries[index].state {
                case .inFlight, .uncertain, .conflicted, .serverChanged:
                    entries[index].state = .reconciliationOnly
                    entries[index].body = nil
                    entries[index].lastMessage = reconciliationMessage
                    entries[index].updatedAt = timestamp
                    changed = true
                case .succeeded, .rejected, .invalidated, .reconciliationOnly:
                    break
                }
            }
        }
        for index in entries.indices where entries[index].requestSHA256 == nil {
            if let body = entries[index].body {
                entries[index].requestSHA256 = LogSubmissionRequest.bodySHA256(body)
                changed = true
            }
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
            let data = try encoder.encode(
                Envelope(schemaVersion: Self.schemaVersion, entries: entries)
            )
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
              allowedPaths.contains(entry.requestPath),
              !entry.allDrafts.isEmpty,
              entry.allDrafts.count <= 50,
              entry.allDrafts.allSatisfy({ isValid($0) })
        else { return false }

        switch entry.requestPath {
        case LogSubmissionRoute.batch.requestPath:
            guard entry.allDrafts.count >= 2 else { return false }
            guard entry.allDrafts.allSatisfy({
                if case .adHoc = $0.item { return false }
                return true
            }) else { return false }
        case LogSubmissionRoute.adHoc.requestPath:
            guard entry.allDrafts.count == 1 else { return false }
            guard case .adHoc = entry.draft.item else { return false }
        default:
            guard entry.allDrafts.count == 1 else { return false }
            switch entry.draft.item {
            case .product, .meal:
                break
            case .adHoc:
                return false
            }
        }

        if let body = entry.body, body.count > maxBodyBytes {
            return false
        }
        switch entry.state {
        case .inFlight, .uncertain, .serverChanged:
            if entry.body == nil { return false }
        case .succeeded, .rejected, .conflicted, .invalidated, .reconciliationOnly:
            break
        }
        return true
    }

    private static func routeMatches(
        path: String,
        drafts: [LogSubmissionDraft]
    ) -> Bool {
        switch path {
        case LogSubmissionRoute.batch.requestPath:
            guard drafts.count >= 2 else { return false }
            return drafts.allSatisfy {
                if case .adHoc = $0.item { return false }
                return true
            }
        case LogSubmissionRoute.adHoc.requestPath:
            guard drafts.count == 1 else { return false }
            if case .adHoc = drafts[0].item { return true }
            return false
        case LogSubmissionRoute.single.requestPath:
            guard drafts.count == 1 else { return false }
            if case .adHoc = drafts[0].item { return false }
            return true
        default:
            return false
        }
    }

    private static func isValid(_ draft: LogSubmissionDraft) -> Bool {
        guard parsePositiveLogAmount(draft.amount) != nil,
              !draft.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.timeZone.isEmpty
        else { return false }
        switch draft.item {
        case .product(let id), .meal(let id):
            return !id.isEmpty
        case .adHoc(let name, _):
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func shouldPrune(_ entry: PendingLogSubmission, now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.updatedAt)
        switch entry.state {
        case .succeeded:
            return age > 60 * 60
        case .rejected, .conflicted, .invalidated, .reconciliationOnly:
            return age > 7 * 24 * 60 * 60
        case .uncertain:
            return age > 30 * 24 * 60 * 60
        case .serverChanged:
            return age > 30 * 24 * 60 * 60
        case .inFlight:
            return false
        }
    }
}
