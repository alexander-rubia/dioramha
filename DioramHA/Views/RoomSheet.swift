import SwiftUI

/// What can be done in a room, and nothing else.
struct RoomSheet: View {
    @Environment(HomeStore.self) private var store
    let room: HouseRoom

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        if room.style == .solar {
            SolarSheet()
        } else {
            devicesView
        }
    }

    private var devicesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(room.name)
                    .font(Type.light(38))
                    .foregroundStyle(Color.lamplight)

                let tiles = room.devices.filter { !isWide($0) }
                if !tiles.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(tiles) { PowerTile(device: $0) }
                    }
                }
                ForEach(room.devices.filter(isWide)) { device in
                    switch device.kind {
                    case .blind: BlindCard(device: device)
                    case .climate(let modes): ClimateCard(device: device, modes: modes)
                    case .vacuum: VacuumCard(device: device)
                    default: EmptyView()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .alert("That didn't work", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func isWide(_ device: Device) -> Bool {
        switch device.kind {
        case .light, .power: false
        default: true
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.lamplight)
            .background(Color.inkRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Lights and plugs

private struct PowerTile: View {
    @Environment(HomeStore.self) private var store
    let device: Device
    @State private var confirming = false

    private var entity: HAEntity? { store.entities[device.entityID] }
    private var isOn: Bool { entity?.isOn == true }
    private var isOffline: Bool { entity?.isUnavailable ?? true }

    private var symbol: String {
        if case .power(let symbol) = device.kind { return symbol }
        return isOn ? "lightbulb.fill" : "lightbulb"
    }

    var body: some View {
        Button {
            if device.confirm { confirming = true } else { toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 24))
                    Spacer()
                    if store.pending.contains(device.entityID) { ProgressView().tint(isOn ? Color.ink : Color.lamplight) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(Type.strong(17)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(stateText).font(Type.regular(14)).opacity(0.75)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .foregroundStyle(isOn ? Color.ink : Color.lamplight)
            .background(isOn ? Color.lamp : Color.inkRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(isOffline ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isOffline || !store.isConnected)
        .accessibilityValue(stateText)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .confirmationDialog("\(verb) \(device.name.lowercased())?", isPresented: $confirming, titleVisibility: .visible) {
            Button(verb, role: .destructive) { toggle() }
        }
    }

    /// The state of these switches does not tell whether the door is open or closed.
    private var isDoor: Bool {
        device.entityID.contains("door") || device.entityID.contains("gate")
    }

    private var verb: String {
        isDoor ? "Operate" : isOn ? "Turn off" : "Turn on"
    }

    private var stateText: String {
        if isOffline { return "Offline" }
        if isDoor { return "Tap to operate" }
        return isOn ? "On" : "Off"
    }

    private func toggle() {
        guard let entity else { return }
        Task { await store.call(entity, service: isOn ? "turn_off" : "turn_on") }
    }
}

// MARK: - Blinds

private struct BlindCard: View {
    @Environment(HomeStore.self) private var store
    let device: Device
    @State private var draft: Double?

    var body: some View {
        if let entity = store.entities[device.entityID] {
            Card {
                HStack(spacing: 16) {
                    if entity.supports(4) { window(entity) }
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(Type.strong(17))
                            Text(stateText(entity)).font(Type.regular(14)).opacity(0.75)
                        }
                        HStack(spacing: 8) {
                            action("Raise", "chevron.up", "open_cover", entity)
                            action("Stop", "stop.fill", "stop_cover", entity)
                            action("Lower", "chevron.down", "close_cover", entity)
                        }
                    }
                }
            }
            .disabled(entity.isUnavailable || !store.isConnected)
            .opacity(entity.isUnavailable ? 0.5 : 1)
        }
    }

    /// The blind is dragged directly; the command is sent on release.
    private func window(_ entity: HAEntity) -> some View {
        let height: CGFloat = 104
        let position = draft ?? entity.attributes["current_position"]?.double ?? 0
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x7FB8E0), Color(hex: 0xD6ECF4)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { _ in Rectangle().fill(Color.lamplight).frame(height: 4) }
            }
            .frame(height: height * CGFloat(1 - position / 100), alignment: .top)
            .clipped()
        }
        .frame(width: 78, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.lamplight, lineWidth: 3))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                draft = min(max(100 - Double(value.location.y / height) * 100, 0), 100)
            }
            .onEnded { _ in
                guard let target = draft else { return }
                Task {
                    await store.call(entity, service: "set_cover_position", data: ["position": .number(target.rounded())])
                    draft = nil
                }
            })
        .accessibilityLabel("Blind height")
        .accessibilityValue("\(Int(position)) percent")
    }

    private func action(_ title: String, _ icon: String, _ service: String, _ entity: HAEntity) -> some View {
        Button {
            Task { await store.call(entity, service: service) }
        } label: {
            Image(systemName: icon)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color.inkLine, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func stateText(_ entity: HAEntity) -> String {
        if entity.isUnavailable { return "Offline" }
        if let draft { return "\(Int(draft))%" }
        switch entity.state {
        case "opening": return "Opening…"
        case "closing": return "Closing…"
        case "closed": return "Closed"
        default: return entity.attributes["current_position"]?.int.map { "Open \($0)%" } ?? "Open"
        }
    }
}

// MARK: - Climate

private struct ClimateCard: View {
    @Environment(HomeStore.self) private var store
    let device: Device
    let modes: [String]
    @State private var draft: Double?
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        if let entity = store.entities[device.entityID] {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(device.name).font(Type.strong(17))
                        Spacer()
                        if let now = entity.attributes["current_temperature"]?.double {
                            Text("Now \(now, specifier: "%.1f")°").font(Type.regular(15)).monospacedDigit().opacity(0.75)
                        }
                    }
                    if entity.state != "off" { target(entity) }
                    modePicker(entity)
                }
            }
            .disabled(entity.isUnavailable || !store.isConnected)
            .opacity(entity.isUnavailable ? 0.5 : 1)
        }
    }

    private func target(_ entity: HAEntity) -> some View {
        let low = entity.attributes["min_temp"]?.double ?? 5
        let high = entity.attributes["max_temp"]?.double ?? 35
        let value = draft ?? entity.attributes["temperature"]?.double ?? low
        return HStack {
            stepButton("minus", "Lower temperature", enabled: value > low) { change(entity, to: max(value - 0.5, low)) }
            Spacer()
            Text("\(value, specifier: "%.1f")°").font(Type.light(46)).monospacedDigit()
            Spacer()
            stepButton("plus", "Raise temperature", enabled: value < high) { change(entity, to: min(value + 0.5, high)) }
        }
    }

    private func stepButton(_ icon: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 52, height: 52)
                .background(Color.inkLine, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    /// Groups quick taps into a single thermostat command.
    private func change(_ entity: HAEntity, to value: Double) {
        draft = value
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await store.call(entity, service: "set_temperature", data: ["temperature": .number(value)])
            draft = nil
        }
    }

    private func modePicker(_ entity: HAEntity) -> some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.self) { mode in
                let selected = entity.state == mode
                Button {
                    Task { await store.call(entity, service: "set_hvac_mode", data: ["hvac_mode": .string(mode)]) }
                } label: {
                    Text(Self.label(mode))
                        .font(Type.strong(15))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(selected ? Color.ink : Color.lamplight)
                        .background(selected ? Color.lamp : Color.inkLine, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private static func label(_ mode: String) -> String {
        switch mode {
        case "off": "Off"
        case "heat": "Heat"
        case "cool": "Cool"
        case "auto": "Auto"
        default: mode
        }
    }
}

// MARK: - Vacuum

private struct VacuumCard: View {
    @Environment(HomeStore.self) private var store
    let device: Device

    var body: some View {
        if let entity = store.entities[device.entityID] {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(Type.strong(17))
                        Text(stateText(entity.state)).font(Type.regular(14)).opacity(0.75)
                    }
                    Spacer()
                    let cleaning = entity.state == "cleaning"
                    Button(cleaning ? "Dock" : "Clean") {
                        Task { await store.call(entity, service: cleaning ? "return_to_base" : "start") }
                    }
                    .font(Type.strong(16))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Color.lamp, in: Capsule())
                    .buttonStyle(.plain)
                }
            }
            .disabled(entity.isUnavailable || !store.isConnected)
            .opacity(entity.isUnavailable ? 0.5 : 1)
        }
    }

    private func stateText(_ state: String) -> String {
        switch state {
        case "docked": "Docked"
        case "cleaning": "Cleaning"
        case "returning": "Returning to dock"
        case "paused": "Paused"
        case "error": "Needs attention"
        case "unavailable", "unknown": "Offline"
        default: "Idle"
        }
    }
}
