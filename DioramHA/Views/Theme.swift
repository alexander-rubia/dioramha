import SwiftUI

enum Type {
    static func light(_ size: CGFloat) -> Font { .custom("AvenirNext-Regular", size: size) }
    static func regular(_ size: CGFloat) -> Font { .custom("AvenirNext-Medium", size: size) }
    static func strong(_ size: CGFloat) -> Font { .custom("AvenirNext-DemiBold", size: size) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let lamp = Color(hex: 0xFFC65C)
    static let lampDeep = Color(hex: 0xF29B38)
    static let ink = Color(hex: 0x1B2A55)
    static let inkRaised = Color(hex: 0x2B3C70)
    static let inkLine = Color(hex: 0x41548F)
    static let lamplight = Color(hex: 0xF7F3E8)
    static let waterLit = Color(hex: 0x35DCD0)
}

/// The sky and the model's light, from the real elevation of the sun.
enum DayPhase: Equatable {
    case night, dusk, day

    init(elevation: Double) {
        self = elevation < -6 ? .night : elevation < 8 ? .dusk : .day
    }

    func sky(rainy: Bool) -> (top: Color, bottom: Color) {
        switch self {
        case .night: (Color(hex: 0x0F1B44), Color(hex: 0x2C3E7E))
        case .dusk: (Color(hex: 0x3D4F93), Color(hex: 0xF5A58A))
        case .day: rainy ? (Color(hex: 0x7C8FA6), Color(hex: 0xBAC6CF)) : (Color(hex: 0x4FA3DC), Color(hex: 0xBFE3F2))
        }
    }
}
