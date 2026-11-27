import ComposableArchitecture
import Foundation

/// The Library stack has a hub prefix followed by window-owned destinations.
public enum LibraryRoute: Hashable, Sendable {
    case hub(LibraryHubDestination)
    case global(WindowDestination)
}

public struct WindowPathChange: Equatable, Sendable {
    public let tab: WindowTab
    public let expected: [WindowDestination]
    public let desired: [WindowDestination]
    public let expectedHub: [LibraryHubDestination]
    public let desiredHub: [LibraryHubDestination]

    public init(tab: WindowTab, expected: [WindowDestination], desired: [WindowDestination],
                expectedHub: [LibraryHubDestination] = [], desiredHub: [LibraryHubDestination] = []) {
        self.tab = tab
        self.expected = expected
        self.desired = desired
        self.expectedHub = expectedHub
        self.desiredHub = desiredHub
    }
}

/// Typed tabs owned by `WindowFeature.State`. The legacy `PrimarySection` enum
/// remains only for the transitional shell until it is removed; this is the
/// production authority for the whole-port migration.
public enum WindowTab: String, Codable, Equatable, Hashable, Sendable {
    case diary
    case search
    case library
    case account

    public var title: String {
        switch self {
        case .diary: return "Diary"
        case .search: return String(localized: "search.title")
        case .library: return String(localized: "library.title")
        case .account: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .diary: return "book.closed"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .account: return "gearshape"
        }
    }
}

/// Where a typed destination or presentation originated. Captured at intent
/// time so a stale/dismissal callback cannot clear a newer presentation.
public enum WindowNavOrigin: String, Codable, Equatable, Hashable, Sendable {
    case diary
    case search
    case library
    case meals
    case barcode
    case assistant
    case quickAdd
    case settings
    case account
}

/// Immutable context carried by every typed destination/presentation. All
/// cross-screen coordination guards on `generation` and `accountID`; `date`
/// and `slot` are the captured logging context. `presentationID` is the
/// request identity used for stale-callback rejection.
public struct WindowCaptureContext: Equatable, Hashable, Sendable {
    public let date: LocalDiaryDate
    public let slot: MealSlot?
    public let accountID: String
    public let generation: UInt64
    public let origin: WindowNavOrigin
    public let presentationID: UUID

    public init(
        date: LocalDiaryDate,
        slot: MealSlot?,
        accountID: String,
        generation: UInt64,
        origin: WindowNavOrigin,
        presentationID: UUID
    ) {
        self.date = date
        self.slot = slot
        self.accountID = accountID
        self.generation = generation
        self.origin = origin
        self.presentationID = presentationID
    }
}

/// A pushed screen in the window's typed destination stack. Each case carries
/// its full captured context; ids are request identities for `ForEach` scope.
public enum WindowDestination: Equatable, Hashable, Identifiable, Sendable {
    case foodDetail(id: String, context: WindowCaptureContext)
    case mealDetail(id: String, context: WindowCaptureContext)
    case mealEditor(id: String?, context: WindowCaptureContext)
    case logEditor(id: String, context: WindowCaptureContext)
    case nutrition(
        selectedDate: LocalDiaryDate,
        today: LocalDiaryDate,
        generation: UInt64,
        presentationID: UUID
    )
    case library(context: WindowCaptureContext)
    case meals(context: WindowCaptureContext)
    case search(context: WindowCaptureContext)
    case settings(context: WindowCaptureContext)
    case accountSettings(
        accountID: String,
        generation: UInt64,
        settingsID: UUID,
        presentationID: UUID
    )

    public var id: UUID {
        switch self {
        case let .foodDetail(_, context),
             let .mealDetail(_, context),
             let .mealEditor(_, context),
             let .logEditor(_, context),
             let .library(context),
             let .meals(context),
             let .search(context),
             let .settings(context):
            return context.presentationID
        case let .nutrition(_, _, _, presentationID),
             let .accountSettings(_, _, _, presentationID):
            return presentationID
        }
    }

    public var generation: UInt64 {
        switch self {
        case let .foodDetail(_, context),
             let .mealDetail(_, context),
             let .mealEditor(_, context),
             let .logEditor(_, context),
             let .library(context),
             let .meals(context),
             let .search(context),
             let .settings(context):
            return context.generation
        case let .nutrition(_, _, generation, _):
            return generation
        case let .accountSettings(_, generation, _, _):
            return generation
        }
    }

    public var accountID: String? {
        switch self {
        case let .foodDetail(_, context),
             let .mealDetail(_, context),
             let .mealEditor(_, context),
             let .logEditor(_, context),
             let .library(context),
             let .meals(context),
             let .search(context),
             let .settings(context):
            return context.accountID
        case let .accountSettings(accountID, _, _, _):
            return accountID
        case .nutrition:
            return nil
        }
    }
}

/// A modal presentation (sheet / cover) owned by the window. `id` is the
/// request identity for `.sheet(item:)`/`fullScreenCover(item:)` bindings and
/// stale dismissal guards.
public enum WindowPresentation: Equatable, Identifiable, Sendable {
    case logFood(context: WindowCaptureContext)
    case quickAdd(context: WindowCaptureContext)
    case barcode(context: WindowCaptureContext)
    case assistant(context: WindowCaptureContext)
    case foodCreation(context: WindowCaptureContext)
    case settings(context: WindowCaptureContext)

    public var id: UUID {
        switch self {
        case let .logFood(context),
             let .quickAdd(context),
             let .barcode(context),
             let .assistant(context),
             let .foodCreation(context),
             let .settings(context):
            return context.presentationID
        }
    }

    public var context: WindowCaptureContext {
        switch self {
        case let .logFood(context),
             let .quickAdd(context),
             let .barcode(context),
             let .assistant(context),
             let .foodCreation(context),
             let .settings(context):
            return context
        }
    }
}
