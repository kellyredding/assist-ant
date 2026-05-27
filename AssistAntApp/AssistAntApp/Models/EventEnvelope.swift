import Foundation

/// Decoded event envelope from the AssistAnt CLI's Unix domain
/// socket. Wire format is newline-delimited JSON:
///
///   {"v":1,"event":"ping","ts":1716825600,"detail_data":{...}}
///
/// Event name is a raw String (not an enum) for extensibility —
/// unknown events are silently skipped by the EventCoordinator.
/// Unknown JSON keys are silently ignored (Swift Codable default).
struct EventEnvelope: Codable {
    let v: Int
    let event: String
    let ts: Int64
    let ref: String?
    let detailData: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case v
        case event
        case ts
        case ref
        case detailData = "detail_data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        event = try container.decode(String.self, forKey: .event)
        ts = try container.decode(Int64.self, forKey: .ts)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        detailData = try container.decodeIfPresent(
            [String: AnyCodable].self, forKey: .detailData
        )
    }

    /// Convenience to extract a typed value from detailData.
    func detailValue<T>(_ key: String, as type: T.Type) -> T? {
        detailData?[key]?.value as? T
    }
}

/// Type-erased Codable wrapper for heterogeneous JSON values.
/// Adapted verbatim from
/// ~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Models/EventEnvelope.swift
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int64.self) {
            value = intVal
        } else if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let strVal = try? container.decode(String.self) {
            value = strVal
        } else if let arrVal = try? container.decode([AnyCodable].self) {
            value = arrVal.map(\.value)
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues(\.value)
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Int64:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as Bool:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case is NSNull:
            try container.encodeNil()
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported type"
                )
            )
        }
    }
}
