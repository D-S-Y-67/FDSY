import Foundation
import SceneKit
import simd

/// Per-frame driver. SCNView calls `renderer(_:updateAtTime:)` once per
/// rendered frame on a non-main thread; we use that as our game loop.
///
/// Phase 2 additions over Phase 1: the loop also updates the `Timing`
/// state machine each frame and pushes a combined `GameSnapshot`
/// (telemetry + lap timing) to `AppState` at 10 Hz.
final class GameLoopController: NSObject, SCNSceneRendererDelegate {
    private let input: InputManager
    private let vehicle: VehiclePhysics
    private let cameraRig: CameraRig
    private let timing: Timing
    private let triggers: [Checkpoint]
    private weak var appState: AppState?

    private var lastTime: TimeInterval = 0
    private var lastSnapshotPush: TimeInterval = 0

    /// HUD doesn't need 60 Hz; 10 Hz is plenty and keeps us from spamming
    /// MainActor-hop tasks every frame.
    private let snapshotPushInterval: TimeInterval = 0.1

    init(input: InputManager,
         vehicle: VehiclePhysics,
         cameraRig: CameraRig,
         timing: Timing,
         triggers: [Checkpoint],
         appState: AppState) {
        self.input = input
        self.vehicle = vehicle
        self.cameraRig = cameraRig
        self.timing = timing
        self.triggers = triggers
        self.appState = appState
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if lastTime == 0 {
            lastTime = time
            lastSnapshotPush = time
            return
        }
        // Clamp to avoid huge jumps when the app is paused/backgrounded.
        let dt = min(max(time - lastTime, 0.0), 1.0 / 20.0)
        lastTime = time

        // Restart request — handled before physics so the simulation
        // sees the new transform on this frame.
        if input.consumeRestart() {
            vehicle.respawn()
            cameraRig.snapToTarget()
            timing.reset(at: time)
        }

        let axes = input.axes
        vehicle.update(axes: axes, dt: dt)
        cameraRig.update(dt: dt)

        // --- Timing: per-frame check against trigger AABBs.
        let pos = vehicle.worldPosition
        let posSimd = simd_float3(Float(pos.x), Float(pos.y), Float(pos.z))
        timing.update(carPosition: posSimd, time: time, triggers: triggers)

        // --- Throttled snapshot push to SwiftUI on the main actor.
        if time - lastSnapshotPush >= snapshotPushInterval, let appState {
            lastSnapshotPush = time
            let snap = GameSnapshot(
                telemetry: Telemetry(
                    speedKPH: vehicle.speedKPH,
                    throttle: axes.throttle,
                    brake: axes.brake,
                    steering: axes.steer
                ),
                timing: timing.snapshot
            )
            Task { @MainActor in
                appState.snapshot = snap
            }
        }
    }
}
