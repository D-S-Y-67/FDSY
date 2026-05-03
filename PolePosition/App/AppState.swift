import Foundation
import Observation

/// Top-level observable state for the app. In Phase 1 we only need the
/// telemetry that the on-screen overlay reads (speed, throttle, steering).
/// Future phases will extend this with selected circuit, profile, mode, etc.
@Observable
final class AppState {
    /// Live vehicle telemetry, written by the game loop on the render thread
    /// and read by SwiftUI on the main thread. Mutations to @Observable
    /// properties are coalesced; SwiftUI will pick them up on its next
    /// redraw cycle, so a few stale frames are fine for HUD purposes.
    var telemetry = Telemetry()
}

/// Lightweight value-type telemetry snapshot. Kept tiny so it can be copied
/// cheaply each frame without allocating.
struct Telemetry: Equatable {
    var speedKPH: Double = 0
    var throttle: Double = 0
    var brake: Double = 0
    var steering: Double = 0     // -1...1, target steering input
}
