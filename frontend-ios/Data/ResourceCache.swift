/// A tiny, pure value-type cache for request/response resources.
///
/// `ResourceCache` owns the state machine for one resource family: whether a
/// keyed resource has not been requested, is currently in flight behind an
/// opaque token, or has settled with a success or failure. It deliberately has
/// no reference state, no persistence, and no service calls; callers compose it
/// into their own models.
///
/// This is not TCA's `Store`. TCA's `Store` runs reducers and effects for
/// application state. `ResourceCache` is only the request-token bookkeeping that
/// keeps a stale response from overwriting newer data.

/// Session-wide reset across all resource families is an integration
/// responsibility: the session root must replace or reset every family cache
/// together at the boundary. This primitive is one family's pure value
/// bookkeeping, not a dependency service, and intentionally does not provide an
/// aggregate wrapper.
import Foundation

public struct ResourceCache<Key: Hashable, Value, Failure: Error> {
    /// The lifecycle of one keyed resource.
    public enum Entry {
        case notRequested
        case inFlight(RequestToken)
        case settled(Result<Value, Failure>)
    }

    /// An opaque identity for one in-flight request.
    ///
    /// The payload is intentionally not public: callers cannot mint a token for a
    /// request that was never issued, nor pair one resource's generation with
    /// another resource's request id. Equality is still available so a cache can
    /// recognize the token it issued.
    public struct RequestToken: Equatable, Hashable, Sendable {
        fileprivate let issuanceID: UUID
        fileprivate let generation: Int
        fileprivate let requestID: Int

        fileprivate init(issuanceID: UUID, generation: Int, requestID: Int) {
            self.issuanceID = issuanceID
            self.generation = generation
            self.requestID = requestID
        }
    }

    /// Outcome of attempting to settle an in-flight request.
    public enum Settlement {
        case accepted(ResourceCache)
        case rejected
    }

    public let generation: Int

    private let issuanceID: UUID

    private let nextRequestID: Int
    private let entries: [Key: Entry]

    public init() {
        self.generation = 0
        self.issuanceID = UUID()
        self.nextRequestID = 0
        self.entries = [:]
    }

    private init(issuanceID: UUID, generation: Int, nextRequestID: Int, entries: [Key: Entry]) {
        self.generation = generation
        self.issuanceID = issuanceID
        self.nextRequestID = nextRequestID
        self.entries = entries
    }

    // MARK: - Reads

    public func entry(for key: Key) -> Entry {
        entries[key] ?? .notRequested
    }

    public func cached(_ key: Key) -> Result<Value, Failure>? {
        guard case .settled(let result) = entry(for: key) else {
            return nil
        }
        return result
    }

    // MARK: - Requests

    /// Issues a request only when the resource is `.notRequested`.
    ///
    /// A second call while the resource is in flight or settled returns `nil`,
    /// so duplicate requests cannot be issued for the same live entry.
    public func request(_ key: Key) -> (ResourceCache, RequestToken)? {
        guard case .notRequested = entry(for: key) else {
            return nil
        }

        let requestID = nextRequestID + 1
        let token = RequestToken(issuanceID: issuanceID, generation: generation, requestID: requestID)
        var updatedEntries = entries
        updatedEntries[key] = .inFlight(token)

        return (
            ResourceCache(
                issuanceID: issuanceID,
                generation: generation,
                nextRequestID: requestID,
                entries: updatedEntries
            ),
            token
        )
    }

    // MARK: - Settlement

    /// Redeems a token against the exact in-flight request in the current
    /// generation.
    ///
    /// Returns `.accepted` only when the key is still in flight and both the
    /// request id and session generation match. Duplicate completions,
    /// invalidated entries, seeded entries, superseded request ids, and old
    /// generations are rejected.
    public func settle(
        _ key: Key,
        token: RequestToken,
        result: Result<Value, Failure>
    ) -> Settlement {
        guard case .inFlight(let pendingToken) = entry(for: key),
              pendingToken == token,
              pendingToken.issuanceID == issuanceID,
              pendingToken.generation == generation,
              pendingToken.requestID == token.requestID else {
            return .rejected
        }

        var updatedEntries = entries
        updatedEntries[key] = .settled(result)

        return .accepted(
            ResourceCache(
                issuanceID: issuanceID,
                generation: generation,
                nextRequestID: nextRequestID,
                entries: updatedEntries
            )
        )
    }

    /// Convenience for callers that prefer an optional updated cache.
    public func settling(
        _ key: Key,
        token: RequestToken,
        result: Result<Value, Failure>
    ) -> ResourceCache? {
        switch settle(key, token: token, result: result) {
        case .accepted(let cache):
            return cache
        case .rejected:
            return nil
        }
    }

    // MARK: - Mutations

    /// Seeds a settled success without an in-flight request.
    public func seed(_ key: Key, value: Value) -> ResourceCache {
        var updatedEntries = entries
        updatedEntries[key] = .settled(.success(value))
        return ResourceCache(
            issuanceID: issuanceID,
            generation: generation,
            nextRequestID: nextRequestID,
            entries: updatedEntries
        )
    }

    /// Makes a resource requestable again and rejects any prior token.
    public func invalidate(_ key: Key) -> ResourceCache {
        var updatedEntries = entries
        updatedEntries[key] = .notRequested
        return ResourceCache(
            issuanceID: issuanceID,
            generation: generation,
            nextRequestID: nextRequestID,
            entries: updatedEntries
        )
    }

    /// Removes every entry whose key satisfies `predicate`.
    ///
    /// This is the family-clearing primitive: an all-date latest-slots cache can
    /// clear every date key with `invalidateWhere { _ in true }`, while a more
    /// selective predicate can target one family or date range.
    public func invalidateWhere(_ predicate: (Key) -> Bool) -> ResourceCache {
        let updatedEntries = entries.filter { key, _ in
            !predicate(key)
        }
        return ResourceCache(
            issuanceID: issuanceID,
            generation: generation,
            nextRequestID: nextRequestID,
            entries: updatedEntries
        )
    }

    /// Removes all entries.
    public func clearAll() -> ResourceCache {
        invalidateWhere { _ in true }
    }

    // MARK: - Session generation

    /// Moves to a new session generation and clears every entry.
    ///
    /// An in-flight token from the previous generation can no longer settle,
    /// even if its request id is later reused.
    public func reset() -> ResourceCache {
        withGeneration(generation + 1)
    }

    // MARK: - Internal helpers

    private func withGeneration(_ generation: Int) -> ResourceCache {
        ResourceCache(
            issuanceID: issuanceID,
            generation: generation,
            nextRequestID: 0,
            entries: [:]
        )
    }
}

extension ResourceCache: Equatable where Key: Equatable, Value: Equatable, Failure: Equatable {}

extension ResourceCache.Entry: Equatable where Value: Equatable, Failure: Equatable {}
