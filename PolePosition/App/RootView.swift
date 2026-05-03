import SwiftUI

/// Root view for Phase 1: a SceneKit container plus a tiny telemetry
/// overlay so we can verify the physics is doing something sensible
/// while tuning. Real HUD work happens in Phase 2.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .topLeading) {
            SceneContainerView()
                .ignoresSafeArea()

            TelemetryOverlay(telemetry: appState.telemetry)
                .padding(16)
                .allowsHitTesting(false)
        }
        #if os(macOS)
        .background(Color.black)
        #endif
    }
}

private struct TelemetryOverlay: View {
    let telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Int(telemetry.speedKPH)) KPH")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(radius: 2)

            Text("Throttle \(format(telemetry.throttle))   Brake \(format(telemetry.brake))   Steer \(format(telemetry.steering))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))

            Text("WASD / arrows · Space brake · R restart")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func format(_ v: Double) -> String {
        String(format: "%+.2f", v)
    }
}
