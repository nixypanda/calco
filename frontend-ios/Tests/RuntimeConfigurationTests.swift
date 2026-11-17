import XCTest

@testable import CalCo

final class RuntimeConfigurationTests: XCTestCase {
    func testReleaseAcceptsHttpsURLWithBasePath() {
        let url = CalCoRuntimeConfiguration.validatedBaseURL(
            "https://api.example.com/v1/",
            environment: .release
        )
        XCTAssertEqual(url?.absoluteString, "https://api.example.com/v1/")
        XCTAssertEqual(url?.path, "/v1")
    }

    func testReleaseRejectsHttpLocalhost() {
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL(
            "http://localhost:3001",
            environment: .release
        ))
    }

    func testReleaseRejectsPlaceholder() {
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL(
            "https://calco.example.com",
            environment: .release
        ))
    }

    func testReleaseRejectsUserinfoQueryFragment() {
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL(
            "https://user:pass@example.com",
            environment: .release
        ))
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL(
            "https://example.com?x=1",
            environment: .release
        ))
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL(
            "https://example.com#frag",
            environment: .release
        ))
    }

    func testDebugAcceptsLocalhostHttp() {
        let url = CalCoRuntimeConfiguration.validatedBaseURL(
            "http://localhost:3001",
            environment: .debug
        )
        XCTAssertEqual(url?.absoluteString, "http://localhost:3001")
    }

    func testDebugRejectsNonLocalhostHttp() {
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL(
            "http://example.com",
            environment: .debug
        ))
    }

    func testResolvePrefersValidOverride() {
        let url = CalCoRuntimeConfiguration.resolveBaseURL(
            environmentOverride: "https://override.example.com",
            configured: "https://configured.example.com",
            environment: .release
        )
        XCTAssertEqual(url?.host, "override.example.com")
    }

    func testResolveRejectsInvalidOverrideWithoutFallback() {
        let url = CalCoRuntimeConfiguration.resolveBaseURL(
            environmentOverride: "http://localhost:3001",
            configured: "https://configured.example.com",
            environment: .release
        )
        XCTAssertNil(url)
    }

    func testEmptyAndMalformedRejected() {
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL("", environment: .release))
        XCTAssertNil(CalCoRuntimeConfiguration.validatedBaseURL("not a url", environment: .release))
    }
}