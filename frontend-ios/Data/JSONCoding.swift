// Wire-format helpers for date and decimal values.

import Foundation

extension KeyedDecodingContainer {
    func decodeLocalDiaryDate(forKey key: Key) throws -> LocalDiaryDate {
        let raw = try decode(String.self, forKey: key)
        guard let date = LocalDiaryDate(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a YYYY-MM-DD local date, got \(raw)"
            )
        }
        return date
    }

    func decodeLocalDiaryDateIfPresent(forKey key: Key) throws -> LocalDiaryDate? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLocalDiaryDate(forKey: key)
    }

    func decodeFlexibleDouble(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let raw = try? decode(String.self, forKey: key),
           let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a decimal string or number"
        )
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeFlexibleDouble(forKey: key)
    }
}

extension KeyedEncodingContainer {
    mutating func encodeLocalDiaryDate(_ date: LocalDiaryDate, forKey key: Key) throws {
        try encode(date.formatted, forKey: key)
    }
}
