import SceneKit
import SwiftUI

/// What the model needs to know about the house. Being comparable, the 3D scene is only
/// touched when something visible has really changed.
struct HouseSnapshot: Equatable {
    struct RoomState: Equatable {
        var lit = false
        var temperature: Int?
        var heating = false
        var blind: Double?
    }

    var rooms: [String: RoomState] = [:]
    var elevation: Double = 30
    var pergolaClosed = false
    var solarPower: Double = 0

    static let empty = HouseSnapshot()
}

extension HomeStore {
    var snapshot: HouseSnapshot {
        var result = HouseSnapshot()
        result.elevation = sunElevation
        // Rounded so the house is not redrawn for every watt.
        result.solarPower = ((solarPower ?? 0) / 100).rounded() * 100
        let pergola = House.rooms.first { $0.style == .terrace }?.blinds.first
        result.pergolaClosed = pergola.flatMap { entities[$0.entityID] }?.state == "closed"
        for room in House.rooms {
            let blind = room.style == .interior ? room.blinds.first.flatMap { entities[$0.entityID] } : nil
            result.rooms[room.id] = .init(
                lit: isLit(room),
                temperature: temperature(of: room).map { Int($0.rounded()) },
                heating: isHeating(room),
                blind: blind.map { $0.attributes["current_position"]?.double ?? ($0.state == "closed" ? 0 : 100) })
        }
        return result
    }
}

/// The main screen: the 3D house over the real sky.
struct HouseScene: View {
    @Environment(HomeStore.self) private var store
    let focusedRoomID: String?
    let onSelect: (HouseRoom) -> Void

    var body: some View {
        let rainy = ["rainy", "pouring", "lightning-rainy", "snowy-rainy"].contains(store.weather)
        ZStack {
            SkyLayer(phase: DayPhase(elevation: store.sunElevation), elevation: store.sunElevation, rainy: rainy)
            HouseSceneView(snapshot: store.snapshot, focusedRoomID: focusedRoomID, onSelect: onSelect)
                .accessibilityRepresentation {
                    VStack {
                        ForEach(House.rooms) { room in
                            Button(description(room)) { onSelect(room) }
                        }
                    }
                }
        }
    }

    private func description(_ room: HouseRoom) -> String {
        var parts = [room.name]
        if !room.lights.isEmpty { parts.append(store.isLit(room) ? "light on" : "light off") }
        if let t = store.temperature(of: room) { parts.append("\(Int(t.rounded())) degrees") }
        return parts.joined(separator: ", ")
    }
}

private struct HouseSceneView: UIViewRepresentable {
    let snapshot: HouseSnapshot
    let focusedRoomID: String?
    let onSelect: (HouseRoom) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = FittingSCNView(frame: .zero, options: nil)
        view.model = context.coordinator.model
        view.scene = context.coordinator.model.scene
        view.pointOfView = context.coordinator.model.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        // No continuous loop: it only draws when something changes, to save battery.
        view.rendersContinuously = false
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned))
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)
        let shift = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.shifted))
        shift.minimumNumberOfTouches = 2
        view.addGestureRecognizer(shift)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched)))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.model.focus(on: focusedRoomID)
        if context.coordinator.last != snapshot {
            context.coordinator.last = snapshot
            context.coordinator.model.apply(snapshot)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let model = HouseModel()
        var last: HouseSnapshot?
        var onSelect: ((HouseRoom) -> Void)?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView,
                  let id = model.roomID(at: gesture.location(in: view), in: view),
                  let room = House.rooms.first(where: { $0.id == id }) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onSelect?(room)
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            model.orbit(dx: Float(delta.x), dy: Float(delta.y))
        }

        @objc func shifted(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            model.shift(dx: delta.x, dy: delta.y)
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            model.pinch(by: gesture.scale)
            gesture.scale = 1
        }
    }
}

private final class FittingSCNView: SCNView {
    var model: HouseModel?

    override func layoutSubviews() {
        super.layoutSubviews()
        model?.fit(to: bounds.size)
    }
}
