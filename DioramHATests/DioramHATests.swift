import Foundation
import SceneKit
import Testing
@testable import DioramHA

// MARK: - Secure connection

@Suite struct ConnectionSettingsTests {
    private func settings(_ mode: ConnectionSettings.Mode, remote: String = "", local: String = "") -> ConnectionSettings {
        var s = ConnectionSettings()
        s.mode = mode
        s.remoteURL = remote
        s.localURL = local
        s.token = "t"
        return s
    }

    @Test func remoteUsesSecureWebSocket() throws {
        let r = try settings(.remote, remote: "https://home.example.com/").webSocketRequest()
        #expect(r.url?.absoluteString == "wss://home.example.com/api/websocket")
    }

    @Test func remoteRejectsPlainHTTP() {
        #expect(throws: ConnectionError.remoteMustUseHTTPS) {
            try settings(.remote, remote: "http://home.example.com").webSocketRequest()
        }
    }

    @Test func localAllowsHTTPOnlyOnPrivateHosts() throws {
        let r = try settings(.local, local: "http://homeassistant.local:8123").webSocketRequest()
        #expect(r.url?.absoluteString == "ws://homeassistant.local:8123/api/websocket")
        _ = try settings(.local, local: "http://192.168.1.10:8123").webSocketRequest()
        for host in ["http://8.8.8.8:8123", "http://home.example.com", "http://172.32.0.1", "http://192.168.1.10.evil.com"] {
            #expect(throws: ConnectionError.insecureLocalHost) {
                try settings(.local, local: host).webSocketRequest()
            }
        }
    }

    @Test func accessHeadersOnlyGoToCloudflare() throws {
        var s = settings(.remote, remote: "https://home.example.com", local: "http://homeassistant.local:8123")
        s.accessClientID = "id"
        s.accessClientSecret = "secret"
        let remote = try s.webSocketRequest()
        #expect(remote.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id")
        #expect(remote.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        s.mode = .local
        #expect(try s.webSocketRequest().value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func accessTokenMustBeComplete() {
        var s = settings(.remote, remote: "https://home.example.com")
        s.accessClientID = "id"
        #expect(throws: ConnectionError.incompleteAccessToken) { try s.webSocketRequest() }
    }

    @Test func tokenIsRequired() {
        var s = settings(.remote, remote: "https://home.example.com")
        s.token = "  "
        #expect(throws: ConnectionError.missingToken) { try s.webSocketRequest() }
    }
}

// MARK: - House

@Suite struct HouseTests {
    private var devices: [Device] { House.rooms.flatMap(\.devices) }

    @Test func eachDeviceAppearsOnce() {
        let ids = devices.map(\.entityID)
        #expect(ids.count == Set(ids).count)
    }

    @Test func doorsAndAppliancesAskForConfirmation() {
        // Every door or gate must ask for confirmation, whatever it is called in each home.
        let doors = devices.filter { device in
            if case .power(let symbol) = device.kind { symbol.hasPrefix("door") } else { false }
        }
        #expect(!doors.isEmpty)
        for door in doors { #expect(door.confirm, "\(door.entityID)") }
    }

    @Test func interiorRoomsDoNotOverlap() {
        let rooms = House.rooms.filter { $0.style == .interior }
        for (i, a) in rooms.enumerated() {
            for b in rooms[(i + 1)...] where a.floor == b.floor {
                #expect(a.frame.insetBy(dx: 0.001, dy: 0.001).intersects(b.frame) == false, "\(a.id) and \(b.id)")
            }
        }
    }
}

// MARK: - House file

@Suite struct HouseDocumentTests {
    private func bundledJSON() throws -> [String: Any] {
        let url = try #require(Bundle(for: HouseModel.self).url(forResource: "house", withExtension: "json"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func read(_ edit: (inout [String: Any]) -> Void) throws -> HouseDocument {
        var json = try bundledJSON()
        edit(&json)
        return try HouseDocument(data: JSONSerialization.data(withJSONObject: json))
    }

    @Test func theExampleHouseIsValid() throws {
        let document = try read { _ in }
        #expect(document.name == "Example Home")
        #expect(!document.rooms.flatMap(\.devices).isEmpty)
        #expect(document.rooms.contains { !$0.furniture.isEmpty })
    }

    /// Doors must not lose their confirmation when loaded from the file.
    @Test func confirmationSurvivesTheDocument() throws {
        let garage = try #require(try read { _ in }.rooms.first { $0.id == "garage" })
        #expect(garage.devices.filter(\.confirm).count == 2)
    }

    @Test func rejectsAVersionItDoesNotKnow() {
        #expect(throws: HouseDocument.Problem.unsupportedVersion(99)) {
            try read { $0["version"] = 99 }
        }
    }

    @Test func rejectsDuplicatedRooms() {
        #expect(throws: HouseDocument.Problem.duplicateRoom("main_bedroom")) {
            try read { json in
                var rooms = json["rooms"] as? [[String: Any]] ?? []
                rooms.append(rooms[0])
                json["rooms"] = rooms
            }
        }
    }

    @Test func rejectsFurnitureOutsideTheCatalog() {
        #expect(throws: DecodingError.self) {
            try read { json in
                var rooms = json["rooms"] as? [[String: Any]] ?? []
                rooms[0]["furniture"] = [["type": "spaceship", "x": 0, "z": 0]]
                json["rooms"] = rooms
            }
        }
    }
}

// MARK: - Solar production

@Suite struct SolarDayTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    private func row(_ hour: Int, _ minute: Int, _ change: Double?) -> SolarDay.Row {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: hour, minute: minute))!
        return SolarDay.Row(start: date.timeIntervalSince1970 * 1000, change: change)
    }

    @Test func addsBlocksPerLocalHourAndTotals() {
        let day = SolarDay(today: [row(9, 0, 0.1), row(9, 5, 0.2), row(13, 0, 1.0), row(14, 0, nil)],
                           yesterday: [row(12, 0, 2.0), row(13, 0, 6.4)], calendar: calendar)
        #expect(abs(day.energy(at: 9) - 0.3) < 0.0001)
        #expect(day.energy(at: 10) == 0)
        #expect(abs(day.todayTotal - 1.3) < 0.0001)
        #expect(abs(day.yesterdayTotal - 8.4) < 0.0001)
        #expect(day.best?.hour == 13)
    }

    /// A reset counter must not subtract from the day's production.
    @Test func ignoresCounterResets() {
        let day = SolarDay(today: [row(9, 0, 1.0), row(9, 5, -6000)], yesterday: [], calendar: calendar)
        #expect(day.todayTotal == 1.0)
    }

    @Test func aDayWithoutSunHasNoBestHour() {
        #expect(SolarDay(today: [row(2, 0, 0)], yesterday: [], calendar: calendar).best == nil)
    }

    @Test func formatsPowerAndEnergy() {
        #expect(SolarFormat.power(4) == "4 W")
        #expect(SolarFormat.power(1500) == "1.5 kW")
        #expect(SolarFormat.energy(3.8) == "3.8 kWh")
    }
}

// MARK: - 3D model

@MainActor
@Suite struct HouseModelTests {
    /// Tapping where a room is visible must open that room, not the one next to it.
    @Test func tappingEachRoomSelectsIt() {
        let model = HouseModel()
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.scene = model.scene
        view.pointOfView = model.cameraNode
        model.fit(to: view.bounds.size)
        for room in House.rooms {
            let point = view.projectPoint(model.tapTarget(for: room))
            let tapped = model.roomID(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), in: view)
            #expect(tapped == room.id, "\(room.id)")
        }
    }

    /// Inside a room, the floors above must not catch taps.
    @Test func floorsAboveTheFocusedRoomDoNotCatchTaps() throws {
        let model = HouseModel()
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.scene = model.scene
        view.pointOfView = model.cameraNode
        model.fit(to: view.bounds.size)
        model.focus(on: "kitchen")
        let kitchen = try #require(House.rooms.first { $0.id == "kitchen" })
        let point = view.projectPoint(model.tapTarget(for: kitchen))
        #expect(model.roomID(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), in: view) == "kitchen")
    }

    @Test func focusingARoomFliesCloserAndBackHome() {
        let model = HouseModel()
        model.fit(to: CGSize(width: 402, height: 874))
        let home = model.cameraDistance
        model.focus(on: "living")
        #expect(model.cameraDistance < home * 0.7)
        model.focus(on: nil)
        #expect(model.cameraDistance == home)
    }

    @Test func zoomStaysWithinLimits() {
        let model = HouseModel()
        model.fit(to: CGSize(width: 402, height: 874))
        let home = model.cameraDistance
        for _ in 0..<50 { model.pinch(by: 1.5) }
        #expect(model.cameraDistance >= home / 4.51)
        for _ in 0..<50 { model.pinch(by: 0.5) }
        #expect(model.cameraDistance <= home / 0.79)
    }

    /// A light that is on must not light any other room.
    @Test func lightOnlyAffectsItsOwnRoom() {
        let model = HouseModel()
        var snapshot = HouseSnapshot.empty
        snapshot.rooms["living"] = .init(lit: true)
        model.apply(snapshot)
        #expect(!model.glowLevels(of: "living").isEmpty)
        #expect(model.glowLevels(of: "living").allSatisfy { $0 == 1 })
        for room in House.rooms where room.id != "living" {
            #expect(model.glowLevels(of: room.id).allSatisfy { $0 == 0 }, "\(room.id)")
        }
        snapshot.rooms["living"] = .init(lit: false)
        model.apply(snapshot)
        #expect(model.glowLevels(of: "living").allSatisfy { $0 == 0 })
    }

    @Test func snapshotUpdateIsAppliedWithoutCrashing() {
        let model = HouseModel()
        var snapshot = HouseSnapshot.empty
        snapshot.rooms["living"] = .init(lit: true, temperature: 21, heating: true, blind: 40)
        snapshot.elevation = -30
        model.apply(snapshot)
        model.apply(snapshot)
    }
}

// MARK: - WebSocket protocol

/// Fake server: answers each message with the closure and records what was sent.
private final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var _sent: [JSONValue] = []
    private let responder: @Sendable (JSONValue) -> [String]

    init(responder: @escaping @Sendable (JSONValue) -> [String]) {
        self.responder = responder
        deliver(#"{"type":"auth_required"}"#)
    }

    var sent: [JSONValue] { lock.withLock { _sent } }

    func deliver(_ text: String) {
        let w: CheckedContinuation<String, Error>? = lock.withLock {
            if let w = waiter { waiter = nil; return w }
            inbox.append(text)
            return nil
        }
        w?.resume(returning: text)
    }

    func send(_ text: String) async throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        lock.withLock { _sent.append(message) }
        responder(message).forEach(deliver)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            let action: (String?, Bool) = lock.withLock {
                if !inbox.isEmpty { return (inbox.removeFirst(), false) }
                if closed { return (nil, true) }
                waiter = c
                return (nil, false)
            }
            if let text = action.0 { c.resume(returning: text) }
            else if action.1 { c.resume(throwing: HAClient.ClientError.connectionClosed) }
        }
    }

    func closeForTest() async { close() }

    func close() {
        let w: CheckedContinuation<String, Error>? = lock.withLock {
            closed = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume(throwing: HAClient.ClientError.connectionClosed)
    }
}

@Suite struct HAClientTests {
    private func okResponder(_ m: JSONValue) -> [String] {
        switch m["type"]?.string {
        case "auth": [#"{"type":"auth_ok"}"#]
        default: [#"{"id":\#(m["id"]?.int ?? 0),"type":"result","success":true,"result":null}"#]
        }
    }

    @Test func invalidTokenIsReported() async {
        let client = HAClient(transport: FakeTransport { _ in [#"{"type":"auth_invalid","message":"bad"}"#] })
        await #expect(throws: HAClient.ClientError.authFailed("bad")) { try await client.connect(token: "x") }
    }

    @Test func callServiceSendsExpectedMessage() async throws {
        let responder = okResponder
        let transport = FakeTransport { responder($0) }
        let client = HAClient(transport: transport)
        try await client.connect(token: "secret")
        try await client.callService(domain: "light", service: "turn_on", entityID: "light.sofa", data: ["brightness_pct": 50])

        #expect(transport.sent[0]["access_token"]?.string == "secret")
        let call = transport.sent[1]
        #expect(call["type"]?.string == "call_service")
        #expect(call["domain"]?.string == "light")
        #expect(call["service"]?.string == "turn_on")
        #expect(call["target"]?["entity_id"]?.string == "light.sofa")
        #expect(call["service_data"]?["brightness_pct"]?.int == 50)
        await client.close()
    }

    @Test func serverErrorIsThrown() async throws {
        let transport = FakeTransport { m in
            m["type"]?.string == "auth"
                ? [#"{"type":"auth_ok"}"#]
                : [#"{"id":\#(m["id"]?.int ?? 0),"type":"result","success":false,"error":{"code":"not_found","message":"nope"}}"#]
        }
        let client = HAClient(transport: transport)
        try await client.connect(token: "x")
        await #expect(throws: HAClient.ClientError.server(code: "not_found", message: "nope")) {
            try await client.callService(domain: "light", service: "x", entityID: "light.a", data: [:])
        }
        await client.close()
    }

    @Test func stateEventsAreDelivered() async throws {
        let responder = okResponder
        let transport = FakeTransport { responder($0) }
        let client = HAClient(transport: transport)
        try await client.connect(token: "x")
        transport.deliver(#"{"id":1,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"light.a","new_state":{"entity_id":"light.a","state":"on","attributes":{"brightness":128},"last_updated":"2026"}}}}"#)
        var iterator = client.events.makeAsyncIterator()
        let change = await iterator.next()
        #expect(change?.newState?.isOn == true)
        #expect(change?.newState?.attributes["brightness"]?.int == 128)
        await client.close()
    }

    @Test func closingFailsPendingRequests() async throws {
        let transport = FakeTransport { m in m["type"]?.string == "auth" ? [#"{"type":"auth_ok"}"#] : [] }
        let client = HAClient(transport: transport)
        try await client.connect(token: "x")
        let waiting = Task { try await client.ping() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.close()
        await #expect(throws: HAClient.ClientError.connectionClosed) { try await waiting.value }
    }
}

// MARK: - Store

@MainActor
@Suite struct HomeStoreTests {
    private func connectedStore() async throws -> (HomeStore, FakeTransport) {
        let transport = FakeTransport { m in
            let id = m["id"]?.int ?? 0
            switch m["type"]?.string {
            case "auth": return [#"{"type":"auth_ok"}"#]
            case "recorder/statistics_during_period":
                let thirteen = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!.timeIntervalSince1970 * 1000
                return [#"{"id":\#(id),"type":"result","success":true,"result":{"\#(House.solarEnergyID)":[{"start":\#(thirteen),"change":0.5},{"start":\#(thirteen + 300000),"change":0.25}]}}"#]
            case "get_states": return [#"{"id":\#(id),"type":"result","success":true,"result":[{"entity_id":"light.living_room_sofa_light","state":"on","attributes":{},"last_updated":"1"},{"entity_id":"light.pool_light","state":"off","attributes":{},"last_updated":"1"},{"entity_id":"sensor.noise","state":"1","attributes":{},"last_updated":"1"},{"entity_id":"\#(House.solarIDs[0])","state":"1200","attributes":{},"last_updated":"1"},{"entity_id":"\#(House.solarIDs[1])","state":"300","attributes":{},"last_updated":"1"},{"entity_id":"\#(House.batteryID)","state":"64","attributes":{},"last_updated":"1"}]}"#]
            default: return [#"{"id":\#(id),"type":"result","success":true,"result":null}"#]
            }
        }
        var settings = ConnectionSettings()
        settings.token = "x"
        let store = HomeStore(settings: settings, persist: false, makeTransport: { _ in transport })
        store.start()
        for _ in 0..<200 where !store.isConnected { try await Task.sleep(nanoseconds: 10_000_000) }
        return (store, transport)
    }

    @Test func keepsOnlyWhatTheHouseShows() async throws {
        let (store, _) = try await connectedStore()
        #expect(store.isConnected)
        #expect(store.entities["sensor.noise"] == nil)
        #expect(store.lightsOn.map(\.entityID) == ["light.living_room_sofa_light"])
        #expect(store.isLit(try #require(House.rooms.first { $0.id == "living" })))
        store.stop()
    }

    @Test func solarAddsBothSourcesAndReadsBattery() async throws {
        let (store, _) = try await connectedStore()
        #expect(store.solarPower == 1500)
        #expect(store.batteryLevel == 64)
        #expect(store.snapshot.solarPower == 1500)
        store.stop()
    }

    @Test func solarDayAsksForTheEnergySource() async throws {
        let (store, transport) = try await connectedStore()
        let day = try await store.loadSolarDay()
        #expect(day.todayTotal == 0.75)
        #expect(day.best?.hour == 13)
        let request = transport.sent.last { $0["type"]?.string == "recorder/statistics_during_period" }
        #expect(request?["statistic_ids"]?.array?.first?.string == House.solarEnergyID)
        store.stop()
    }

    @Test func allOffOnlyTouchesLightsThatAreOn() async throws {
        let (store, transport) = try await connectedStore()
        await store.turnOffAllLights()
        let calls = transport.sent.filter { $0["type"]?.string == "call_service" }
        #expect(calls.count == 1)
        #expect(calls[0]["service"]?.string == "turn_off")
        #expect(calls[0]["target"]?["entity_id"]?.string == "light.living_room_sofa_light")
        #expect(store.pending.isEmpty)
        store.stop()
    }

    @Test func serviceFailureIsShownToTheUser() async throws {
        let (store, transport) = try await connectedStore()
        await transport.closeForTest()
        for _ in 0..<200 where store.isConnected { try await Task.sleep(nanoseconds: 10_000_000) }
        await store.call(HAEntity(entityID: "light.pool_light", state: "off"), service: "turn_on")
        #expect(store.errorMessage != nil)
        store.stop()
    }
}
