import Foundation
import Observation

@MainActor
@Observable
final class HomeStore {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(String)
        /// No retry: the settings must be fixed first.
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var settings: ConnectionSettings?
    private(set) var entities: [String: HAEntity] = [:]
    private(set) var pending: Set<String> = []
    var errorMessage: String?

    @ObservationIgnored private var client: HAClient?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let makeTransport: @Sendable (URLRequest) -> WebSocketTransport

    init(
        settings: ConnectionSettings? = nil,
        persist: Bool = true,
        makeTransport: @escaping @Sendable (URLRequest) -> WebSocketTransport = { URLSessionTransport(request: $0) }
    ) {
        self.settings = settings ?? (persist ? KeychainStore.load() : nil)
        self.persist = persist
        self.makeTransport = makeTransport
    }

    var isConnected: Bool { status == .connected }

    // MARK: - Connection

    func start() {
        guard loop == nil, let settings else { return }
        loop = Task { await run(settings) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        let current = client
        client = nil
        Task { await current?.close() }
        status = .idle
    }

    func apply(settings newValue: ConnectionSettings) throws {
        _ = try newValue.webSocketRequest()
        if persist { try KeychainStore.save(newValue) }
        stop()
        settings = newValue
        start()
    }

    func signOut() {
        stop()
        if persist { KeychainStore.delete() }
        settings = nil
        entities = [:]
    }

    private func run(_ settings: ConnectionSettings) async {
        var attempt = 0
        status = .connecting
        while !Task.isCancelled {
            do {
                try await session(settings)
                attempt = 0
            } catch HAClient.ClientError.authFailed(let message) {
                status = .failed("Home Assistant rejected the token: \(message)")
                loop = nil
                return
            } catch let error as ConnectionError {
                status = .failed(error.localizedDescription)
                loop = nil
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = .reconnecting(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            let delays: [UInt64] = [1, 2, 5, 10, 30]
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
    }

    /// Lasts as long as one connection. It only returns by throwing.
    private func session(_ settings: ConnectionSettings) async throws {
        let request = try settings.webSocketRequest()
        let client = HAClient(transport: makeTransport(request))
        self.client = client
        defer { Task { await client.close() } }

        // If the server stops responding, closing the socket releases every waiter.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            await client.close()
        }
        defer { watchdog.cancel() }

        try await client.connect(token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines))
        // Subscribe before the initial snapshot, so no change between the two is lost.
        try await client.subscribeToStateChanges()
        let states: [HAEntity] = try await client.request("get_states").decoded()
        watchdog.cancel()

        entities = Dictionary(states.filter { House.trackedIDs.contains($0.entityID) }.map { ($0.entityID, $0) },
                              uniquingKeysWith: { a, _ in a })
        applyDebugOverrides()
        status = .connected

        let heartbeat = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                let timeout = Task {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    await client.close()
                }
                try? await client.ping()
                timeout.cancel()
            }
        }
        defer { heartbeat.cancel() }

        for await change in client.events { apply(change) }
        throw HAClient.ClientError.connectionClosed
    }

    private func apply(_ change: StateChange) {
        // The hundreds of other sensors change constantly and would redraw the house for nothing.
        guard House.trackedIDs.contains(change.entityID) else { return }
        guard let new = change.newState else {
            entities[change.entityID] = nil
            return
        }
        // A queued event may be older than the initial snapshot.
        if let current = entities[change.entityID], new.lastUpdated < current.lastUpdated { return }
        entities[change.entityID] = new
    }

    private func applyDebugOverrides() {
        #if DEBUG
        // On screen only, to review the design in the simulator without touching the real house.
        let env = ProcessInfo.processInfo.environment
        for id in (env["HA_DEBUG_ON"] ?? "").split(separator: ",").map(String.init) {
            if let e = entities[id] {
                entities[id] = HAEntity(entityID: id, state: "on", attributes: e.attributes, lastUpdated: e.lastUpdated)
            }
        }
        if let raw = env["HA_DEBUG_ELEVATION"], let elevation = Double(raw), let sun = entities[House.sunID] {
            var a = sun.attributes
            a["elevation"] = .number(elevation)
            entities[House.sunID] = HAEntity(entityID: House.sunID, state: sun.state, attributes: a, lastUpdated: sun.lastUpdated)
        }
        if let weather = env["HA_DEBUG_WEATHER"], let w = entities[House.weatherID] {
            entities[House.weatherID] = HAEntity(entityID: w.entityID, state: weather, attributes: w.attributes, lastUpdated: w.lastUpdated)
        }
        #endif
    }

    // MARK: - Actions

    func call(_ entity: HAEntity, service: String, data: [String: JSONValue] = [:]) async {
        guard let client, isConnected else {
            errorMessage = "Not connected to Home Assistant."
            return
        }
        pending.insert(entity.entityID)
        defer { pending.remove(entity.entityID) }
        do {
            try await client.callService(domain: entity.domain, service: service, entityID: entity.entityID, data: data)
        } catch {
            errorMessage = "\(entity.friendlyName): \(error.localizedDescription)"
        }
    }

    func turnOffAllLights() async {
        for entity in lightsOn { await call(entity, service: "turn_off") }
    }

    // MARK: - Reading

    var lightsOn: [HAEntity] {
        House.rooms.flatMap(\.lights).compactMap { entities[$0.entityID] }.filter(\.isOn)
    }

    func isLit(_ room: HouseRoom) -> Bool {
        room.lights.contains { entities[$0.entityID]?.isOn == true }
    }

    func temperature(of room: HouseRoom) -> Double? {
        room.climates.lazy.compactMap { self.entities[$0.entityID]?.attributes["current_temperature"]?.double }.first
    }

    func isHeating(_ room: HouseRoom) -> Bool {
        room.climates.contains {
            let state = entities[$0.entityID]?.state
            return state != nil && state != "off" && state != "unavailable" && state != "unknown"
        }
    }

    /// Current production in watts; nil if Home Assistant has no solar reading.
    var solarPower: Double? {
        let readings = House.solarIDs.compactMap { entities[$0].flatMap { Double($0.state) } }
        return readings.isEmpty ? nil : readings.reduce(0, +)
    }

    var solarPeak: Double? { entities[House.solarPeakID].flatMap { Double($0.state) } }

    /// Today's and yesterday's production, from the statistics Home Assistant keeps.
    func loadSolarDay(now: Date = Date(), calendar: Calendar = .current) async throws -> SolarDay {
        guard let client, isConnected else { throw HAClient.ClientError.connectionClosed }
        let midnight = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: midnight) ?? midnight
        // Today in 5-minute blocks: hourly statistics leave out the current hour.
        let today = try await solarRows(client, from: midnight, to: now, period: "5minute")
        let previous = try await solarRows(client, from: yesterday, to: midnight, period: "hour")
        return SolarDay(today: today, yesterday: previous, calendar: calendar)
    }

    private func solarRows(_ client: HAClient, from: Date, to: Date, period: String) async throws -> [SolarDay.Row] {
        let format = ISO8601DateFormatter()
        let result = try await client.request("recorder/statistics_during_period", [
            "start_time": .string(format.string(from: from)),
            "end_time": .string(format.string(from: to)),
            "period": .string(period),
            "statistic_ids": [.string(House.solarEnergyID)],
            "types": ["change"],
        ])
        return try result[House.solarEnergyID]?.decoded() ?? []
    }

    var batteryLevel: Double? { entities[House.batteryID].flatMap { Double($0.state) } }

    var sunElevation: Double { entities[House.sunID]?.attributes["elevation"]?.double ?? 30 }
    var weather: String { entities[House.weatherID]?.state ?? "" }
    var outsideTemperature: Double? { entities[House.weatherID]?.attributes["temperature"]?.double }
}
