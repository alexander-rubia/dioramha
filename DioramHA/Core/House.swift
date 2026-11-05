import CoreGraphics
import Foundation

/// The home comes from a JSON file. That is what keeps the app simple: only what is listed there
/// appears. To add or remove something from the app, edit that file.
enum House {
    static let document = HouseDocument.bundled

    static let rooms = document.rooms
    static let alarmID = document.sensors.alarm
    static let weatherID = document.sensors.weather
    static let sunID = document.sensors.sun
    /// Solar power sources; their readings are added together.
    static let solarIDs = document.sensors.solar
    static let solarPeakID = document.sensors.solarPeak
    /// Cumulative energy counter that hourly production is derived from.
    static let solarEnergyID = document.sensors.solarEnergy
    static let batteryID = document.sensors.battery

    static let trackedIDs: Set<String> = Set(rooms.flatMap(\.devices).map(\.entityID))
        .union([alarmID, weatherID, sunID, batteryID, solarPeakID])
        .union(solarIDs)
}
