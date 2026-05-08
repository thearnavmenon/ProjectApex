// JSONBCodable.swift
// ProjectApex — Models
//
// Helpers for encoding/decoding enum-keyed `Dictionary` fields as JSON
// objects (`{ "rawValue": ... }`) instead of Swift's default alternating
// array shape (`["rawValue", value, "rawValue", value]`).
//
// Why: Swift's synthesized `Dictionary<K, V>` Codable conformance encodes
// as a JSON object **only** when `K` is `String` or `Int`. For other
// `Hashable` keys — including `RawRepresentable` enums with `String` raw
// values like `MovementPattern` / `MuscleGroup` / `SetIntent` — Codable
// falls back to a flat alternating `[key, value, key, value, ...]` array.
// Swift's internal round-trips work fine on this shape, but it makes the
// JSONB unintelligible in Postgres Studio inspection and forces the TS
// Edge Function orchestrator (slice A12 / #83, ADR-0006 contract author)
// to emit non-idiomatic shapes. ADR-0006 §"Implementation consequences":
// "the trainee-model JSONB column is a contract between Edge Function
// (writer) and client (reader) for digest assembly" — that contract is
// cleaner with object-keyed shapes both sides can produce naturally.
//
// The cross-platform shape parity is locked by
// docs/fixtures/trainee-model-snapshot.json + the TS round-trip test +
// `TraineeModelSnapshotsCrossValidationTests`.

import Foundation

/// Dynamic CodingKey accepting any string. Used as the key type when
/// decoding JSON objects whose keys are dynamically derived (i.e., enum
/// raw values) rather than statically known.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { return nil }
    init(_ value: String) { self.stringValue = value }
}

extension KeyedDecodingContainer {
    /// Decode a dictionary whose keys are `RawRepresentable<String>` enums
    /// from a JSON object. Unknown rawValues (forward-compat: a key from a
    /// future `MovementPattern` case the local Swift binary doesn't know
    /// about) are silently skipped — matches the trainee-model evolution
    /// rule from ADR-0006 §"Rule-versioning: forward-only".
    func decodeEnumKeyedDict<EK, V>(
        _ valueType: V.Type,
        forKey key: Key
    ) throws -> [EK: V]
    where EK: RawRepresentable & Hashable, EK.RawValue == String, V: Decodable {
        let nested = try nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        var result: [EK: V] = [:]
        for k in nested.allKeys {
            guard let typed = EK(rawValue: k.stringValue) else { continue }
            result[typed] = try nested.decode(V.self, forKey: k)
        }
        return result
    }

    /// Variant for dictionaries that may be absent in older snapshots; returns
    /// an empty dictionary on missing key. Used for additive Codable migrations
    /// where the field is optional in the on-disk shape.
    func decodeEnumKeyedDictIfPresent<EK, V>(
        _ valueType: V.Type,
        forKey key: Key
    ) throws -> [EK: V]
    where EK: RawRepresentable & Hashable, EK.RawValue == String, V: Decodable {
        guard contains(key) else { return [:] }
        return try decodeEnumKeyedDict(valueType, forKey: key)
    }
}

extension KeyedEncodingContainer {
    /// Encode a dictionary whose keys are `RawRepresentable<String>` enums
    /// as a JSON object. Keys are sorted by rawValue for deterministic
    /// output (matters for snapshot-fixture stability and JSONB equality
    /// comparisons).
    mutating func encodeEnumKeyedDict<EK, V>(
        _ dict: [EK: V],
        forKey key: Key
    ) throws
    where EK: RawRepresentable & Hashable, EK.RawValue == String, V: Encodable {
        var nested = nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        let sorted = dict.sorted { $0.key.rawValue < $1.key.rawValue }
        for (k, v) in sorted {
            try nested.encode(v, forKey: AnyCodingKey(k.rawValue))
        }
    }
}
