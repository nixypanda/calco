import XCTest
@testable import CalCo

enum ResourceCacheTestFailure: Error, Equatable {
    case server
}

typealias TestResourceCache = ResourceCache<String, Int, ResourceCacheTestFailure>

final class ResourceCacheTests: XCTestCase {
    private let key = "2024-01-01"
    private let otherKey = "2024-01-02"

    func testRequestIsIssuedOnce() {
        let cache = TestResourceCache()

        guard let (inFlight, token) = cache.request(key) else {
            return XCTFail("the first request should have been issued")
        }

        XCTAssertNil(inFlight.cached(key))
        XCTAssertNil(inFlight.request(key))

        guard case .accepted(let settled) = inFlight.settle(key, token: token, result: .success(42)) else {
            return XCTFail("the live token should settle")
        }

        XCTAssertEqual(settled.cached(key), .success(42))
        XCTAssertNil(settled.request(key))
    }

    func testTokenGuardsRequestIDAndGeneration() {
        let cache = TestResourceCache()

        guard let (firstInFlight, firstToken) = cache.request(key) else {
            return XCTFail("first request should have been issued")
        }
        guard let (bothInFlight, secondToken) = firstInFlight.request(otherKey) else {
            return XCTFail("second independent request should have been issued")
        }
        guard let (afterReset, liveToken) = bothInFlight.reset().request(key) else {
            return XCTFail("request after reset should have been issued")
        }

        // A different resource's token cannot settle this resource.
        XCTAssertTrue(isRejected(bothInFlight.settle(key, token: secondToken, result: .success(1))))
        // This resource's old token cannot settle another resource.
        XCTAssertTrue(isRejected(bothInFlight.settle(otherKey, token: firstToken, result: .success(1))))
        // A token from before reset cannot settle the reset-generation request.
        XCTAssertTrue(isRejected(afterReset.settle(key, token: firstToken, result: .success(1))))

        guard case .accepted(let settled) = afterReset.settle(key, token: liveToken, result: .success(7)) else {
            return XCTFail("the live post-reset token should settle")
        }
        XCTAssertEqual(settled.cached(key), .success(7))
    }

    func testIndependentCachesRejectForeignTokens() {
        let cacheA = TestResourceCache()
        let cacheB = TestResourceCache()

        guard let (inFlightA, tokenA) = cacheA.request(key) else {
            return XCTFail("cache A request should have been issued")
        }
        guard let (inFlightB, tokenB) = cacheB.request(key) else {
            return XCTFail("cache B request should have been issued")
        }

        // Fresh independent caches can have identical generation/request ids.
        XCTAssertTrue(isRejected(inFlightB.settle(key, token: tokenA, result: .success(1))))
        XCTAssertTrue(isRejected(inFlightA.settle(key, token: tokenB, result: .success(1))))

        guard let (resetA, resetToken) = inFlightA.reset().request(key) else {
            return XCTFail("reset cache A request should have been issued")
        }

        // Resetting generation rejects the old token even with the same namespace.
        XCTAssertTrue(isRejected(resetA.settle(key, token: tokenA, result: .success(1))))

        guard case .accepted(let settled) = resetA.settle(key, token: resetToken, result: .success(2)) else {
            return XCTFail("reset cache A live token should settle")
        }
        XCTAssertEqual(settled.cached(key), .success(2))
    }

    func testCopiesPreserveIssuanceNamespace() {
        let cache = TestResourceCache()

        guard let (inFlight, token) = cache.request(key) else {
            return XCTFail("request should have been issued")
        }

        let copy = inFlight
        guard case .accepted(let settled) = copy.settle(key, token: token, result: .success(5)) else {
            return XCTFail("a value copy should preserve the issuance namespace")
        }

        XCTAssertEqual(settled.cached(key), .success(5))
    }

    func testFailedSettlementIsCachedAndInvalidatable() {
        let cache = TestResourceCache()

        guard let (inFlight, token) = cache.request(key) else {
            return XCTFail("the first request should have been issued")
        }

        guard case .accepted(let settled) = inFlight.settle(
            key,
            token: token,
            result: .failure(.server)
        ) else {
            return XCTFail("the live token should settle a failure")
        }

        XCTAssertEqual(settled.cached(key), .failure(.server))
        XCTAssertNil(settled.request(key))

        let retryable = settled.invalidate(key)
        XCTAssertNil(retryable.cached(key))
        XCTAssertNotNil(retryable.request(key))
    }

    func testSettleRejectsSupersededRequests() {
        let cache = TestResourceCache()

        guard let (inFlight, token) = cache.request(key) else {
            return XCTFail("the first request should have been issued")
        }
        guard case .accepted(let settled) = inFlight.settle(key, token: token, result: .success(1)) else {
            return XCTFail("the live token should settle")
        }

        let invalidated = inFlight.invalidate(key)
        let seeded = inFlight.seed(key, value: 99)

        XCTAssertTrue(isRejected(settled.settle(key, token: token, result: .success(2)))) // duplicate
        XCTAssertTrue(isRejected(invalidated.settle(key, token: token, result: .success(2)))) // invalidated
        XCTAssertTrue(isRejected(seeded.settle(key, token: token, result: .success(2)))) // seeded-superseded
    }

    func testResetClearsEverythingAndRejectsOldTokens() {
        let cache = TestResourceCache()
            .seed(key, value: 1)
            .seed(otherKey, value: 2)
            .seed("prefs", value: 3)

        guard let (withOutstanding, token) = cache.request("unseeded") else {
            return XCTFail("an unseeded resource should be requestable")
        }

        let resetCache = withOutstanding.reset()

        XCTAssertEqual(withOutstanding.cached(key), .success(1))
        XCTAssertEqual(withOutstanding.cached(otherKey), .success(2))
        XCTAssertEqual(withOutstanding.cached("prefs"), .success(3))

        XCTAssertNil(resetCache.cached(key))
        XCTAssertNil(resetCache.cached(otherKey))
        XCTAssertNil(resetCache.cached("prefs"))
        XCTAssertNil(resetCache.cached("unseeded"))
        XCTAssertTrue(isRejected(resetCache.settle("unseeded", token: token, result: .success(4))))

        XCTAssertNotNil(resetCache.request(key))
        XCTAssertNotNil(resetCache.request(otherKey))
        XCTAssertNotNil(resetCache.request("prefs"))
        XCTAssertNotNil(resetCache.request("unseeded"))
    }

    func testInvalidateWhereClearsOnlyMatchingFamily() {
        let seeded = TestResourceCache()
            .seed("goal:\(key)", value: 1)
            .seed("slots:\(key)", value: 2)
            .seed("logs:\(key)", value: 3)
            .seed("units", value: 4)

        let withoutGoals = seeded.invalidateWhere { entryKey in
            entryKey.hasPrefix("goal:")
        }
        let withoutSlots = seeded.invalidateWhere { entryKey in
            entryKey.hasPrefix("slots:")
        }

        XCTAssertNil(withoutGoals.cached("goal:\(key)"))
        XCTAssertEqual(withoutGoals.cached("slots:\(key)"), .success(2))
        XCTAssertEqual(withoutGoals.cached("logs:\(key)"), .success(3))
        XCTAssertEqual(withoutGoals.cached("units"), .success(4))

        XCTAssertEqual(withoutSlots.cached("goal:\(key)"), .success(1))
        XCTAssertNil(withoutSlots.cached("slots:\(key)"))
        XCTAssertEqual(withoutSlots.cached("logs:\(key)"), .success(3))
        XCTAssertEqual(withoutSlots.cached("units"), .success(4))
    }

    func testInvalidateWhereCanClearAllDateKeys() {
        let seeded = TestResourceCache()
            .seed("2024-01-01", value: 1)
            .seed("2024-01-02", value: 2)
            .seed("units", value: 3)

        let cleared = seeded.invalidateWhere { _ in true }

        XCTAssertNil(cleared.cached("2024-01-01"))
        XCTAssertNil(cleared.cached("2024-01-02"))
        XCTAssertNil(cleared.cached("units"))
        XCTAssertEqual(cleared.generation, seeded.generation)
    }

    func testResourceKeysAreIndependent() {
        let cache = TestResourceCache()

        guard let (afterFirst, firstToken) = cache.request(key) else {
            return XCTFail("first request should have been issued")
        }
        guard let (afterSecond, secondToken) = afterFirst.request(otherKey) else {
            return XCTFail("second request should have been issued")
        }
        guard let (allInFlight, _) = afterSecond.request("prefs") else {
            return XCTFail("prefs request should have been issued")
        }

        guard let settledBoth = allInFlight
            .settling(key, token: firstToken, result: .success(10))
            .flatMap({ $0.settling(otherKey, token: secondToken, result: .success(20)) }) else {
            return XCTFail("both live tokens should settle")
        }

        let withPrefs = settledBoth.seed("prefs", value: 30)
        let withoutFirst = withPrefs.invalidate(key)

        XCTAssertEqual(withPrefs.cached(key), .success(10))
        XCTAssertEqual(withPrefs.cached(otherKey), .success(20))
        XCTAssertEqual(withPrefs.cached("prefs"), .success(30))

        XCTAssertNil(withoutFirst.cached(key))
        XCTAssertEqual(withoutFirst.cached(otherKey), .success(20))
        XCTAssertEqual(withoutFirst.cached("prefs"), .success(30))
    }

    func testInvalidateRejectsPriorToken() {
        let cache = TestResourceCache()

        guard let (inFlight, token) = cache.request(key) else {
            return XCTFail("request should have been issued")
        }

        let invalidated = inFlight.invalidate(key)
        XCTAssertTrue(isRejected(invalidated.settle(key, token: token, result: .success(1))))
        XCTAssertEqual(invalidated.entry(for: key), .notRequested)
    }

    func testRequestOnlyFromNotRequested() {
        let cache = TestResourceCache()

        guard let (inFlight, token) = cache.request(key) else {
            return XCTFail("request should have been issued")
        }

        XCTAssertNil(inFlight.request(key))

        guard case .accepted(let settled) = inFlight.settle(key, token: token, result: .success(1)) else {
            return XCTFail("the live token should settle")
        }

        XCTAssertNil(settled.request(key))
    }

    // MARK: - Helpers

    private func isRejected(_ settlement: TestResourceCache.Settlement) -> Bool {
        if case .rejected = settlement {
            return true
        }
        return false
    }
}

private extension TestResourceCache.Entry {
    var token: TestResourceCache.RequestToken? {
        guard case .inFlight(let token) = self else {
            return nil
        }
        return token
    }
}
