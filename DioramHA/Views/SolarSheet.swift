import Charts
import SwiftUI

/// What the panels are generating now and how the day is going.
struct SolarSheet: View {
    @Environment(HomeStore.self) private var store
    @State private var day: SolarDay?
    @State private var loadError: String?
    @State private var selectedHour: Int?

    /// Hours that can have sun all year round; the rest would leave the chart empty.
    private static let visibleHours = 6...21
    private static let barColor = Color(hex: 0xF29B38)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Solar")
                    .font(Type.light(38))
                    .foregroundStyle(Color.lamplight)
                now
                stats
                chartCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .task(id: store.isConnected) { await refreshWhileOpen() }
    }

    private func refreshWhileOpen() async {
        while !Task.isCancelled {
            if store.isConnected {
                do {
                    day = try await store.loadSolarDay()
                    loadError = nil
                } catch is CancellationError {
                    return
                } catch {
                    loadError = "Could not read production. \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    private var now: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.solarPower.map(SolarFormat.power) ?? "No data")
                .font(Type.light(64))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(isProducing ? "Generating now" : "Not generating now")
                .font(Type.regular(16))
                .opacity(0.75)
        }
        .foregroundStyle(Color.lamplight)
        .accessibilityElement(children: .combine)
    }

    private var isProducing: Bool { (store.solarPower ?? 0) > 0 }

    private var stats: some View {
        HStack(spacing: 8) {
            stat("Today", day.map { SolarFormat.energy($0.todayTotal) })
            stat("Yesterday", day.map { SolarFormat.energy($0.yesterdayTotal) })
            stat("Today's peak", store.solarPeak.map(SolarFormat.power))
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(Type.strong(18))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).font(Type.regular(13)).opacity(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .foregroundStyle(Color.lamplight)
        .background(Color.inkRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today's production by hour").font(Type.strong(17))
                Text(caption).font(Type.regular(14)).monospacedDigit().opacity(0.75)
            }
            if let loadError {
                Text(loadError).font(Type.regular(14))
            } else if let day {
                chart(day)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 170)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.lamplight)
        .background(Color.inkRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The tapped hour; if none, the day's best.
    private var caption: String {
        guard let day else { return "Tap a bar to see its hour" }
        if let selectedHour {
            return "\(selectedHour):00, \(SolarFormat.energy(day.energy(at: selectedHour)))"
        }
        guard let best = day.best else { return "Nothing produced yet" }
        return "Best hour: \(best.hour):00, \(SolarFormat.energy(best.energy))"
    }

    private func chart(_ day: SolarDay) -> some View {
        Chart {
            ForEach(Self.visibleHours, id: \.self) { hour in
                let energy = day.energy(at: hour)
                BarMark(x: .value("Hour", hour), y: .value("kWh", energy), width: .fixed(11))
                    .foregroundStyle(Self.barColor.opacity(selectedHour == nil || selectedHour == hour ? 1 : 0.4))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .accessibilityLabel("\(hour):00")
                    .accessibilityValue(SolarFormat.energy(energy))
            }
        }
        .chartXScale(domain: 5.5...21.5)
        .chartXAxis {
            AxisMarks(values: [6, 9, 12, 15, 18, 21]) { value in
                // Centered under its bar; by default it starts at the mark and looks like the next hour.
                AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                    if let hour = value.as(Int.self) {
                        Text("\(hour)h").font(Type.regular(12)).foregroundStyle(Color.lamplight.opacity(0.75))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.inkLine.opacity(0.7))
                AxisValueLabel {
                    if let kWh = value.as(Double.self) {
                        Text(String(format: "%.1f", kWh))
                            .font(Type.regular(12))
                            .foregroundStyle(Color.lamplight.opacity(0.75))
                    }
                }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedHour },
            set: { newValue in
                selectedHour = newValue.map { min(max($0, Self.visibleHours.lowerBound), Self.visibleHours.upperBound) }
            }
        ))
        .frame(height: 170)
    }
}
