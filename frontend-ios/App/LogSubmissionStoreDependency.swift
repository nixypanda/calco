import ComposableArchitecture
import Foundation

/// Dependency seam for the FROZEN journal. No new writer or cache authority:
/// the value is the existing shared store, overridable in tests.
extension DependencyValues {
    public var logSubmissionStore: LogSubmissionStore {
        get { self[LogSubmissionStoreKey.self] }
        set { self[LogSubmissionStoreKey.self] = newValue }
    }
}

private enum LogSubmissionStoreKey: DependencyKey {
    static let liveValue: LogSubmissionStore = .shared
    static let testValue: LogSubmissionStore = .shared
}
