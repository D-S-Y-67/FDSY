import Foundation
import Observation

/// Top-level observable state for the app. The game loop pushes a fresh
/// `GameSnapshot` once every ~100 ms; SwiftUI observes the whole thing
/// as a single Equatable struct so we get one redraw per push regardless
/// of how many fields changed.
///
/// In Phase 2 this carries telemetry (speed/inputs) and lap timing.
/// Phase 3 adds ghost recording status; Phase 5 adds selected
/// driver/team; etc.
@Observable
final class AppState {
    var snapshot = GameSnapshot()

    /// The currently-loaded track. Changing this triggers
    /// `SceneContainerView` to rebuild the scene. Phase 2 ships with a
    /// hard-coded default; Phase 5+ adds a circuit selector.
    var trackChoice: TrackChoice = .monaco
}

struct GameSnapshot: Equatable {
    var telemetry = Telemetry()
    var timing = LapTiming()
}

struct Telemetry: Equatable {
    var speedKPH: Double = 0
    var throttle: Double = 0
    var brake: Double = 0
    var steering: Double = 0
}

/// Bundled official tracks. Custom tracks (Phase 4) get their own loader
/// path. Strings match the JSON resource basenames.
enum TrackChoice: String, CaseIterable, Equatable {
    case monaco       = "Monaco"
    case testOval     = "TestOval"

    var displayName: String {
        switch self {
        case .monaco:   return "Monaco"
        case .testOval: return "Test Oval"
        }
    }
}
