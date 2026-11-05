import SwiftUI

struct SkyLayer: View {
    let phase: DayPhase
    let elevation: Double
    let rainy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [phase.sky(rainy: rainy).top, phase.sky(rainy: rainy).bottom], startPoint: .top, endPoint: .init(x: 0.5, y: 0.8))
            if !rainy { celestial }
            if rainy {
                if reduceMotion {
                    Canvas { context, size in drawRain(context, size, time: 0) }
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        Canvas { context, size in
                            drawRain(context, size, time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var celestial: some View {
        Canvas { context, size in
            if phase == .night {
                for i in 0..<46 {
                    let x = (Double(i) * 137.508).truncatingRemainder(dividingBy: 100) / 100 * size.width
                    let y = (Double(i) * 61.803).truncatingRemainder(dividingBy: 100) / 100 * size.height * 0.5
                    let r = i % 5 == 0 ? 1.5 : 0.9
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.8)))
                }
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.08, y: size.height * 0.12, width: 30, height: 30)),
                             with: .color(Color(hex: 0xF4EFD8)))
            } else {
                let y = size.height * (0.22 - min(max(elevation, 0), 60) / 60 * 0.1)
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.08, y: y, width: 38, height: 38)),
                             with: .color(Color(hex: 0xFFE27A)))
            }
        }
    }

    private func drawRain(_ context: GraphicsContext, _ size: CGSize, time: Double) {
        for i in 0..<70 {
            let seed = Double(i)
            // Pseudo-random but stable: spacing by fixed multiples draws visible rows.
            let hash = (sin(seed * 12.9898) * 43758.5453)
            let x = (hash - hash.rounded(.down)) * size.width
            let hash2 = (sin(seed * 78.233) * 12543.123)
            let phase = hash2 - hash2.rounded(.down)
            let speed = 260 + phase * 120
            let y = (time * speed + phase * size.height).truncatingRemainder(dividingBy: size.height)
            var line = Path()
            line.move(to: CGPoint(x: x, y: y))
            line.addLine(to: CGPoint(x: x - 2, y: y + 12))
            context.stroke(line, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
    }
}
