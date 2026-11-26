import ComposableArchitecture
import Foundation

/// Narrow live seam for Nutrition Details while the legacy feature sheet and
/// TCA root coexist. `nil` bridge means legacy coordinator owns presentation.
/// A non-nil bridge means TCA owns presentation, even when `store == nil`
/// (live but unpresented).
public struct NativeNutritionBridge {
    public let store: StoreOf<NutritionDetailsFeature>?
    public let onOpen: (LocalDiaryDate, LocalDiaryDate) -> Void
    public let onDismiss: () -> Void

    public init(
        store: StoreOf<NutritionDetailsFeature>?,
        onOpen: @escaping (LocalDiaryDate, LocalDiaryDate) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }
}