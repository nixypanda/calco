// Authenticated capability discovery used to gate keyed batch/ad-hoc writes.

import Foundation

public struct LogCreationIdempotencyCapability: Decodable, Equatable, Sendable {
    public let version: Int
    public let single: Bool
    public let adHoc: Bool
    public let batch: Bool
    public let batchKeyLocation: String?
    public let deletedOperationReplay: String
    public let preMigrationDeletedKeys: String
    /// Server-advertised request account assertion header. v2 servers must
    /// advertise `x-calco-account-id`; a missing/unknown value is unsafe.
    public let requestAccountBinding: String?

    public init(
        version: Int,
        single: Bool,
        adHoc: Bool,
        batch: Bool,
        batchKeyLocation: String?,
        deletedOperationReplay: String,
        preMigrationDeletedKeys: String,
        requestAccountBinding: String? = "x-calco-account-id"
    ) {
        self.version = version
        self.single = single
        self.adHoc = adHoc
        self.batch = batch
        self.batchKeyLocation = batchKeyLocation
        self.deletedOperationReplay = deletedOperationReplay
        self.preMigrationDeletedKeys = preMigrationDeletedKeys
        self.requestAccountBinding = requestAccountBinding
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case single
        case adHoc = "ad_hoc"
        case batch
        case batchKeyLocation = "batch_key_location"
        case deletedOperationReplay = "deleted_operation_replay"
        case preMigrationDeletedKeys = "pre_migration_deleted_keys"
        case requestAccountBinding = "request_account_binding"
    }

    public var supportsRequestAccountBinding: Bool {
        version >= 2 && requestAccountBinding == "x-calco-account-id"
    }

    public var supportsBatchIdempotency: Bool {
        supportsRequestAccountBinding
            && batch
            && batchKeyLocation == "top_level"
            && deletedOperationReplay == "conflict"
    }

    public var supportsAdHocIdempotency: Bool {
        supportsRequestAccountBinding
            && adHoc
            && deletedOperationReplay == "conflict"
    }

    public func supports(_ route: LogSubmissionRoute) -> Bool {
        guard supportsRequestAccountBinding else { return false }
        switch route {
        case .single:
            return single && deletedOperationReplay == "conflict"
        case .batch:
            return supportsBatchIdempotency
        case .adHoc:
            return supportsAdHocIdempotency
        }
    }
}

public struct CapabilitiesResponse: Decodable, Equatable, Sendable {
    public let logCreationIdempotency: LogCreationIdempotencyCapability

    public init(logCreationIdempotency: LogCreationIdempotencyCapability) {
        self.logCreationIdempotency = logCreationIdempotency
    }

    private enum CodingKeys: String, CodingKey {
        case logCreationIdempotency = "log_creation_idempotency"
    }
}
