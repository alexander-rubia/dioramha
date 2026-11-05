import SwiftUI

struct RootView: View {
    @Environment(HomeStore.self) private var store

    var body: some View {
        Group {
            if store.settings == nil {
                ConnectionForm(isFirstRun: true)
            } else {
                HomeView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(.lamp)
    }
}

struct HomeView: View {
    @Environment(HomeStore.self) private var store
    @State private var room: HouseRoom?
    @State private var showSettings = false
    @State private var showAlarm = false
    @State private var confirmLightsOff = false

    var body: some View {
        ZStack(alignment: .bottom) {
            HouseScene(focusedRoomID: room?.id) { room = $0 }
                .ignoresSafeArea()
            dock
        }
        .overlay(alignment: .top) { banner }
        .background(Color.ink)
        .sheet(item: $room) { room in
            // Solar needs more height, so the chart shows without scrolling.
            let resting: PresentationDetent = room.style == .solar ? .fraction(0.72) : .medium
            RoomSheet(room: room)
                .presentationDetents([resting, .large])
                .presentationBackground(Color.ink)
                // The house is not dimmed: it stays visible, and another room can be tapped.
                .presentationBackgroundInteraction(.enabled(upThrough: resting))
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { ConnectionForm(isFirstRun: false) }
        }
        .confirmationDialog(alarmTitle, isPresented: $showAlarm, titleVisibility: .visible) { alarmOptions }
        .confirmationDialog("Turn off \(store.lightsOn.count == 1 ? "the light that is on" : "the \(store.lightsOn.count) lights that are on")?",
                            isPresented: $confirmLightsOff, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { Task { await store.turnOffAllLights() } }
        }
        .alert("That didn't work", isPresented: Binding(
            get: { store.errorMessage != nil && room == nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        #if DEBUG
        .onChange(of: store.isConnected) { _, connected in
            if connected, let id = ProcessInfo.processInfo.environment["HA_DEBUG_ROOM"] {
                room = House.rooms.first { $0.id == id }
            }
        }
        #endif
    }

    @ViewBuilder
    private var banner: some View {
        switch store.status {
        case .connected, .idle:
            EmptyView()
        case .connecting:
            bannerText("Connecting to your home…")
        case .reconnecting(let reason):
            bannerText("Offline. \(reason)")
        case .failed(let reason):
            Button { showSettings = true } label: { bannerText(reason) }
        }
    }

    private func bannerText(_ text: String) -> some View {
        Text(text)
            .font(Type.regular(14))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.ink.opacity(0.85), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 6)
    }

    // MARK: - Bottom dock

    private var dock: some View {
        let on = store.lightsOn.count
        return VStack(spacing: 10) {
            HStack(spacing: 14) {
                Label("\(on)", systemImage: on > 0 ? "lightbulb.fill" : "lightbulb")
                    .accessibilityLabel(on == 0 ? "All lights off" : on == 1 ? "1 light on" : "\(on) lights on")
                if let power = store.solarPower {
                    Button { room = House.rooms.first { $0.style == .solar } } label: {
                        Label(SolarFormat.power(power), systemImage: "sun.max.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Solar panels producing \(SolarFormat.power(power))")
                }
                if let battery = store.batteryLevel {
                    Label("\(Int(battery.rounded()))%", systemImage: battery < 20 ? "battery.25percent" : "battery.75percent")
                        .accessibilityLabel("Battery at \(Int(battery.rounded())) percent")
                }
                if let t = store.outsideTemperature {
                    Label("\(t, specifier: "%.0f")°", systemImage: "thermometer.medium")
                        .accessibilityLabel("\(Int(t.rounded())) degrees outside")
                }
                Spacer(minLength: 0)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").frame(width: 32, height: 28, alignment: .trailing)
                }
                .accessibilityLabel("Settings")
            }
            .labelStyle(CompactLabelStyle())
            .font(Type.regular(15))
            .monospacedDigit()
            .foregroundStyle(Color.lamplight)

            HStack(spacing: 8) {
                DockButton(title: "Alarm", symbol: alarmArmed ? "shield.fill" : "shield", active: alarmArmed) { showAlarm = true }
                    .accessibilityValue(alarmState)
                DockButton(title: "Garage", symbol: "door.garage.closed", active: false) {
                    room = House.rooms.first { $0.id == "garage" }
                }
                DockButton(title: "All off", symbol: "lightbulb.slash", active: false) {
                    confirmLightsOff = true
                }
                .disabled(on == 0)
                .opacity(on == 0 ? 0.45 : 1)
                .accessibilityLabel("Turn off the whole house")
            }
            .disabled(!store.isConnected)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var alarm: HAEntity? { store.entities[House.alarmID] }
    private var alarmArmed: Bool { (alarm?.state ?? "disarmed") != "disarmed" && alarm?.isUnavailable == false }
    private var alarmTitle: String { "Alarm: \(alarmState.lowercased())" }

    private var alarmState: String {
        switch alarm?.state {
        case "disarmed": "Disarmed"
        case "armed_home": "Armed, home"
        case "armed_away": "Armed, away"
        case "armed_night": "Armed, night"
        case "arming": "Arming…"
        case "pending": "Entry detected"
        case "triggered": "Triggered!"
        default: "Unavailable"
        }
    }

    @ViewBuilder
    private var alarmOptions: some View {
        if let alarm, !alarm.isUnavailable {
            if alarm.state == "disarmed" {
                Button("Arm: I'm home") { Task { await store.call(alarm, service: "alarm_arm_home") } }
                Button("Arm: I'm leaving") { Task { await store.call(alarm, service: "alarm_arm_away") } }
            } else {
                Button("Disarm", role: .destructive) { Task { await store.call(alarm, service: "alarm_disarm") } }
            }
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(Color.lamp)
            configuration.title
        }
    }
}

private struct DockButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(Type.strong(14)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(active ? Color.ink : Color.lamplight)
            .background(active ? Color.lamp : Color.inkRaised.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
