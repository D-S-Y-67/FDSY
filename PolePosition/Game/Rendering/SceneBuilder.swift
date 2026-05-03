import Foundation
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Builds the initial Phase 1 scene: lighting, ground plane, car. Phase 2
/// will swap the bare plane for a proper track via `TrackBuilder`.
enum SceneBuilder {

    /// Result bundle so the caller can wire up the game loop.
    struct Scene {
        let scene: SCNScene
        let cameraRig: CameraRig
        let vehicle: VehiclePhysics
    }

    static func build(tuning: PhysicsTuning = .default) -> Scene {
        let scene = SCNScene()

        // Sky / background. Soft pale blue, intentionally low contrast so
        // the orange car pops.
        scene.background.contents = PlatformColor(red: 0.78, green: 0.85, blue: 0.92, alpha: 1)

        // Match physics gravity to real-world. SCNScene default is -9.8
        // already, but setting it explicitly is documentation.
        scene.physicsWorld.gravity = vec3(0, -9.8, 0)
        // Sub-step a bit more aggressively than the default for stable
        // wheels at higher speeds.
        scene.physicsWorld.timeStep = 1.0 / 120.0

        // --- Lighting -------------------------------------------------
        // Ambient — fills shadows so the dark side of the car isn't black.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = PlatformColor(white: 0.55, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Directional — the "sun". Casts soft shadows.
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.color = PlatformColor(white: 1.0, alpha: 1)
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowSampleCount = 8
        sun.light?.shadowRadius = 4
        sun.light?.shadowColor = PlatformColor(white: 0, alpha: 0.45)
        // Pointed roughly south-west and down; eulerAngles X = -1.0 rad
        // (≈ -57°) gives the long raking shadows we want.
        sun.eulerAngles = vec3(-1.0, -0.6, 0)
        sun.position = vec3(0, 50, 0)
        scene.rootNode.addChildNode(sun)

        // --- Ground plane --------------------------------------------
        // Use SCNFloor so it tiles to the horizon. For Phase 1 the floor
        // is a plain slate grey — Phase 2's track pieces will sit on top
        // of (or replace) this.
        let floorGeo = SCNFloor()
        floorGeo.reflectivity = 0.0
        floorGeo.firstMaterial = CarGeometry.flatMaterial(
            PlatformColor(red: 0.30, green: 0.32, blue: 0.34, alpha: 1)
        )
        let floor = SCNNode(geometry: floorGeo)
        // Static physics body so the wheels have something to push on.
        floor.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        floor.physicsBody?.friction = 1.0
        scene.rootNode.addChildNode(floor)

        // Reference grid markers — small posts every 25 m so you can tell
        // you're moving while driving in a featureless plane. Removed in
        // Phase 2 once a real track is in.
        for x in stride(from: -100.0, through: 100.0, by: 25.0) {
            for z in stride(from: -100.0, through: 100.0, by: 25.0) where !(x == 0 && z == 0) {
                let post = CarGeometry.box(
                    width: 0.4, height: 1.2, length: 0.4, chamfer: 0,
                    color: PlatformColor(white: 0.85, alpha: 1)
                )
                post.position = vec3(x, 0.6, z)
                scene.rootNode.addChildNode(post)
            }
        }

        // --- Car ------------------------------------------------------
        let (chassis, wheels) = F1Car.build(at: vec3(0, 0.6, 0), tuning: tuning)
        scene.rootNode.addChildNode(chassis)
        let vehicle = VehiclePhysics(chassisNode: chassis, wheelNodes: wheels, tuning: tuning)
        vehicle.attach(to: scene.physicsWorld)

        // --- Camera ---------------------------------------------------
        let cameraRig = CameraRig(target: chassis)
        scene.rootNode.addChildNode(cameraRig.node)

        return Scene(scene: scene, cameraRig: cameraRig, vehicle: vehicle)
    }
}
