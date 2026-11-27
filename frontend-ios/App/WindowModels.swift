import Foundation

// Pure value models retained from the retired app shell / feature handoff files.
// These carry no service, coordinator or view-model authority.

/// One immutable, typed log-editor mutation handed to the store-backed Diary
/// owner. The localized notice is built before the async handoff, so a later
/// generation/date change cannot rewrite what the user did.
public enum DiaryEditorMutation: Equatable, Sendable {
    case saved(
        originalID: String,
        date: LocalDiaryDate,
        log: DiaryLog,
        notice: DiaryMutationNotice
    )
    case deleted(
        id: String,
        date: LocalDiaryDate,
        notice: DiaryMutationNotice
    )

    public var date: LocalDiaryDate {
        switch self {
        case .saved(_, let date, _, _), .deleted(_, let date, _):
            return date
        }
    }

    public var notice: DiaryMutationNotice {
        switch self {
        case .saved(_, _, _, let notice), .deleted(_, _, let notice):
            return notice
        }
    }
}

/// One successful typed submission delivered to the store-backed Diary owner.
/// Affected dates are the de-duplicated union of draft dates and server log
/// dates, so a multi-day write can never be silently dropped.
public struct DiaryMutationDelivery: Equatable, Sendable {
    public let generation: UInt64
    public let affectedDates: [LocalDiaryDate]
    /// Original server payload; conversion to `DiaryLog` belongs to the owner.
    public let logs: [FoodLog]
    /// Mutually exclusive with the created-submission row payload.
    public let editor: DiaryEditorMutation?

    public init(generation: UInt64, drafts: [LogSubmissionDraft], logs: [FoodLog]) {
        self.generation = generation
        self.editor = nil
        var dates: [LocalDiaryDate] = []
        var seen: Set<LocalDiaryDate> = []
        for date in drafts.map(\.date) + logs.map(\.logDate) where seen.insert(date).inserted {
            dates.append(date)
        }
        self.affectedDates = dates
        self.logs = logs
    }

    public init(generation: UInt64, editor: DiaryEditorMutation) {
        self.generation = generation
        self.editor = editor
        self.affectedDates = [editor.date]
        self.logs = []
    }

    /// FoodDetail's frozen journal callback has no full server row; the owner
    /// invalidates the captured date and refreshes only if it is visible.
    public init(generation: UInt64, invalidating date: LocalDiaryDate) {
        self.generation = generation
        self.affectedDates = [date]
        self.logs = []
        self.editor = nil
    }
}

// MARK: - Assistant / barcode handoff values

public enum AssistantDraftPurpose: String, Codable, Equatable, Sendable {
    case customFood = "custom_food"
    case adHocLog = "ad_hoc_log"
}

/// Editable draft data handed between barcode/assistant review and creation.
/// Nothing is written until a later screen explicitly saves or logs it.
public struct AssistantFoodDraft: Equatable, Sendable {
    public let purpose: AssistantDraftPurpose
    public let name: String
    public let brand: String?
    public let barcode: String?
    public let quantity: NutritionQuantity?
    public let nutrients: [NutrientAmountValue]

    public init(
        purpose: AssistantDraftPurpose,
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        quantity: NutritionQuantity? = nil,
        nutrients: [NutrientAmountValue] = []
    ) {
        self.purpose = purpose
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.quantity = quantity
        self.nutrients = nutrients
    }
}
