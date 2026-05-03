import Foundation
import SceneKit

/// Per-frame driver. SCNView calls `renderer(_:updateAtTime:)` once per
/// rendered frame on a non-main thread; we use that as our game loop.
///
/// Responsibilities:
///   1. Compute frame `dt` from monotonic times.
///   2. Read input, apply to the vehicle, update the camera.
///   3. Push a fresh `Telemetry` snapshot to `AppState` on the main actor.
final class GameLoopController: NSObject, SCNSceneRendererDelegate {
    private let input: InputManager
    private let vehicle: VehiclePhysics
    private let cameraRig: CameraRig
    private weak var appState: AppState?

    private var lastTime: TimeInterval = 0
    private var lastTelemetryPush: TimeInterval = 0

    /// HUD doesn't need 60 Hz; 10 Hz is plenty and keeps us from spamming
    /// MainActor-hop tasks every frame.
    private let telemetryPushInterval: TimeInterval = 0.1

    init(input: InputManager,
         vehicle: VehiclePhysics,
         cameraRig: CameraRig,
         appState: AppState) {
        self.input = input
        self.vehicle = vehicle
        self.cameraRig = cameraRig
        self.appState = appState
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // First frame: just record the timestamp and bail.
        if lastTime == 0 {
            lastTime = time
            lastTelemetryPush = time
            return
        }
        let dt = min(max(time - lastTime, 0.0), 1.0 / 20.0) // clamp to avoid
        // huge jumps when the app is paused. 50 ms = 20 fps floor.
        lastTime = time

        // Restart request — handled before the physics step so the car's
        // new transform is what the simulation sees this frame.
        if input.consumeRestart() {
            vehicle.respawn()
            cameraRig.snapToTarget()
        }

        let axes = input.axes
        vehicle.update(axes: axes, dt: dt)
        cameraRig.update(dt: dt)

        // Throttled telemetry push. Reading speedKPH and assembling the
        // struct is cheap, but spawning 60 MainActor tasks per second adds
        // up — 10 Hz is plenty for the HUD.
        if time - lastTelemetryPush >= telemetryPushInterval, let appState {
            lastTelemetryPush = time
            let telem = Telemetry(
                speedKPH: vehicle.speedKPH,
                throttle: axes.throttle,
                brake: axes.brake,
                steering: axes.steer
            )
            Task { @MainActor in
                appState.telemetry = telem
            }
        }
    }
}
