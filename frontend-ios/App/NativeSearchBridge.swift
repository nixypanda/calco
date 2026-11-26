import ComposableArchitecture
import Foundation

/// Narrow live seam for Search while the legacy search screen and TCA root
/// coexist. A non-nil bridge means TCA owns search presentation, including the
/// case where `windowStore.foodCreation == nil` (no active creation). A nil
/// bridge means the legacy coordinator/search view owns presentation.
public struct NativeSearchBridge {
    public let windowStore: StoreOf<WindowFeature>

    public init(windowStore: StoreOf<WindowFeature>) {
        self.windowStore = windowStore
    }
}
