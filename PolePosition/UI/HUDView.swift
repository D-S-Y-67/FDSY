import SwiftUI

/// In-race HUD overlay. Single source: `GameSnapshot`. Layout:
///
///     [throttle/brake/steer]                [lap clock]                [last/best lap]
///
///                                                                                   .
///
///     [S1] [S2] [S3]                        [SPEED]
///
/// All text uses monospaced digits so the clock doesn't jitter as digits
/// change width.
struct HUDView: View {
    let snapshot: GameSnapshot

    var body: some View {
        ZStack {
            VStack {
                topRow
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                Spacer()
                bottomRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(alignment: .top) {
            inputReadout
            Spacer()
            lapClock
            Spacer()
            lapHistory
        }
    }

    private var inputReadout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Throttle \(format(snapshot.telemetry.throttle))")
            Text("Brake    \(format(snapshot.telemetry.brake))")
            Text("Steer    \(format(snapshot.telemetry.steering))")
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
    }

    private var lapClock: some View {
        VStack(spacing: 2) {
            Text(snapshot.timing.currentLap.asLapString)
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(radius: 2)
            HStack(spacing: 12) {
                Text("S\(snapshot.timing.sector)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.18)))
                    .foregroundStyle(.white)
                if snapshot.timing.didSetPB {
                    Text("PERSONAL BEST")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.78, green: 0.4, blue: 1.0))
                }
            }
        }
    }

    private var lapHistory: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("LAST")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Text(snapshot.timing.lastLap?.asLapString ?? "—:——.———")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text("BEST")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Text(snapshot.timing.bestLap?.asLapString ?? "—:——.———")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.78, green: 0.4, blue: 1.0).opacity(0.95))
            }
        }
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack(alignment: .bottom) {
            sectorPills
            Spacer()
            speedReadout
        }
    }

    private var sectorPills: some View {
        HStack(spacing: 8) {
            sectorPill(index: 0, label: "S1")
            sectorPill(index: 1, label: "S2")
            sectorPill(index: 2, label: "S3")
        }
    }

    private func sectorPill(index: Int, label: String) -> some View {
        let split = snapshot.timing.sectorSplits[index]
        let delta = snapshot.timing.lastSectorDeltas[index]
        let color = pillColor(delta: delta, split: split)
        return VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text(split?.asLapString ?? "—:——.———")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(width: 110)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.85)))
    }

    /// Sector colour: purple = improvement (PB), green = within
    /// threshold, red = slower, dark = no data yet.
    private func pillColor(delta: TimeInterval?, split: TimeInterval?) -> Color {
        guard split != nil else { return Color.white.opacity(0.08) }
        guard let d = delta else { return Color.white.opacity(0.18) }
        if d <= -Timing.purpleThresholdMs / 1000 {
            return Color(red: 0.55, green: 0.20, blue: 0.85)
        } else if d < 0 {
            return Color(red: 0.0, green: 0.65, blue: 0.30)
        } else if d == 0 {
            return Color.white.opacity(0.22)
        } else {
            return Color(red: 0.78, green: 0.18, blue: 0.18)
        }
    }

    private var speedReadout: some View {
        VStack(alignment: .trailing, spacing: -4) {
            Text("\(Int(snapshot.telemetry.speedKPH))")
                .font(.system(size: 56, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(radius: 2)
            Text("KPH")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.trailing, 4)
        }
    }

    private func format(_ v: Double) -> String {
        String(format: "%+.2f", v)
    }
}
