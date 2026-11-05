import CoreGraphics
import Foundation

/// A house file: everything needed to draw and control a home, in one JSON document.
/// Swap the file and the home changes, with no code changes.
/// Measurements are in meters from the center of the house: x to the right seen from the street,
/// z toward the street.
struct HouseDocument: Decodable, Sendable {
    struct Sensors: Decodable, Sendable {
        let alarm, weather, sun, solarPeak, solarEnergy, battery: String
        let solar: [String]
    }

    struct Point: Decodable, Sendable {
        let x, y, z: Float
    }

    struct View: Decodable, Sendable {
        let yaw, pitch: Float
        let width: CGFloat
        let target: Point
    }

    struct Building: Decodable, Sendable {
        struct Floors: Decodable, Sendable {
            let basement, ground, first: Float

            func height(of floor: HouseRoom.Floor) -> Float {
                switch floor {
                case .basement: basement
                case .ground: ground
                case .first: first
                }
            }
        }

        let halfWidth, halfDepth, wallHeight, lowWall: CGFloat
        let floors: Floors
    }

    struct Roof: Decodable, Sendable {
        struct Spot: Decodable, Sendable { let x, z: CGFloat }
        struct Panels: Decodable, Sendable {
            let columns, rows: Int
            /// Where they sit on the back slope: 0 at the ridge, 1 at the eave.
            let along: CGFloat
        }

        let height, halfWidth, halfDepth, ridge, rise: Float
        let chimney: Spot
        let panels: Panels
    }

    struct Site: Decodable, Sendable {
        struct Street: Decodable, Sendable {
            let x, width, earthZ, earthDepth, roadZ, roadDepth: CGFloat
        }
        struct Ramp: Decodable, Sendable { let x, width: CGFloat }
        struct Steps: Decodable, Sendable {
            let x, width: CGFloat
            let count: Int
        }
        struct Tree: Decodable, Sendable {
            let floor: HouseRoom.Floor
            let x, z, size: CGFloat
        }
        struct Hedge: Decodable, Sendable {
            let floor: HouseRoom.Floor
            let x, z, width, height, depth: CGFloat
        }

        let garden: PlanRect
        let street: Street
        let ramp: Ramp
        let steps: Steps
        let trees: [Tree]
        let hedges: [Hedge]
    }

    /// A space that shapes the house but that the app does not control and cannot be tapped.
    struct Extra: Decodable, Sendable {
        let name: String
        let floor: HouseRoom.Floor
        let frame: PlanRect
        let color: HexColor
    }

    enum Problem: Error, Equatable {
        case unsupportedVersion(Int)
        case duplicateRoom(String)
        case duplicateDevice(String)
        case emptyRoom(String)
    }

    static let currentVersion = 1

    let version: Int
    let name: String
    let sensors: Sensors
    let view: View
    let building: Building
    let roof: Roof
    let site: Site
    let extras: [Extra]
    let rooms: [HouseRoom]

    /// Reads and checks a house file. Every file goes through here, wherever it comes from.
    init(data: Data) throws {
        self = try JSONDecoder().decode(HouseDocument.self, from: data)
        try validate()
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw Problem.unsupportedVersion(version) }
        var roomIDs = Set<String>()
        var deviceIDs = Set<String>()
        for room in rooms {
            guard roomIDs.insert(room.id).inserted else { throw Problem.duplicateRoom(room.id) }
            guard room.frame.width > 0, room.frame.height > 0 else { throw Problem.emptyRoom(room.id) }
            for device in room.devices {
                guard deviceIDs.insert(device.entityID).inserted else { throw Problem.duplicateDevice(device.entityID) }
            }
        }
    }

    private final class BundleToken {}

    /// The file shipped in the app: your `house.local.json` if it exists, which git ignores,
    /// otherwise the example home. A broken file here is a programming error.
    static let bundled: HouseDocument = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "house.local", withExtension: "json")
                ?? bundle.url(forResource: "house", withExtension: "json") else {
            fatalError("The house file is missing from the app")
        }
        do {
            return try HouseDocument(data: Data(contentsOf: url))
        } catch {
            fatalError("\(url.lastPathComponent) is not valid: \(error)")
        }
    }()
}

/// A floor plan rectangle as written in the house file.
struct PlanRect: Decodable, Hashable, Sendable {
    let x, z, width, depth: CGFloat

    var rect: CGRect { CGRect(x: x, y: z, width: width, height: depth) }
}

/// A color written as "E9C6BC".
struct HexColor: Decodable, Hashable, Sendable {
    let value: UInt32

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid color: \(text)")
        }
        self.value = value
    }
}

struct Device: Identifiable, Hashable, Sendable, Decodable {
    enum Kind: Hashable, Sendable {
        case light
        case power(symbol: String)
        case blind
        case climate(modes: [String])
        case vacuum
    }

    let entityID: String
    let name: String
    let kind: Kind
    /// Doors, alarms or appliances that should not be switched by accident: confirmed before sending.
    var confirm = false

    var id: String { entityID }

    private enum Keys: String, CodingKey { case entity, name, kind, symbol, modes, confirm }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        entityID = try c.decode(String.self, forKey: .entity)
        name = try c.decode(String.self, forKey: .name)
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
        let type = try c.decode(String.self, forKey: .kind)
        switch type {
        case "light": kind = .light
        case "blind": kind = .blind
        case "vacuum": kind = .vacuum
        case "power": kind = .power(symbol: try c.decode(String.self, forKey: .symbol))
        case "climate": kind = .climate(modes: try c.decode([String].self, forKey: .modes))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown kind: \(type)")
        }
    }
}

/// A piece of furniture in a room. Its position is relative to the center of the room.
struct Furniture: Decodable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable, CaseIterable {
        case doubleBed = "double_bed", kidBed = "kid_bed", cabinet, washer
        case rug, coffeeTable = "coffee_table", sofa, diningTable = "dining_table"
        case counter, fridge, desk, bathtub, toilet, car, shelf
        case lounger, hedge
    }

    let type: Kind
    let x, z: CGFloat
    var rotation: Float?
    var color: HexColor?
    var accent: HexColor?
    var width: CGFloat?
    var height: CGFloat?
    var depth: CGFloat?
}

struct HouseRoom: Identifiable, Hashable, Sendable, Decodable {
    enum Style: String, Hashable, Sendable, Decodable { case interior, terrace, pool, garden, solar }
    enum Floor: String, Hashable, Sendable, CaseIterable, Decodable { case basement, ground, first }

    struct Pergola: Decodable, Hashable, Sendable {
        let width, height: CGFloat
    }

    let id: String
    let name: String
    let symbol: String
    let style: Style
    let floor: Floor
    /// Place on the plan: x grows to the right seen from the street, and y toward the street.
    let frame: CGRect
    let paint: HexColor?
    let floorColor: HexColor?
    let pergola: Pergola?
    let furniture: [Furniture]
    let devices: [Device]

    var lights: [Device] { devices.filter { $0.kind == .light } }
    var climates: [Device] { devices.filter { if case .climate = $0.kind { true } else { false } } }
    var blinds: [Device] { devices.filter { $0.kind == .blind } }

    private enum Keys: String, CodingKey {
        case id, name, symbol, style, floor, frame, paint, floorColor, pergola, furniture, devices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        style = try c.decode(Style.self, forKey: .style)
        floor = try c.decode(Floor.self, forKey: .floor)
        frame = try c.decode(PlanRect.self, forKey: .frame).rect
        paint = try c.decodeIfPresent(HexColor.self, forKey: .paint)
        floorColor = try c.decodeIfPresent(HexColor.self, forKey: .floorColor)
        pergola = try c.decodeIfPresent(Pergola.self, forKey: .pergola)
        furniture = try c.decodeIfPresent([Furniture].self, forKey: .furniture) ?? []
        devices = try c.decodeIfPresent([Device].self, forKey: .devices) ?? []
    }
}
