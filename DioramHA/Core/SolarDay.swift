import Foundation

/// One day's production, split by local hour.
struct SolarDay: Equatable, Sendable {
    /// One Home Assistant statistics block: start in milliseconds and kWh produced.
    struct Row: Decodable, Sendable {
        let start: Double
        let change: Double?
    }

    struct Hour: Identifiable, Equatable, Sendable {
        let hour: Int
        let energy: Double
        var id: Int { hour }
    }

    let hours: [Hour]
    let todayTotal: Double
    let yesterdayTotal: Double

    init(today: [Row], yesterday: [Row], calendar: Calendar) {
        var byHour: [Int: Double] = [:]
        for row in today {
            let date = Date(timeIntervalSince1970: row.start / 1000)
            byHour[calendar.component(.hour, from: date), default: 0] += Self.produced(row)
        }
        hours = byHour.map { Hour(hour: $0.key, energy: $0.value) }.sorted { $0.hour < $1.hour }
        todayTotal = today.reduce(0) { $0 + Self.produced($1) }
        yesterdayTotal = yesterday.reduce(0) { $0 + Self.produced($1) }
    }

    func energy(at hour: Int) -> Double {
        hours.first { $0.hour == hour }?.energy ?? 0
    }

    var best: Hour? {
        hours.filter { $0.energy > 0 }.max { $0.energy < $1.energy }
    }

    /// A negative change is a counter reset, not production.
    private static func produced(_ row: Row) -> Double {
        max(row.change ?? 0, 0)
    }
}

enum SolarFormat {
    static func power(_ watts: Double) -> String {
        watts < 1000 ? "\(Int(watts.rounded())) W" : "\(decimal(watts / 1000)) kW"
    }

    static func energy(_ kWh: Double) -> String {
        "\(decimal(kWh)) kWh"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
