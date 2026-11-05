import SceneKit
import UIKit

/// The 3D model, generated from the house file: floors float apart so that
/// every room can be seen and tapped at once, even when rooms sit behind one another.
/// Units: meters. x to the right seen from the street, y up, z toward the street.
@MainActor
final class HouseModel {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let rig = SCNNode()
    private let sun = SCNNode()
    private let fill = SCNNode()
    private let ambient = SCNNode()
    private let doc: HouseDocument
    private let camera: HouseDocument.View
    private var yaw: Float
    private var pitch: Float
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var aspect: CGFloat = 0.46
    private var focusedID: String?
    private var didIntro = false
    private var parts: [String: RoomParts] = [:]
    private var floors: [Int: SCNNode] = [:]
    private let roofNode = SCNNode()
    private var louvers: [SCNNode] = []
    private var columns: [SCNNode] = []
    private let solarCell = SCNMaterial()
    private var applied: HouseSnapshot?

    /// A narrow angle, close to an architect's model: every floor looks the same size.
    private static let fieldOfView: CGFloat = 14
    private static let labelName = "label"
    private static let keepName = "keep"
    private static let plaster: UInt32 = 0xF7F6F1
    private static let defaultPaint: UInt32 = 0xCBCDD3
    private static let woodFloor: UInt32 = 0xC49A6C

    private var homeWidth: CGFloat { camera.width }
    private var homeTarget: SCNVector3 { SCNVector3(camera.target.x, camera.target.y, camera.target.z) }
    private var halfWidth: CGFloat { doc.building.halfWidth }
    private var halfDepth: CGFloat { doc.building.halfDepth }
    private var wallHeight: CGFloat { doc.building.wallHeight }
    /// The wall facing the camera is low, to see inside.
    private var lowWall: CGFloat { doc.building.lowWall }
    private var roofHeight: Float { doc.building.roofElevation }

    private func elevation(of level: Int) -> Float {
        doc.building.elevation(of: level)
    }

    private final class RoomParts {
        /// The room's own materials: when it lights up, only these glow.
        var glow: [SCNMaterial] = []
        var lamps: [SCNMaterial] = []
        var label: SCNMaterial?
        var labelNode: SCNNode?
        var labelSize = CGSize.zero
        var blind: SCNNode?
        var water: SCNMaterial?
        /// Point of the room that is visible and tappable from the overview.
        var center = SCNVector3Zero
        /// Point the camera flies to; if nil, the same center.
        var lookAt: SCNVector3?
    }

    init(document: HouseDocument = House.document) {
        doc = document
        camera = document.camera
        yaw = camera.yaw
        pitch = camera.pitch
        buildLightsAndCamera()
        for level in document.building.levels {
            let node = SCNNode()
            node.position.y = elevation(of: level)
            scene.rootNode.addChildNode(node)
            floors[level] = node
        }
        roofNode.position.y = roofHeight
        scene.rootNode.addChildNode(roofNode)

        buildGround()
        for room in doc.rooms {
            switch room.style {
            case .interior: buildInterior(room)
            case .terrace: buildTerrace(room)
            case .pool: buildPool(room)
            case .garden: buildEntrance(room)
            case .solar: break // Sits on the roof: built with it.
            }
        }
        for extra in doc.extras { buildUnlabeled(extra.frame.rect, color: extra.color.value, on: extra.level) }
        buildPartyWalls()
        buildColumns()
        buildRoof()
        apply(.empty)
    }

    // MARK: - Interaction

    /// The field of view is horizontal, so the model fills the width on any iPhone.
    func fit(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = size.width / size.height
        // A single entrance on launch: the camera moves toward the house.
        let intro = !didIntro && !UIAccessibility.isReduceMotionEnabled
        if !didIntro {
            didIntro = true
            if intro { placeCamera(duration: 1.4) } else { placeCamera(duration: 0) }
        } else {
            placeCamera(duration: 0)
        }
    }

    func orbit(dx: Float, dy: Float) {
        yaw = min(max(yaw + dx * 0.006, -1.1), 1.1)
        pitch = min(max(pitch - dy * 0.004, -1.25), -0.3)
        rig.eulerAngles = SCNVector3(pitch, yaw, 0)
    }

    func pinch(by scale: CGFloat) {
        guard focusedID == nil else { return }
        zoom = min(max(zoom * scale, 0.8), 4.5)
        placeCamera(duration: 0)
    }

    /// Two-finger pan; the closer the view, the less it moves per point.
    func shift(dx: CGFloat, dy: CGFloat) {
        guard focusedID == nil else { return }
        let perPoint = homeWidth / zoom / 400
        offset.x = min(max(offset.x - dx * perPoint, -9), 9)
        offset.y = min(max(offset.y + dy * perPoint, -12), 12)
        placeCamera(duration: 0)
    }

    /// Flies to a room, or back to the overview with nil.
    func focus(on id: String?) {
        guard id != focusedID else { return }
        focusedID = id
        if let id {
            yaw = -0.1
            // The panels are on the back slope: they are viewed almost from above.
            pitch = id == "solar" ? -1.05 : -0.78
        } else {
            yaw = camera.yaw
            pitch = camera.pitch
            zoom = 1
            offset = .zero
        }
        placeCamera(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.8)
    }

    /// Distance at which the given width fills the screen.
    var cameraDistance: Float { cameraNode.position.z }

    private func placeCamera(duration: CFTimeInterval) {
        let visible: CGFloat
        var target: SCNVector3
        let focused = focusedID.flatMap { id in doc.rooms.first { $0.id == id } }
        if let room = focused, let part = parts[room.id] {
            visible = max(min(room.frame.width, 9) + 2.5, 6.5)
            // The sheet covers the lower half: the room is centered in the upper half.
            let lift = Float(visible / aspect * (room.style == .solar ? 0.30 : 0.20))
            target = part.lookAt ?? part.center
            target.y -= lift
        } else {
            visible = homeWidth / zoom
            target = homeTarget
            target.x += Float(offset.x)
            target.y += Float(offset.y)
        }
        let distance = visible / (2 * tan(Self.fieldOfView / 2 * .pi / 180))
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rig.position = target
        rig.eulerAngles = SCNVector3(pitch, yaw, 0)
        cameraNode.position.z = Float(distance)
        // Inside a room its name is already in the sheet, and labels would hide the furniture.
        for part in parts.values { part.labelNode?.opacity = focused == nil ? 1 : 0 }
        columns.forEach { $0.opacity = focused == nil ? 0.45 : 0 }
        // The floors above fade out so they do not hide the room.
        let level = focused.flatMap { $0.style == .solar ? nil : elevation(of: $0.level) }
        for (floor, node) in floors {
            node.opacity = level.map { elevation(of: floor) > $0 ? 0 : 1 } ?? 1
        }
        roofNode.opacity = level == nil ? 1 : 0
        SCNTransaction.commit()
    }

    func roomID(at point: CGPoint, in view: SCNView) -> String? {
        // `.all`, sorted by distance: labels and faded floors must not catch the tap.
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        guard let hit = hits.first(where: { $0.node.name != Self.labelName && !isFaded($0.node) }) else { return nil }
        var node: SCNNode? = hit.node
        while let current = node {
            if let name = current.name, name.hasPrefix("room:") { return String(name.dropFirst(5)) }
            node = current.parent
        }
        return nil
    }

    private func isFaded(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let item = current {
            if item.opacity < 0.01 { return true }
            current = item.parent
        }
        return false
    }

    /// How much each piece of a room glows; 0 for all when it is off.
    func glowLevels(of roomID: String) -> [CGFloat] {
        parts[roomID]?.glow.map(\.emission.intensity) ?? []
    }

    func tapTarget(for room: HouseRoom) -> SCNVector3 {
        parts[room.id]?.center ?? SCNVector3Zero
    }

    // MARK: - State

    func apply(_ snapshot: HouseSnapshot) {
        let first = applied == nil
        SCNTransaction.begin()
        SCNTransaction.animationDuration = first ? 0 : 0.5

        applyPhase(DayPhase(elevation: snapshot.elevation), elevation: snapshot.elevation)

        for room in doc.rooms {
            guard let part = parts[room.id] else { continue }
            let state = snapshot.rooms[room.id] ?? .init()
            part.glow.forEach { $0.emission.intensity = state.lit ? 1 : 0 }
            part.lamps.forEach {
                $0.emission.contents = state.lit ? UIColor(hex: 0xFFD27A) : UIColor.black
            }
            if let water = part.water {
                water.emission.contents = state.lit ? UIColor(hex: 0x38E6D8) : UIColor.black
                water.diffuse.contents = UIColor(hex: state.lit ? 0x35DCD0 : 0x1E8FA3)
            }
            if let blind = part.blind, let position = state.blind {
                blind.scale.y = Float(max(1 - position / 100, 0.001))
            }
            let old = applied?.rooms[room.id]
            if first || old?.temperature != state.temperature || old?.heating != state.heating {
                refreshLabel(room, part, state)
            }
        }

        // Panels glow more the more they produce (5 kW = full glow).
        let output = CGFloat(min(snapshot.solarPower / 5000, 1))
        solarCell.emission.contents = UIColor(red: 0.12 * output, green: 0.42 * output, blue: 0.95 * output, alpha: 1)

        // Pergola louvers: open edge-on to the camera to show the gaps, closed flat.
        let angle: Float = snapshot.pergolaClosed ? 0 : -0.85
        louvers.forEach { $0.eulerAngles.x = angle }

        SCNTransaction.commit()
        applied = snapshot
    }

    private func applyPhase(_ phase: DayPhase, elevation: Double) {
        switch phase {
        case .day:
            sun.light?.intensity = 760
            sun.light?.color = UIColor(hex: 0xFFF3DC)
            fill.light?.intensity = 240
            ambient.light?.intensity = 360
            ambient.light?.color = UIColor(hex: 0xDCE8F5)
        case .dusk:
            sun.light?.intensity = 620
            sun.light?.color = UIColor(hex: 0xFFB27E)
            fill.light?.intensity = 170
            ambient.light?.intensity = 300
            ambient.light?.color = UIColor(hex: 0xB9A9D6)
        case .night:
            sun.light?.intensity = 55
            sun.light?.color = UIColor(hex: 0x9DB4F0)
            fill.light?.intensity = 25
            ambient.light?.intensity = 130
            ambient.light?.color = UIColor(hex: 0x5C6FB5)
        }
        let height = Float(min(max(elevation, 12), 60)) * .pi / 180
        sun.eulerAngles = SCNVector3(phase == .night ? -0.9 : -height - 0.25, 0.65, 0)
    }

    private func refreshLabel(_ room: HouseRoom, _ part: RoomParts, _ state: HouseSnapshot.RoomState) {
        part.label?.diffuse.contents = Self.labelImage(
            name: room.name, temperature: state.temperature, heating: state.heating, size: part.labelSize)
    }

    /// Light text on a dark pill: readable by day, at night and with the light on.
    private static func labelImage(name: String, temperature: Int?, heating: Bool, size: CGSize) -> UIImage {
        let pixels = CGSize(width: size.width * 150, height: size.height * 150)
        return UIGraphicsImageRenderer(size: pixels).image { _ in
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "AvenirNext-DemiBold", size: 76) ?? .boldSystemFont(ofSize: 76),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style,
            ]
            var line = name
            if let temperature, !heating { line += "  \(temperature)°" }
            let text = NSMutableAttributedString(string: line, attributes: attributes)
            if let temperature, heating, let flame = UIImage(systemName: "flame.fill")?
                .withTintColor(UIColor(hex: 0xFF8A3C), renderingMode: .alwaysOriginal) {
                text.append(NSAttributedString(string: "  ", attributes: attributes))
                let attachment = NSTextAttachment(image: flame)
                attachment.bounds = CGRect(x: 0, y: -6, width: 50, height: 60)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " \(temperature)°", attributes: attributes))
            }
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            // Long names shrink to fit on one line instead of wrapping out of the label.
            let room = pixels.width - 56
            let natural = text.size().width
            if natural > room {
                let scale = room / natural
                text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { font, range, _ in
                    guard let font = font as? UIFont else { return }
                    text.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: range)
                }
            }
            let bounds = text.boundingRect(with: pixels, options: [.usesLineFragmentOrigin], context: nil)
            let pill = CGRect(x: (pixels.width - bounds.width) / 2 - 28, y: 0,
                              width: bounds.width + 56, height: bounds.height + 20)
                .intersection(CGRect(origin: .zero, size: pixels))
            UIColor(hex: 0x14204A).withAlphaComponent(0.78).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            text.draw(with: CGRect(x: 0, y: 10, width: pixels.width, height: pixels.height - 10),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    // MARK: - Light and camera

    private func buildLightsAndCamera() {
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = Self.fieldOfView
        camera.zNear = 0.5
        camera.zFar = 500
        cameraNode.camera = camera
        // Starts far away for the opening move.
        cameraNode.position = SCNVector3(0, 0, 130)
        rig.position = homeTarget
        rig.eulerAngles = SCNVector3(pitch, yaw, 0)
        rig.addChildNode(cameraNode)
        scene.rootNode.addChildNode(rig)

        // No shadows: with floating floors, each would smudge the one below.
        let sunLight = SCNLight()
        sunLight.type = .directional
        sun.light = sunLight
        scene.rootNode.addChildNode(sun)

        // Fill light from the other side, so shaded faces do not look flat.
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.color = UIColor(hex: 0xDCE8F5)
        fill.light = fillLight
        fill.eulerAngles = SCNVector3(-0.5, -2.4, 0)
        scene.rootNode.addChildNode(fill)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambient.light = ambientLight
        scene.rootNode.addChildNode(ambient)
    }

    // MARK: - Site

    /// The plot rises toward the back: patio and garden are level with the ground floor, and the
    /// street is level with the garage.
    private func buildGround() {
        guard let ground = floors[0], let street = floors[doc.building.lowestLevel] else { return }
        let site = doc.site
        // Side garden and back patio, on one slab with soil underneath.
        let garden = site.garden.rect
        box(garden.width, 0.5, garden.height, 0x8B6A55, x: garden.midX, bottom: -0.56, z: garden.midY, in: ground)
        box(garden.width, 0.06, garden.height, 0x79AE62, x: garden.midX, bottom: -0.06, z: garden.midY, in: ground)
        // The neighbor's fence continues the party wall along the patio.
        for side in doc.building.partyWalls where side != .back {
            let sign: CGFloat = side == .right ? 1 : -1
            box(0.14, 1.0, -garden.minY - halfDepth, Self.plaster, x: sign * (halfWidth - 0.07), bottom: 0,
                z: (garden.minY - halfDepth) / 2, in: ground)
        }
        for item in site.trees {
            guard let parent = floors[item.level] else { continue }
            tree(x: item.x, z: item.z, size: item.size, groundY: 0, in: parent)
        }
        for hedge in site.hedges {
            guard let parent = floors[hedge.level] else { continue }
            box(hedge.width, hedge.height, hedge.depth, 0x3F7D4A, x: hedge.x, bottom: 0, z: hedge.z, in: parent)
        }

        // Street.
        let road = site.street
        box(road.width, 0.5, road.earthDepth, 0x8B6A55, x: road.x, bottom: -0.56, z: road.earthZ, in: street)
        box(road.width, 0.12, road.roadDepth, 0x6C7078, x: road.x, bottom: -0.1, z: road.roadZ, in: street)
    }

    private func buildEntrance(_ room: HouseRoom) {
        guard let parent = floors[room.level] else { return }
        let node = SCNNode()
        node.name = "room:\(room.id)"
        parent.addChildNode(node)
        let f = room.frame
        let site = doc.site

        box(site.street.width, 0.06, f.height, 0x79AE62, x: site.street.x, bottom: -0.06, z: f.midY, in: node)
        // Garage ramp: from the street to the door.
        if let ramp = site.ramp {
            box(ramp.width, 0.04, f.height, 0xB9B6AE, x: ramp.x, bottom: 0, z: f.midY, in: node)
        }
        // Outdoor steps up to the porch.
        if let steps = site.steps {
            for step in 0..<steps.count {
                box(steps.width, 0.16 * CGFloat(steps.count - step), 0.5, 0xE4DFD2, x: steps.x, bottom: 0,
                    z: halfDepth + 0.25 + CGFloat(step) * 0.5, in: node)
            }
        }
        placeFurniture(of: room, in: node, center: SCNVector3(f.midX, 0, f.midY))

        let part = RoomParts()
        part.center = SCNVector3(Float(site.street.x), elevation(of: room.level) + 0.02, Float(f.midY))
        let label = billboard(size: CGSize(width: 3.2, height: 0.72), in: node)
        label.node.position = SCNVector3(Float(site.street.x) + 0.2, 1.0, Float(f.midY))
        part.label = label.material
        part.labelNode = label.node
        part.labelSize = label.size
        parts[room.id] = part
    }

    private func tree(x: CGFloat, z: CGFloat, size s: CGFloat, groundY: CGFloat, in parent: SCNNode) {
        let trunk = SCNCylinder(radius: 0.08 * s, height: 0.7 * s)
        trunk.firstMaterial = Self.material(0x6D4C3A)
        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(x, groundY + 0.35 * s, z)
        parent.addChildNode(trunkNode)
        for (dx, dy, dz, r) in [(0.0, 0.95, 0.0, 0.5), (-0.28, 0.75, 0.1, 0.34), (0.28, 0.78, -0.05, 0.36)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            let sphere = SCNSphere(radius: r * s)
            sphere.segmentCount = 14
            sphere.firstMaterial = Self.material(0x4F9A58)
            let leaf = SCNNode(geometry: sphere)
            leaf.position = SCNVector3(x + dx * s, groundY + dy * s, z + dz * s)
            parent.addChildNode(leaf)
        }
    }

    // MARK: - House

    /// Solid wall on each side shared with a neighbor.
    private func buildPartyWalls() {
        for side in doc.building.partyWalls {
            for node in floors.values {
                switch side {
                case .right, .left:
                    box(0.3, wallHeight + 0.5, halfDepth * 2, 0xCFCAC0,
                        x: (side == .right ? 1 : -1) * (halfWidth + 0.15), bottom: -0.2, z: 0, in: node)
                case .back:
                    box(halfWidth * 2, wallHeight + 0.5, 0.3, 0xCFCAC0,
                        x: 0, bottom: -0.2, z: -(halfDepth + 0.15), in: node)
                }
            }
        }
    }

    /// Thin columns that tie the floors together and show they are one house.
    private func buildColumns() {
        let bottom = CGFloat(elevation(of: doc.building.lowestLevel))
        let height = CGFloat(roofHeight) - bottom
        for (x, z) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(CGFloat, CGFloat)] {
            let column = box(0.05, height, 0.05, 0xFFFFFF, x: x * halfWidth, bottom: bottom,
                             z: z * halfDepth, in: scene.rootNode)
            column.opacity = 0.45
            columns.append(column)
        }
    }

    /// Hip roof, with the panels on the back slope.
    private func buildRoof() {
        let roof = doc.roof
        let x = roof.halfWidth, z = roof.halfDepth, ridge = roof.ridge, rise = roof.rise
        let a = SCNVector3(-x, 0, z), b = SCNVector3(x, 0, z)
        let c = SCNVector3(x, 0, -z), d = SCNVector3(-x, 0, -z)
        let e = SCNVector3(-ridge, rise, 0), f = SCNVector3(ridge, rise, 0)
        let faces: [[SCNVector3]] = [[a, b, f, e], [b, c, f], [c, d, e, f], [d, a, e]]

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        for face in faces {
            let u = Self.minus(face[1], face[0]), v = Self.minus(face[2], face[0])
            let normal = Self.normalized(Self.cross(u, v))
            let base = Int32(vertices.count)
            vertices += face
            normals += face.map { _ in normal }
            for i in 1..<(face.count - 1) { indices += [base, base + Int32(i), base + Int32(i) + 1] }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let tiles = SCNMaterial()
        tiles.lightingModel = .lambert
        tiles.diffuse.contents = UIColor(hex: 0xB5563D)
        tiles.isDoubleSided = true
        geometry.firstMaterial = tiles
        roofNode.addChildNode(SCNNode(geometry: geometry))

        // Chimney, on the street-side slope.
        box(0.6, 1.3, 0.6, 0xC5684C, x: roof.chimney.x, bottom: 0.1, z: roof.chimney.z, in: roofNode)
        box(0.75, 0.12, 0.75, 0x8F4A36, x: roof.chimney.x, bottom: 1.4, z: roof.chimney.z, in: roofNode)

        if let panels = roof.panels, doc.rooms.contains(where: { $0.style == .solar }) {
            buildSolarPanels(panels, halfDepth: CGFloat(z), rise: CGFloat(rise))
        }
    }

    private static func minus(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    private static func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    private static func normalized(_ v: SCNVector3) -> SCNVector3 {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return SCNVector3(v.x / length, v.y / length, v.z / length)
    }

    private func buildSolarPanels(_ panels: HouseDocument.Roof.Panels, halfDepth: CGFloat, rise: CGFloat) {
        solarCell.lightingModel = .blinn
        solarCell.diffuse.contents = UIColor(hex: 0x14285A)
        solarCell.specular.contents = UIColor(white: 0.9, alpha: 1)
        solarCell.shininess = 0.8

        let array = SCNNode()
        array.name = "room:solar"
        // The slope rises from the back to the ridge: the panels tilt with it.
        let along = panels.along
        array.position = SCNVector3(0, Float(rise * (1 - along)) + 0.03, Float(-halfDepth * along))
        array.eulerAngles.x = -Float(atan2(rise, halfDepth))
        roofNode.addChildNode(array)

        let columns = panels.columns, rows = panels.rows
        let w: CGFloat = 1.05, depth: CGFloat = 1.0, gap: CGFloat = 0.06
        for column in 0..<columns {
            for row in 0..<rows {
                let x = (CGFloat(column) - CGFloat(columns - 1) / 2) * (w + gap)
                let z = (CGFloat(row) - CGFloat(rows - 1) / 2) * (depth + gap)
                box(w, 0.04, depth, 0xC9CDD3, x: x, bottom: 0, z: z, in: array)
                let geometry = SCNBox(width: w - 0.06, height: 0.015, length: depth - 0.06, chamferRadius: 0)
                geometry.firstMaterial = solarCell
                let cell = SCNNode(geometry: geometry)
                cell.position = SCNVector3(x, 0.045, z)
                array.addChildNode(cell)
            }
        }

        let label = billboard(size: CGSize(width: 2.6, height: 0.72), in: roofNode)
        label.node.position = SCNVector3(0, 1.4, -4.6)
        let part = RoomParts()
        part.label = label.material
        part.labelNode = label.node
        part.labelSize = label.size
        // The exact center falls on the seam between panels: aim at one of them.
        let inward: CGFloat = 0.5
        part.center = SCNVector3(0.55, roofHeight + Float(rise * (1 - along) - inward * rise / halfDepth) + 0.08,
                                 Float(-halfDepth * along - inward))
        part.lookAt = SCNVector3(0, roofHeight + Float(rise * (1 - along)), Float(-halfDepth * along))
        parts["solar"] = part
    }

    /// Walls and floor of a room: three tall walls and a low one toward the street.
    private func addWalls(width w: CGFloat, depth d: CGFloat, paint: UInt32, floorColor: UInt32, in node: SCNNode) {
        let h = wallHeight, t: CGFloat = 0.1
        box(w, 0.08, d, floorColor, x: 0, bottom: 0, z: 0, in: node)
        box(w, h, t, paint, x: 0, bottom: 0, z: -d / 2 + t / 2, in: node)
        box(t, h, d, paint, x: -w / 2 + t / 2, bottom: 0, z: 0, in: node)
        box(t, h, d, paint, x: w / 2 - t / 2, bottom: 0, z: 0, in: node)
        box(w, lowWall, t, paint, x: 0, bottom: 0, z: d / 2 - t / 2, in: node)
        // Light cap: draws the outline of the room, like a floor plan.
        let cap: CGFloat = 0.03
        box(w, cap, t + 0.02, Self.plaster, x: 0, bottom: h, z: -d / 2 + t / 2, in: node)
        box(t + 0.02, cap, d, Self.plaster, x: -w / 2 + t / 2, bottom: h, z: 0, in: node)
        box(t + 0.02, cap, d, Self.plaster, x: w / 2 - t / 2, bottom: h, z: 0, in: node)
        box(w, cap, t + 0.02, Self.plaster, x: 0, bottom: lowWall, z: d / 2 - t / 2, in: node)
    }

    private func buildUnlabeled(_ f: CGRect, color: UInt32, on level: Int) {
        guard let parent = floors[level] else { return }
        let node = SCNNode()
        node.position = SCNVector3(f.midX, 0, f.midY)
        parent.addChildNode(node)
        addWalls(width: f.width, depth: f.height, paint: color, floorColor: 0xC9B79C, in: node)
    }

    private func buildInterior(_ room: HouseRoom) {
        guard let parent = floors[room.level] else { return }
        let f = room.frame
        let w = f.width, d = f.height, h = wallHeight
        let node = SCNNode()
        node.name = "room:\(room.id)"
        node.position = SCNVector3(f.midX, 0, f.midY)
        parent.addChildNode(node)

        let part = RoomParts()
        // The front wall hides the near part of the room: tap a little further back.
        part.center = SCNVector3(Float(f.midX), elevation(of: room.level) + 0.4, Float(f.minY + d * 0.3))
        part.lookAt = SCNVector3(Float(f.midX), elevation(of: room.level) + 0.1, Float(f.midY))
        addWalls(width: w, depth: d, paint: room.paint?.value ?? Self.defaultPaint,
                 floorColor: room.floorColor?.value ?? Self.woodFloor, in: node)

        placeFurniture(of: room, in: node, center: SCNVector3Zero)

        if !room.blinds.isEmpty { part.blind = addWindow(width: min(w * 0.5, 2.0), depth: d, in: node) }
        if !room.lights.isEmpty { part.lamps = [addLamp(width: w, depth: d, in: node)] }

        let label = billboard(size: CGSize(width: 3.4, height: 0.72), in: node)
        label.node.position = SCNVector3(0, h + 0.5, 0)
        part.label = label.material
        part.labelNode = label.node
        part.labelSize = label.size
        parts[room.id] = part

        makeGlow(node, part)
    }

    /// With no ceiling to hang from, the lamp stands in the back corner.
    private func addLamp(width w: CGFloat, depth d: CGFloat, in node: SCNNode) -> SCNMaterial {
        let x = w / 2 - 0.35, z = -d / 2 + 0.35
        box(0.03, 0.95, 0.03, 0x333333, x: x, bottom: 0.08, z: z, in: node)
        let bulb = SCNSphere(radius: 0.17)
        bulb.segmentCount = 16
        // Its own, not shared: each lamp lights up separately.
        let own = Self.material(0xFFF3D6).copy() as? SCNMaterial ?? SCNMaterial()
        bulb.firstMaterial = own
        let lamp = SCNNode(geometry: bulb)
        lamp.position = SCNVector3(x, 1.1, z)
        node.addChildNode(lamp)
        return own
    }

    /// Window with a real blind on the back wall; scaling lowers the blind from the top.
    private func addWindow(width: CGFloat, depth d: CGFloat, in node: SCNNode) -> SCNNode {
        let wh: CGFloat = 0.62
        let y: CGFloat = 0.3
        let z = -d / 2 + 0.12
        box(width + 0.1, wh + 0.1, 0.03, Self.plaster, x: 0, bottom: y - 0.05, z: z, in: node)
        let pane = box(width, wh, 0.03, 0x9CCFEA, x: 0, bottom: y, z: z + 0.012, in: node)
        let glass = Self.material(0x9CCFEA).copy() as? SCNMaterial
        glass?.emission.contents = UIColor(hex: 0x4B7FA8)
        pane.geometry?.firstMaterial = glass
        pane.name = Self.keepName

        let geometry = SCNBox(width: width, height: wh, length: 0.03, chamferRadius: 0)
        geometry.firstMaterial = Self.material(0xF3EEDF)
        let blind = SCNNode(geometry: geometry)
        blind.pivot = SCNMatrix4MakeTranslation(0, Float(wh / 2), 0)
        blind.position = SCNVector3(0, y + wh, z + 0.03)
        node.addChildNode(blind)
        return blind
    }

    // MARK: - Furniture

    /// Places the house file's furniture. `center` is the center of the room inside `node`.
    private func placeFurniture(of room: HouseRoom, in node: SCNNode, center: SCNVector3) {
        for item in room.furniture {
            let piece = SCNNode()
            piece.position = SCNVector3(Float(item.x) + center.x, center.y, Float(item.z) + center.z)
            piece.eulerAngles.y = (item.rotation ?? 0) * .pi / 180
            let scale = Self.scale(of: item.type)
            piece.scale = SCNVector3(scale, scale, scale)
            node.addChildNode(piece)
            build(item, scale: CGFloat(scale), in: piece)
        }
    }

    /// The catalog is drawn slightly below real size; outdoor pieces are already in meters.
    private static func scale(of kind: Furniture.Kind) -> Float {
        switch kind {
        case .lounger, .hedge: 1
        default: 1.35
        }
    }

    /// The furniture catalog. Each piece is drawn around its own origin.
    private func build(_ item: Furniture, scale: CGFloat, in n: SCNNode) {
        let color = item.color?.value
        switch item.type {
        case .doubleBed:
            box(1.45, 0.3, 1.55, 0x8A6A52, x: 0, bottom: 0.08, z: 0.9, in: n)
            box(1.35, 0.17, 1.45, 0xF4F1EA, x: 0, bottom: 0.38, z: 0.9, in: n)
            box(1.35, 0.1, 0.8, 0xB9576A, x: 0, bottom: 0.46, z: 1.25, in: n)
            box(1.5, 0.8, 0.08, 0x6D5240, x: 0, bottom: 0.08, z: 0.08, in: n)
            box(0.5, 0.11, 0.3, 0xFFFFFF, x: -0.34, bottom: 0.55, z: 0.32, in: n)
            box(0.5, 0.11, 0.3, 0xFFFFFF, x: 0.34, bottom: 0.55, z: 0.32, in: n)
        case .kidBed:
            box(0.8, 0.24, 1.45, 0xE8DCC8, x: 0, bottom: 0.08, z: 0.85, in: n)
            box(0.72, 0.1, 0.9, color ?? 0x2F6DB5, x: 0, bottom: 0.32, z: 1.08, in: n)
            box(0.5, 0.09, 0.28, 0xFFFFFF, x: 0, bottom: 0.32, z: 0.32, in: n)
            // Teddy bear.
            for (dx, dy, r) in [(0.0, 0.0, 0.1), (0.0, 0.14, 0.075), (-0.06, 0.2, 0.03), (0.06, 0.2, 0.03)] as [(CGFloat, CGFloat, CGFloat)] {
                let s = SCNSphere(radius: r)
                s.segmentCount = 12
                s.firstMaterial = Self.material(item.accent?.value ?? 0xB5834F)
                let bear = SCNNode(geometry: s)
                bear.position = SCNVector3(dx, 0.5 + dy, 0.62)
                n.addChildNode(bear)
            }
        case .cabinet:
            box(0.36, 0.7, 0.3, color ?? 0xE3B23C, x: 0, bottom: 0.08, z: 0, in: n)
        case .washer:
            box(0.62, 0.78, 0.55, 0xF7F7F4, x: 0, bottom: 0.08, z: 0.32, in: n)
            let door = SCNCylinder(radius: 0.2, height: 0.03)
            door.firstMaterial = Self.material(color ?? 0x7B8FA8)
            let drum = SCNNode(geometry: door)
            drum.eulerAngles.x = .pi / 2
            drum.position = SCNVector3(0, 0.44, 0.61)
            n.addChildNode(drum)
        case .rug:
            box(2.0, 0.03, 1.2, color ?? 0xC85A4A, x: 0, bottom: 0.08, z: 0, in: n)
        case .coffeeTable:
            box(0.8, 0.05, 0.42, 0x8C5E3C, x: 0, bottom: 0.3, z: 0, in: n)
            box(0.06, 0.2, 0.06, 0x5E3F28, x: -0.3, bottom: 0.1, z: 0, in: n)
            box(0.06, 0.2, 0.06, 0x5E3F28, x: 0.3, bottom: 0.1, z: 0, in: n)
        case .sofa:
            box(1.75, 0.3, 0.68, 0x35577D, x: 0, bottom: 0.1, z: 0.58, in: n)
            box(1.75, 0.56, 0.2, 0x2D4A6B, x: 0, bottom: 0.1, z: 0.28, in: n)
            box(0.2, 0.44, 0.68, 0x2D4A6B, x: -0.92, bottom: 0.1, z: 0.58, in: n)
            box(0.2, 0.44, 0.68, 0x2D4A6B, x: 0.92, bottom: 0.1, z: 0.58, in: n)
        case .diningTable:
            box(0.9, 0.05, 1.6, 0x8C5E3C, x: 0, bottom: 0.56, z: 0, in: n)
            box(0.1, 0.48, 1.3, 0x5E3F28, x: 0, bottom: 0.08, z: 0, in: n)
            for z in [-0.45, 0.45] as [CGFloat] {
                box(0.3, 0.32, 0.3, 0x35577D, x: -0.68, bottom: 0.08, z: z, in: n)
                box(0.3, 0.32, 0.3, 0x35577D, x: 0.68, bottom: 0.08, z: z, in: n)
            }
        case .counter:
            let width = (item.width ?? 2.8) / scale
            box(width, 0.72, 0.5, 0xF4F1EA, x: 0, bottom: 0.08, z: 0, in: n)
            box(width, 0.05, 0.54, 0x4A4F5A, x: 0, bottom: 0.8, z: 0, in: n)
            box(0.42, 0.012, 0.36, 0x16181D, x: -0.14, bottom: 0.85, z: 0, in: n)
        case .fridge:
            box(0.46, 1.7, 0.5, 0xD8DCE2, x: 0, bottom: 0.08, z: 0, in: n)
        case .desk:
            box(1.15, 0.05, 0.5, 0x8C5E3C, x: 0, bottom: 0.72, z: 0.34, in: n)
            box(0.05, 0.64, 0.45, 0x5E3F28, x: -0.52, bottom: 0.08, z: 0.34, in: n)
            box(0.05, 0.64, 0.45, 0x5E3F28, x: 0.52, bottom: 0.08, z: 0.34, in: n)
            box(0.52, 0.32, 0.03, 0x1C2230, x: 0, bottom: 0.85, z: 0.24, in: n)
            box(0.08, 0.1, 0.05, 0x3B3F4A, x: 0, bottom: 0.77, z: 0.24, in: n)
            box(0.34, 0.06, 0.34, 0x3F7A62, x: 0, bottom: 0.42, z: 0.85, in: n)
            box(0.34, 0.4, 0.05, 0x3F7A62, x: 0, bottom: 0.46, z: 1.02, in: n)
            box(0.05, 0.34, 0.05, 0x3B3F4A, x: 0, bottom: 0.08, z: 0.85, in: n)
        case .bathtub:
            let width = (item.width ?? 2.0) / scale
            box(width, 0.42, 0.62, 0xFFFFFF, x: 0, bottom: 0.08, z: 0, in: n)
            box(width - 0.12, 0.03, 0.5, 0x67C5D4, x: 0, bottom: 0.5, z: 0, in: n)
        case .toilet:
            box(0.34, 0.34, 0.42, 0xFFFFFF, x: 0, bottom: 0.08, z: 0, in: n)
            box(0.34, 0.42, 0.1, 0xFFFFFF, x: 0, bottom: 0.2, z: -0.25, in: n)
        case .car:
            car(in: n)
        case .shelf:
            box(1.1, 1.5, 0.3, 0x8C7B6B, x: 0, bottom: 0.08, z: 0, in: n)
            box(1.1, 0.04, 0.32, 0xE3B23C, x: 0, bottom: 0.8, z: 0, in: n)
        case .lounger:
            box(0.7, 0.16, 1.9, 0xE9E3D3, x: 0, bottom: 0.06, z: 0, in: n)
            box(0.7, 0.07, 0.6, 0x2E6F95, x: 0, bottom: 0.22, z: -0.65, in: n)
        case .hedge:
            box(item.width ?? 1, item.height ?? 0.45, item.depth ?? 0.32, 0x3F7D4A, x: 0, bottom: 0, z: 0, in: n)
        }
    }

    private func car(in n: SCNNode) {
        let x: CGFloat = 0.0
        let z: CGFloat = 0.3
        box(2.3, 0.36, 1.05, 0xC8402F, x: x, bottom: 0.26, z: z, in: n, chamfer: 0.08)
        box(1.2, 0.34, 0.92, 0xA93224, x: x - 0.1, bottom: 0.6, z: z, in: n, chamfer: 0.08)
        box(1.24, 0.2, 0.94, 0x24304D, x: x - 0.1, bottom: 0.68, z: z, in: n)
        for (dx, dz) in [(-0.72, 0.53), (0.72, 0.53), (-0.72, -0.53), (0.72, -0.53)] as [(CGFloat, CGFloat)] {
            let wheel = SCNCylinder(radius: 0.19, height: 0.12)
            wheel.firstMaterial = Self.material(0x20232A)
            let node = SCNNode(geometry: wheel)
            node.eulerAngles.x = .pi / 2
            node.position = SCNVector3(x + dx, 0.27, z + dz)
            n.addChildNode(node)
        }
    }

    // MARK: - Exterior

    private func buildTerrace(_ room: HouseRoom) {
        guard let parent = floors[room.level] else { return }
        let f = room.frame
        let node = SCNNode()
        node.name = "room:\(room.id)"
        parent.addChildNode(node)
        let part = RoomParts()

        // Deck boards across the whole patio.
        let boards = Int(f.height / 0.3)
        for i in 0..<boards {
            box(f.width, 0.06, 0.28, i % 2 == 0 ? 0xB98A5E : 0xA87A50, x: f.midX, bottom: 0,
                z: f.minY + 0.15 + CGFloat(i) * 0.3, in: node)
        }

        // Pergola with its posts, beams and adjustable louvers.
        let pw = room.pergola?.width ?? 5.2, pd: CGFloat = f.height - 0.2, height = room.pergola?.height ?? 2.3
        let px = f.maxX - pw / 2 - 0.3, pz = f.midY
        for (sx, sz) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] as [(CGFloat, CGFloat)] {
            box(0.12, height, 0.12, Self.plaster, x: px + sx * (pw / 2 - 0.08), bottom: 0.06,
                z: pz + sz * (pd / 2 - 0.08), in: node)
        }
        box(pw, 0.14, 0.12, Self.plaster, x: px, bottom: height, z: pz + pd / 2 - 0.08, in: node)
        box(pw, 0.14, 0.12, Self.plaster, x: px, bottom: height, z: pz - pd / 2 + 0.08, in: node)
        let count = Int((pd - 0.3) / 0.24)
        for i in 0..<count {
            let slat = SCNBox(width: pw - 0.2, height: 0.025, length: 0.22, chamferRadius: 0)
            slat.firstMaterial = Self.material(0xF0EDE5)
            let louver = SCNNode(geometry: slat)
            louver.position = SCNVector3(px, height + 0.1, pz - pd / 2 + 0.2 + CGFloat(i) * 0.24)
            node.addChildNode(louver)
            louvers.append(louver)
        }

        placeFurniture(of: room, in: node, center: SCNVector3(f.midX, 0, f.midY))

        // String of bulbs: they glow when the light is on.
        let bulbMaterial = Self.material(0xFFF3D6).copy() as? SCNMaterial ?? SCNMaterial()
        for i in 0..<9 {
            let bulb = SCNSphere(radius: 0.08)
            bulb.segmentCount = 10
            bulb.firstMaterial = bulbMaterial
            let b = SCNNode(geometry: bulb)
            b.position = SCNVector3(px - pw / 2 + 0.2 + CGFloat(i) * (pw - 0.4) / 8, height - 0.15, pz + pd / 2 - 0.1)
            node.addChildNode(b)
        }
        part.lamps = [bulbMaterial]

        part.center = SCNVector3(Float(px), elevation(of: room.level) + Float(height) + 0.1, Float(pz))
        part.lookAt = SCNVector3(Float(f.midX), elevation(of: room.level) + 0.1, Float(f.midY))

        let label = billboard(size: CGSize(width: 2.8, height: 0.72), in: node)
        label.node.position = SCNVector3(Float(px), Float(height + 0.35), Float(pz))
        part.label = label.material
        part.labelNode = label.node
        part.labelSize = label.size
        parts[room.id] = part
        makeGlow(node, part)
    }

    private func buildPool(_ room: HouseRoom) {
        guard let parent = floors[room.level] else { return }
        let f = room.frame
        let node = SCNNode()
        node.name = "room:\(room.id)"
        node.position = SCNVector3(f.midX, 0, f.midY)
        parent.addChildNode(node)

        box(f.width + 0.8, 0.1, f.height + 0.8, 0xF0EDE5, x: 0, bottom: 0, z: 0, in: node)
        let waterGeometry = SCNBox(width: f.width, height: 0.03, length: f.height, chamferRadius: 0)
        let water = Self.material(0x1E8FA3).copy() as? SCNMaterial ?? SCNMaterial()
        waterGeometry.firstMaterial = water
        let waterNode = SCNNode(geometry: waterGeometry)
        waterNode.position = SCNVector3(0, 0.11, 0)
        node.addChildNode(waterNode)

        let part = RoomParts()
        part.water = water
        part.center = SCNVector3(Float(f.midX), elevation(of: room.level) + 0.13, Float(f.midY))

        let label = billboard(size: CGSize(width: 2.6, height: 0.72), in: node)
        label.node.position = SCNVector3(0, 0.75, 0)
        part.label = label.material
        part.labelNode = label.node
        part.labelSize = label.size
        parts[room.id] = part
        makeGlow(node, part)
    }

    // MARK: - Pieces

    /// `bottom` is the height of the base, to set furniture on the floor without arithmetic.
    @discardableResult
    private func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ color: UInt32,
                     x: CGFloat, bottom: CGFloat, z: CGFloat, in parent: SCNNode, chamfer: CGFloat = 0) -> SCNNode {
        let geometry = SCNBox(width: w, height: h, length: d, chamferRadius: chamfer)
        geometry.firstMaterial = Self.material(color)
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(x, bottom + h / 2, z)
        parent.addChildNode(node)
        return node
    }

    /// A label that always faces the camera, however the model turns.
    private func billboard(size: CGSize, in parent: SCNNode) -> (node: SCNNode, material: SCNMaterial, size: CGSize) {
        let label = labelPlane(size, in: parent)
        label.node.constraints = [SCNBillboardConstraint()]
        return label
    }

    private func labelPlane(_ size: CGSize, in parent: SCNNode) -> (node: SCNNode, material: SCNMaterial, size: CGSize) {
        let plane = SCNPlane(width: size.width, height: size.height)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.diffuse.contents = UIColor.clear
        plane.firstMaterial = material
        let node = SCNNode(geometry: plane)
        node.name = Self.labelName
        node.castsShadow = false
        parent.addChildNode(node)
        return (node, material, size)
    }

    /// Gives each piece of the room its own material with a warm glow, off by default.
    /// SceneKit lights are not used because they pass through walls and would light other rooms.
    private func makeGlow(_ node: SCNNode, _ part: RoomParts) {
        node.enumerateHierarchy { child, _ in
            guard child.name != Self.labelName, child.name != Self.keepName, let geometry = child.geometry else { return }
            let tall = (geometry as? SCNBox).map { $0.height > 1 } ?? false
            geometry.materials = geometry.materials.map { original in
                if part.lamps.contains(where: { $0 === original }) || part.water === original { return original }
                guard let own = original.copy() as? SCNMaterial,
                      let base = original.diffuse.contents as? UIColor else { return original }
                // Walls get more light higher up, near the lamp.
                own.emission.contents = tall ? Self.glowGradient(base) : Self.warmed(base, by: 0.72)
                own.emission.intensity = 0
                part.glow.append(own)
                return own
            }
        }
    }

    private static func warmed(_ color: UIColor, by amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: min(r * 1.05, 1) * amount, green: g * 0.84 * amount, blue: b * 0.56 * amount, alpha: 1)
    }

    private static func glowGradient(_ base: UIColor) -> UIImage {
        let size = CGSize(width: 2, height: 64)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [warmed(base, by: 1.05).cgColor, warmed(base, by: 0.5).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            context.cgContext.drawLinearGradient(gradient!, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    private static var cache: [UInt32: SCNMaterial] = [:]

    private static func material(_ hex: UInt32) -> SCNMaterial {
        if let cached = cache[hex] { return cached }
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor(hex: hex)
        cache[hex] = material
        return material
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
