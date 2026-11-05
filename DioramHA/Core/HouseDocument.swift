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

    /// Where the camera rests in the overview.
    struct View: Decodable, Sendable {
        let yaw, pitch: Float
        let width: CGFloat
        let target: Point
    }

    /// A side of the house, seen from the street.
    enum Side: String, Decodable, Sendable { case left, right, back }

    struct Building: Decodable, Sendable {
        let halfWidth, halfDepth, wallHeight, lowWall: CGFloat
        /// Floors of the house: 0 is the ground floor, -1 a basement, 1 the floor above, and so on.
        let levels: [Int]
        /// Sides shared with a neighbor. Empty for a detached house.
        let partyWalls: [Side]

        /// Optional distance between upper floors. A deep upper floor needs more to show the patio behind.
        let levelGap: Float?

        /// Height at which a floor floats in the model, far enough apart to see the one below.
        func elevation(of level: Int) -> Float {
            Float(level) * (level < 0 ? 7.0 : levelGap ?? 8.6)
        }

        var lowestLevel: Int { levels.min() ?? 0 }
        /// With only a ground floor the roof floats higher, so it does not hide the patio behind.
        var roofElevation: Float {
            let top = levels.max() ?? 0
            return elevation(of: top) + (top == 0 ? 11.4 : 7.6)
        }
    }

    struct Roof: Decodable, Sendable {
        struct Spot: Decodable, Sendable { let x, z: CGFloat }
        struct Panels: Decodable, Sendable {
            let columns, rows: Int
            /// Where they sit on the back slope: 0 at the ridge, 1 at the eave.
            let along: CGFloat
        }

        let halfWidth, halfDepth, ridge, rise: Float
        let chimney: Spot
        let panels: Panels?
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
            let level: Int
            let x, z, size: CGFloat
        }
        struct Hedge: Decodable, Sendable {
            let level: Int
            let x, z, width, height, depth: CGFloat
        }

        let garden: PlanRect
        let street: Street
        let ramp: Ramp?
        let steps: Steps?
        let trees: [Tree]
        let hedges: [Hedge]
    }

    /// A space that shapes the house but that the app does not control and cannot be tapped.
    struct Extra: Decodable, Sendable {
        let name: String
        let level: Int
        let frame: PlanRect
        let color: HexColor
    }

    enum Problem: Error, Equatable {
        case unsupportedVersion(Int)
        case duplicateRoom(String)
        case duplicateDevice(String)
        case emptyRoom(String)
        case noGroundFloor
        case repeatedLevel(Int)
        case gapBetweenLevels
        case unknownLevel(Int, in: String)
    }

    static let currentVersion = 2

    let version: Int
    let name: String
    let sensors: Sensors
    /// Optional: without it, the camera is worked out from the size of the house.
    let view: View?
    let building: Building
    let roof: Roof
    let site: Site
    let extras: [Extra]
    let rooms: [HouseRoom]

    /// Reads and checks a house file. Every file goes through here, wherever it comes from.
    init(data: Data) throws {
        // Checked first: an older file would otherwise fail with a confusing missing-field error.
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard version == Self.currentVersion else { throw Problem.unsupportedVersion(version) }
        self = try JSONDecoder().decode(HouseDocument.self, from: data)
        try validate()
    }

    var camera: View { view ?? automaticView }

    /// Frames the whole house above the bottom dock, whatever its size and number of floors.
    private var automaticView: View {
        let yaw: Float = -0.14, pitch: Float = -0.6
        let b = building, street = site.street
        let lowest = b.elevation(of: b.lowestLevel)
        let garden = site.garden.rect
        var points: [(x: Float, y: Float, z: Float)] = []
        func add(minX: CGFloat, maxX: CGFloat, minZ: CGFloat, maxZ: CGFloat, y: Float) {
            for x in [minX, maxX] { for z in [minZ, maxZ] { points.append((Float(x), y, Float(z))) } }
        }
        add(minX: garden.minX, maxX: garden.maxX, minZ: garden.minY, maxZ: garden.maxY, y: b.elevation(of: 0))
        add(minX: street.x - street.width / 2, maxX: street.x + street.width / 2, minZ: street.roadZ - street.roadDepth / 2,
            maxZ: street.roadZ + street.roadDepth / 2, y: lowest)
        add(minX: CGFloat(-roof.halfWidth), maxX: CGFloat(roof.halfWidth), minZ: CGFloat(-roof.halfDepth),
            maxZ: CGFloat(roof.halfDepth), y: b.roofElevation)
        // The roof label floats above the back slope.
        points.append((0, b.roofElevation + roof.rise + 1.0, -roof.halfDepth))
        let across = points.map { $0.x * cos(yaw) - $0.z * sin(yaw) }
        let up = points.map { $0.y * cos(pitch) + $0.z * sin(pitch) }
        let minU = across.min() ?? 0, maxU = across.max() ?? 0, minV = up.min() ?? 0, maxV = up.max() ?? 0
        // A very wide plot may be cropped, so the house stays large enough to tap...
        let wide = min(maxU - minU, Float(b.halfWidth) * 4)
        // ...but every floor must fit between the dock and the notch on a tall iPhone screen.
        let tall = (maxV - minV) * 0.635
        // Slightly wider than the sums: perspective makes the floors nearest the camera look larger.
        let width = max(wide, tall) * 1.08
        // Room for the dock below and the notch above, in world units on a 402-point-wide screen.
        let dock = width * 140 / 402, notch = width * 100 / 402
        let center = (minV + maxV) / 2 - dock / 2 + notch / 2
        // When cropping, the garden is what gets cut: the far edge of the house stays on screen.
        let houseEdge = roof.halfWidth * cos(yaw) - roof.halfDepth * sin(yaw)
        let gardenOnLeft = -garden.minX >= garden.maxX
        let centerU = maxU - minU <= max(wide, tall) ? (minU + maxU) / 2
            : gardenOnLeft ? houseEdge + 1 - width / 2 : -houseEdge - 1 + width / 2
        return View(yaw: yaw, pitch: pitch, width: CGFloat(width),
                    target: Point(x: centerU / cos(yaw), y: center / cos(pitch), z: 0))
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw Problem.unsupportedVersion(version) }
        let levels = building.levels.sorted()
        guard levels.contains(0) else { throw Problem.noGroundFloor }
        for (a, b) in zip(levels, levels.dropFirst()) {
            if a == b { throw Problem.repeatedLevel(a) }
            if b != a + 1 { throw Problem.gapBetweenLevels }
        }
        func check(_ level: Int, _ place: String) throws {
            guard levels.contains(level) else { throw Problem.unknownLevel(level, in: place) }
        }
        for room in rooms { try check(room.level, room.id) }
        for extra in extras { try check(extra.level, extra.name) }
        for tree in site.trees { try check(tree.level, "tree") }
        for hedge in site.hedges { try check(hedge.level, "hedge") }
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
        #if DEBUG
        // Simulator testing only: preview another house file without rebuilding the app.
        if let path = ProcessInfo.processInfo.environment["HA_DEBUG_HOUSE"], !path.isEmpty,
           let data = FileManager.default.contents(atPath: path) {
            do { return try HouseDocument(data: data) } catch { fatalError("\(path) is not valid: \(error)") }
        }
        #endif
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

    struct Pergola: Decodable, Hashable, Sendable {
        let width, height: CGFloat
    }

    let id: String
    let name: String
    let symbol: String
    let style: Style
    /// Floor it is on: 0 is the ground floor.
    let level: Int
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
        case id, name, symbol, style, level, frame, paint, floorColor, pergola, furniture, devices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        style = try c.decode(Style.self, forKey: .style)
        level = try c.decode(Int.self, forKey: .level)
        frame = try c.decode(PlanRect.self, forKey: .frame).rect
        paint = try c.decodeIfPresent(HexColor.self, forKey: .paint)
        floorColor = try c.decodeIfPresent(HexColor.self, forKey: .floorColor)
        pergola = try c.decodeIfPresent(Pergola.self, forKey: .pergola)
        furniture = try c.decodeIfPresent([Furniture].self, forKey: .furniture) ?? []
        devices = try c.decodeIfPresent([Device].self, forKey: .devices) ?? []
    }
}
