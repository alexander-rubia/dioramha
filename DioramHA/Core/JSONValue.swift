import Foundation

/// Schemaless JSON: Home Assistant attributes vary by entity.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var string: String? { if case .string(let v) = self { v } else { nil } }
    var double: Double? { if case .number(let v) = self { v } else { nil } }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    var isNull: Bool { self == .null }

    subscript(key: String) -> JSONValue? {
        if case .object(let v) = self { v[key] } else { nil }
    }

    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
