import XCTest

@testable import CalCo

final class BuildConfigurationTests: XCTestCase {
    /// Regression: the Debug and Test app builds must define Swift's `DEBUG`
    /// compilation condition so the loopback-HTTP URL baked into their
    /// Info.plist is accepted by `CalCoRuntimeConfiguration`.
    func testLoopbackAppBuildUsesDebugRuntimeConfiguration() throws {
        let configured = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CALCOAPIBaseURL") as? String,
            "App Info.plist must define CALCOAPIBaseURL"
        )

        guard configured.hasPrefix("http://localhost:")
            || configured.hasPrefix("http://127.0.0.1:") else {
            throw XCTSkip("Not a loopback Debug/Test app bundle: \(configured)")
        }

        switch CalCoRuntimeConfiguration.currentEnvironment {
        case .debug, .test:
            break
        case .release:
            XCTFail("Loopback app bundle \(configured) was compiled without Swift DEBUG")
        }

        XCTAssertNil(CalCoRuntimeConfiguration.startupConfigurationError)
        XCTAssertEqual(
            CalCoRuntimeConfiguration.resolveBaseURL(
                environmentOverride: nil,
                configured: configured,
                environment: CalCoRuntimeConfiguration.currentEnvironment
            )?.absoluteString,
            configured
        )
    }
}
