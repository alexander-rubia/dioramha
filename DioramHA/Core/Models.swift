import Foundation

struct HAEntity: Decodable, Identifiable, Hashable, Sendable {
    let entityID: String
    let state: String
    let attributes: [String: JSONValue]
    let lastUpdated: String

    var id: String { entityID }
    var domain: String { String(entityID.prefix { $0 != "." }) }
    var friendlyName: String { attributes["friendly_name"]?.string ?? entityID }
    var features: Int { attributes["supported_features"]?.int ?? 0 }
    var isUnavailable: Bool { state == "unavailable" || state == "unknown" }
    var isOn: Bool { state == "on" }

    func supports(_ bit: Int) -> Bool { features & bit != 0 }

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id", state, attributes, lastUpdated = "last_updated"
    }

    init(entityID: String, state: String, attributes: [String: JSONValue] = [:], lastUpdated: String = "") {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.lastUpdated = lastUpdated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try c.decode(String.self, forKey: .entityID)
        state = try c.decode(String.self, forKey: .state)
        attributes = try c.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        lastUpdated = try c.decodeIfPresent(String.self, forKey: .lastUpdated) ?? ""
    }
}

struct StateChange: Sendable {
    let entityID: String
    let newState: HAEntity?
}
