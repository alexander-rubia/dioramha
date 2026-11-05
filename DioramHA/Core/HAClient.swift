import Foundation

protocol WebSocketTransport: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

final class URLSessionTransport: WebSocketTransport {
    // No cache or cookies on disk.
    private static let session = URLSession(configuration: .ephemeral)
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = Self.session.webSocketTask(with: request)
        // The default limit (1 MB) is smaller than the get_states response.
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw HAClient.ClientError.unexpectedMessage
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Client for the Home Assistant WebSocket API.
actor HAClient {
    enum ClientError: LocalizedError, Equatable {
        case authFailed(String)
        case connectionClosed
        case unexpectedMessage
        case server(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .authFailed(let m): "Home Assistant rejected the token: \(m)"
            case .connectionClosed: "The connection was lost."
            case .unexpectedMessage: "Unexpected response from Home Assistant."
            case .server(_, let m): m
            }
        }
    }

    nonisolated let events: AsyncStream<StateChange>
    private let eventsContinuation: AsyncStream<StateChange>.Continuation
    private let transport: WebSocketTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var isClosed = false

    init(transport: WebSocketTransport) {
        self.transport = transport
        (events, eventsContinuation) = AsyncStream.makeStream(of: StateChange.self)
    }

    func connect(token: String) async throws {
        guard try await readMessage()["type"]?.string == "auth_required" else {
            throw ClientError.unexpectedMessage
        }
        let auth: JSONValue = ["type": "auth", "access_token": .string(token)]
        try await transport.send(try Self.encode(auth))
        let reply = try await readMessage()
        switch reply["type"]?.string {
        case "auth_ok":
            Task { await self.readLoop() }
        case "auth_invalid":
            throw ClientError.authFailed(reply["message"]?.string ?? "invalid token")
        default:
            throw ClientError.unexpectedMessage
        }
    }

    func request(_ type: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard !isClosed else { throw ClientError.connectionClosed }
        let id = nextID
        nextID += 1
        var message = fields
        message["id"] = .number(Double(id))
        message["type"] = .string(type)
        let text = try Self.encode(.object(message))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await transport.send(text) }
                catch { resolve(id, .failure(error)) }
            }
        }
    }

    func callService(domain: String, service: String, entityID: String, data: [String: JSONValue]) async throws {
        _ = try await request("call_service", [
            "domain": .string(domain),
            "service": .string(service),
            "service_data": .object(data),
            "target": ["entity_id": .string(entityID)],
        ])
    }

    func subscribeToStateChanges() async throws {
        _ = try await request("subscribe_events", ["event_type": "state_changed"])
    }

    func ping() async throws { _ = try await request("ping") }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        transport.close()
        finish(with: ClientError.connectionClosed)
    }

    // MARK: - Reading

    private func readLoop() async {
        do {
            while true { handle(try await readMessage()) }
        } catch {
            transport.close()
            isClosed = true
            finish(with: ClientError.connectionClosed)
        }
    }

    private func readMessage() async throws -> JSONValue {
        let text = try await transport.receive()
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func handle(_ message: JSONValue) {
        switch message["type"]?.string {
        case "result":
            guard let id = message["id"]?.int else { return }
            if message["success"]?.bool == true {
                resolve(id, .success(message["result"] ?? .null))
            } else {
                resolve(id, .failure(ClientError.server(
                    code: message["error"]?["code"]?.string ?? "unknown",
                    message: message["error"]?["message"]?.string ?? "Unknown error")))
            }
        case "pong":
            if let id = message["id"]?.int { resolve(id, .success(.null)) }
        case "event":
            guard let data = message["event"]?["data"],
                  let entityID = data["entity_id"]?.string else { return }
            let newState = data["new_state"].flatMap { try? $0.decoded(as: HAEntity.self) }
            eventsContinuation.yield(StateChange(entityID: entityID, newState: newState))
        default:
            break
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func finish(with error: Error) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
        eventsContinuation.finish()
    }

    private static func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
