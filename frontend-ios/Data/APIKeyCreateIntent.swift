// Durable, non-secret write-ahead intent for personal API-key creation.
//
// A create request is not idempotent. If the app dies or the session changes
// after the server may have committed the key, the secret is unrecoverable.
// This record lets the next list load warn about that possibility. It contains
// only metadata: never a token, request body, or secret.
//
// A corrupt record also gets a durable quarantine marker. It can only be reset
// by an explicit user action after metadata review, using the file identity
// captured when the corruption was observed. The identity CAS prevents a stale
// window from removing a newer valid intent.

import CryptoKit
import Foundation

public struct APIKeyCreateIntentFileIdentity: Codable, Equatable, Sendable {
    public let accountID: String
    public let digest: String

    public init(accountID: String, digest: String) {
        self.accountID = accountID
        self.digest = digest
    }
}

public struct APIKeyCreateIntent: Codable, Equatable, Sendable {
    public let accountID: String
    public let revision: String
    public let name: String
    public let scope: APIKeyCreatableScope
    public let expiresInDays: Int?
    public let startedAt: Date
    public let baselineKeyIDs: [String]

    public init(
        accountID: String,
        revision: String = UUID().uuidString.lowercased(),
        name: String,
        scope: APIKeyCreatableScope,
        expiresInDays: Int?,
        startedAt: Date,
        baselineKeyIDs: [String]
    ) {
        self.accountID = accountID
        self.revision = revision
        self.name = name
        self.scope = scope
        self.expiresInDays = expiresInDays
        self.startedAt = startedAt
        self.baselineKeyIDs = Array(Set(baselineKeyIDs)).sorted()
    }

    /// Keys not present immediately before the interrupted create. This is
    /// deliberately conservative: another window's key is also surfaced for
    /// explicit review rather than auto-revoked.
    public func potentialOrphanKeys(from keys: [APIKey]) -> [APIKey] {
        let baseline = Set(baselineKeyIDs)
        return keys.filter { !baseline.contains($0.id) }
    }
}

public enum APIKeyCreateIntentStoreError: Error, Equatable, Sendable {
    case invalidAccount
    case unavailable
    /// Another window or process already has an unresolved create.
    case alreadyPending
    /// The record exists but cannot be decoded, or a durable quarantine marker
    /// is present. Creation stays blocked until an explicit reset.
    case unreadable(APIKeyCreateIntentFileIdentity)
    /// A stale window tried to clear a newer intent.
    case staleRevision
    /// The quarantined file changed or a newer valid intent appeared.
    case staleReset
    case persistence
}

public protocol APIKeyCreateIntentStoring: Sendable {
    func load(accountID: String) throws -> APIKeyCreateIntent?
    func saveIfAbsent(_ intent: APIKeyCreateIntent) throws
    /// Compare-and-swap by revision. A missing record is already clear.
    func clear(accountID: String, revision: String) throws
    /// Explicit destructive recovery for an unreadable/quarantined record.
    /// The captured file identity must still match.
    func resetUnreadable(
        accountID: String,
        expectedIdentity: APIKeyCreateIntentFileIdentity
    ) throws
}

/// Account-scoped JSON file with process-wide serialization and revision CAS.
/// Multiple windows must use `shared` (the view model default), which keeps
/// their read/modify/write operations ordered.
public final class APIKeyCreateIntentStore: APIKeyCreateIntentStoring, @unchecked Sendable {
    public static let shared = APIKeyCreateIntentStore()

    private static let processLock = NSLock()
    private static let schemaVersion = 1
    private static let markerSchemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let intent: APIKeyCreateIntent
    }

    private struct QuarantineMarker: Codable {
        let schemaVersion: Int
        let identity: APIKeyCreateIntentFileIdentity
        let quarantinedAt: Date
    }

    private struct LedgerRecord: Codable {
        let schemaVersion: Int
        let accountID: String
        let revision: String
        let identity: APIKeyCreateIntentFileIdentity
        let updatedAt: Date
    }

    public let directoryURL: URL

    /// An independent, bounded account ledger outside the intent directory.
    /// It keeps a non-secret fallback if the quarantine marker cannot be
    /// written because the intent directory itself is unwritable.
    private var ledgerDirectoryURL: URL {
        directoryURL.deletingLastPathComponent().appendingPathComponent(
            "\(directoryURL.lastPathComponent)-ledger",
            isDirectory: true
        )
    }

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
                .appendingPathComponent("APIKeyIntents", isDirectory: true)
        }
    }

    public func load(accountID: String) throws -> APIKeyCreateIntent? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try validate(accountID: accountID)
        return try loadUnlocked(accountID: accountID)
    }

    public func saveIfAbsent(_ intent: APIKeyCreateIntent) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try validate(accountID: intent.accountID)
        if try loadUnlocked(accountID: intent.accountID) != nil {
            throw APIKeyCreateIntentStoreError.alreadyPending
        }

        try createDirectoryIfNeeded(directoryURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                Envelope(schemaVersion: Self.schemaVersion, intent: intent)
            )
        } catch {
            throw APIKeyCreateIntentStoreError.persistence
        }

        // Write the independent ledger before the intent file. If either write
        // fails, no POST is sent. A leftover ledger is a fail-closed false
        // positive, never a false grant.
        let identity = makeIdentity(accountID: intent.accountID, data: data)
        let ledger = LedgerRecord(
            schemaVersion: Self.schemaVersion,
            accountID: intent.accountID,
            revision: intent.revision,
            identity: identity,
            updatedAt: Date()
        )
        do {
            try writeLedger(ledger)
        } catch {
            throw APIKeyCreateIntentStoreError.persistence
        }

        do {
            try data.write(to: fileURL(accountID: intent.accountID), options: [.atomic])
            hardenFile(at: fileURL(accountID: intent.accountID))
        } catch {
            try? removeIfPresent(ledgerURL(accountID: intent.accountID))
            throw APIKeyCreateIntentStoreError.persistence
        }
    }

    public func clear(accountID: String, revision: String) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try validate(accountID: accountID)
        let ledger = try loadLedgerUnlocked(accountID: accountID)
        guard let current = try loadUnlocked(accountID: accountID) else {
            return
        }
        guard current.revision == revision else {
            throw APIKeyCreateIntentStoreError.staleRevision
        }
        if let ledger, ledger.revision != revision {
            throw APIKeyCreateIntentStoreError.staleRevision
        }
        do {
            try removeIfPresent(fileURL(accountID: accountID))
            try removeIfPresent(markerURL(accountID: accountID))
            try removeIfPresent(ledgerURL(accountID: accountID))
        } catch {
            throw APIKeyCreateIntentStoreError.persistence
        }
    }

    public func resetUnreadable(
        accountID: String,
        expectedIdentity: APIKeyCreateIntentFileIdentity
    ) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try validate(accountID: accountID)
        guard expectedIdentity.accountID == accountID else {
            throw APIKeyCreateIntentStoreError.staleReset
        }

        let marker = try loadMarkerUnlocked(accountID: accountID)
        let ledger = try loadLedgerUnlocked(accountID: accountID)
        let currentIdentity = try identityUnlocked(accountID: accountID)

        let identities = [marker?.identity, ledger?.identity, currentIdentity]
            .compactMap { $0 }
        if identities.isEmpty {
            return
        }
        guard identities.allSatisfy({ $0 == expectedIdentity }) else {
            // A newer file, marker, or ledger replaced the reviewed record.
            throw APIKeyCreateIntentStoreError.staleReset
        }

        try removeIfPresent(fileURL(accountID: accountID))
        try removeIfPresent(markerURL(accountID: accountID))
        try removeIfPresent(ledgerURL(accountID: accountID))
    }

    // MARK: - Internals (caller holds processLock)

    private func loadUnlocked(accountID: String) throws -> APIKeyCreateIntent? {
        let ledger = try loadLedgerUnlocked(accountID: accountID)
        let marker = try loadMarkerUnlocked(accountID: accountID)
        let url = fileURL(accountID: accountID)
        let fileExists = FileManager.default.fileExists(atPath: url.path)

        if let marker {
            if fileExists {
                let current = try identityUnlocked(accountID: accountID)
                guard current == marker.identity else {
                    // Do not reveal or trust a changed file while a durable
                    // quarantine is installed. The stale reset path protects it.
                    throw APIKeyCreateIntentStoreError.unreadable(marker.identity)
                }
            }
            throw APIKeyCreateIntentStoreError.unreadable(marker.identity)
        }

        guard fileExists else {
            if let ledger {
                throw APIKeyCreateIntentStoreError.unreadable(ledger.identity)
            }
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard let identity = try identityUnlocked(accountID: accountID) else {
                throw APIKeyCreateIntentStoreError.unavailable
            }
            persistQuarantine(identity)
            throw APIKeyCreateIntentStoreError.unreadable(identity)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion,
                  envelope.intent.accountID == accountID else {
                let identity = makeIdentity(accountID: accountID, data: data)
                persistQuarantine(identity)
                throw APIKeyCreateIntentStoreError.unreadable(identity)
            }
            return envelope.intent
        } catch let error as APIKeyCreateIntentStoreError {
            throw error
        } catch {
            let identity = makeIdentity(accountID: accountID, data: data)
            persistQuarantine(identity)
            throw APIKeyCreateIntentStoreError.unreadable(identity)
        }
    }

    private func loadMarkerUnlocked(accountID: String) throws -> QuarantineMarker? {
        let url = markerURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let marker = try decoder.decode(QuarantineMarker.self, from: data)
            guard marker.schemaVersion == Self.markerSchemaVersion,
                  marker.identity.accountID == accountID else {
                throw APIKeyCreateIntentStoreError.unavailable
            }
            return marker
        } catch let error as APIKeyCreateIntentStoreError {
            throw error
        } catch {
            throw APIKeyCreateIntentStoreError.unavailable
        }
    }

    private func loadLedgerUnlocked(accountID: String) throws -> LedgerRecord? {
        let url = ledgerURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let ledger = try decoder.decode(LedgerRecord.self, from: data)
            guard ledger.schemaVersion == Self.schemaVersion,
                  ledger.accountID == accountID,
                  ledger.identity.accountID == accountID else {
                throw APIKeyCreateIntentStoreError.unavailable
            }
            return ledger
        } catch let error as APIKeyCreateIntentStoreError {
            throw error
        } catch {
            throw APIKeyCreateIntentStoreError.unavailable
        }
    }

    private func writeLedger(_ ledger: LedgerRecord) throws {
        try createDirectoryIfNeeded(ledgerDirectoryURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(ledger)
            let url = ledgerURL(accountID: ledger.accountID)
            try data.write(to: url, options: [.atomic])
            hardenFile(at: url)
        } catch {
            throw APIKeyCreateIntentStoreError.persistence
        }
    }

    /// The marker is first-choice recovery data; the independent ledger is the
    /// durable fallback when the intent directory itself is unwritable.
    private func persistQuarantine(_ identity: APIKeyCreateIntentFileIdentity) {
        try? writeMarker(identity)
        let existingRevision = (try? loadLedgerUnlocked(
            accountID: identity.accountID
        ))?.revision ?? ""
        let ledger = LedgerRecord(
            schemaVersion: Self.schemaVersion,
            accountID: identity.accountID,
            revision: existingRevision,
            identity: identity,
            updatedAt: Date()
        )
        try? writeLedger(ledger)
    }

    private func writeMarker(_ identity: APIKeyCreateIntentFileIdentity) throws {
        try createDirectoryIfNeeded(directoryURL)
        let marker = QuarantineMarker(
            schemaVersion: Self.markerSchemaVersion,
            identity: identity,
            quarantinedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        let url = markerURL(accountID: identity.accountID)
        try data.write(to: url, options: [.atomic])
        hardenFile(at: url)
    }

    /// SHA-256 of the exact stored bytes. If the bytes cannot be read, a stable
    /// metadata descriptor is used so the explicit reset still has a CAS token.
    private func identityUnlocked(
        accountID: String
    ) throws -> APIKeyCreateIntentFileIdentity? {
        let url = fileURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        if let data = try? Data(contentsOf: url) {
            return makeIdentity(accountID: accountID, data: data)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else {
            throw APIKeyCreateIntentStoreError.unavailable
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let descriptor = "file-attrs|\(size)|\(modified)"
        return makeIdentity(accountID: accountID, data: Data(descriptor.utf8))
    }

    private func makeIdentity(
        accountID: String,
        data: Data
    ) -> APIKeyCreateIntentFileIdentity {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return APIKeyCreateIntentFileIdentity(accountID: accountID, digest: digest)
    }

    private func validate(accountID: String) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIKeyCreateIntentStoreError.invalidAccount
        }
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = url
            try? directory.setResourceValues(values)
        } catch {
            throw APIKeyCreateIntentStoreError.unavailable
        }
    }

    private func hardenFile(at url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw APIKeyCreateIntentStoreError.persistence
        }
    }

    private func fileURL(accountID: String) -> URL {
        directoryURL.appendingPathComponent(
            "api-key-intent-\(encodedAccount(accountID)).json"
        )
    }

    private func markerURL(accountID: String) -> URL {
        directoryURL.appendingPathComponent(
            "api-key-intent-\(encodedAccount(accountID)).quarantined"
        )
    }

    private func ledgerURL(accountID: String) -> URL {
        ledgerDirectoryURL.appendingPathComponent(
            "api-key-intent-ledger-\(encodedAccount(accountID)).json"
        )
    }

    private func encodedAccount(_ accountID: String) -> String {
        Data(accountID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
