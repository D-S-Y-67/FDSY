import Foundation
import SceneKit
import simd

/// Smoothed chase camera. Owns a single `SCNCamera` node which gets added
/// to the scene root (NOT parented to the car — we want independent
/// smoothing in world space).
///
/// The camera target sits *behind and above* the car in car-local space.
/// Each frame we exponentially smooth the camera's world position toward
/// that target, then aim it at a point slightly above the car's roof.
final class CameraRig {
    let node: SCNNode
    let target: SCNNode

    /// Behind / above offset in chassis-local space. Tweak to taste.
    var followOffset = simd_float3(0, 1.6, 5.5)

    /// Lookat point in chassis-local space — slightly above the chassis
    /// origin so the horizon sits comfortably above the car.
    var lookAtOffset = simd_float3(0, 0.6, 0)

    /// Exponential damping rate (1/seconds). Bigger = stiffer / less lag.
    /// 5.0 feels right for an arcade racer; drop to 3 for cinematic.
    var damping: Float = 5.0

    init(target: SCNNode, fov: Double = 60) {
        self.target = target
        let cam = SCNCamera()
        cam.fieldOfView = fov
        cam.zNear = 0.1
        cam.zFar = 1500
        // Slightly wider FOV "feels fast"; auto-adjusts based on speed in
        // a later phase.
        let n = SCNNode()
        n.camera = cam
        // Initial position so the very first frame isn't a wild snap.
        n.simdWorldPosition = target.simdWorldPosition + simd_float3(0, 1.6, 5.5)
        self.node = n
    }

    /// Per-frame update. Call from the game loop.
    func update(dt: TimeInterval) {
        // The car node has been moved by the physics simulation. Use the
        // *presentation* node so we read the post-physics position, not
        // the model position which lags.
        let pres = target.presentation
        let carWorldPos = pres.simdWorldPosition
        let carOrient = pres.simdOrientation

        // World-space target = car position + (car-orientation rotated offset)
        let targetWorld = carWorldPos + carOrient.act(followOffset)

        // Exponential smoothing: 1 - exp(-rate * dt). Frame-rate independent.
        let alpha = 1 - exp(-damping * Float(dt))
        node.simdWorldPosition = mix(node.simdWorldPosition, targetWorld, t: alpha)

        // Look at a point slightly above the car. SCNNode.look(at:) handles
        // the orientation maths; we pass world-up so the camera stays level
        // even when the car is rolling.
        let lookWorld = carWorldPos + carOrient.act(lookAtOffset)
        node.simdLook(at: lookWorld, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
    }

    /// Snap to target with no smoothing — used on respawn so the camera
    /// doesn't drift across the world.
    func snapToTarget() {
        let pres = target.presentation
        let carWorldPos = pres.simdWorldPosition
        let carOrient = pres.simdOrientation
        node.simdWorldPosition = carWorldPos + carOrient.act(followOffset)
        let lookWorld = carWorldPos + carOrient.act(lookAtOffset)
        node.simdLook(at: lookWorld, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
    }
}

private func mix(_ a: simd_float3, _ b: simd_float3, t: Float) -> simd_float3 {
    a + (b - a) * t
}
