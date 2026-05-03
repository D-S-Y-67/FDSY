import Foundation
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Builds the Phase 2 scene from a `Track`: lighting, large slate ground,
/// the track itself (via `TrackBuilder`), the car (via `F1Car`), and the
/// chase camera. Returns the live objects the game loop needs to drive
/// each frame.
enum SceneBuilder {

    struct Scene {
        let scene: SCNScene
        let cameraRig: CameraRig
        let vehicle: VehiclePhysics
        let triggers: [Checkpoint]    // for the timing system
    }

    static func build(track: Track,
                      tuning: PhysicsTuning = .default) -> Scene {
        let scene = SCNScene()

        // Sky background colour driven by the track's `skybox` enum.
        scene.background.contents = backgroundColor(for: track.skybox)
        scene.physicsWorld.gravity = vec3(0, -9.8, 0)
        scene.physicsWorld.timeStep = 1.0 / 120.0

        // --- Lighting -------------------------------------------------
        addLighting(to: scene, skybox: track.skybox)

        // --- Ground ---------------------------------------------------
        // The "outside the track" surface — a big flat slab the same
        // colour as the track's own ground colour. The track itself sits
        // a hair above this so its tarmac z-fights nothing.
        let floor = SCNBox(width: 1200, height: 0.2, length: 1200, chamferRadius: 0)
        floor.firstMaterial = CarGeometry.flatMaterial(track.groundColor.platformColor())
        let floorN = SCNNode(geometry: floor)
        floorN.position = vec3(0, -0.11, 0)
        floorN.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        floorN.physicsBody?.friction = 0.6
        scene.rootNode.addChildNode(floorN)

        // --- Track ----------------------------------------------------
        let built = TrackBuilder.build(track)
        scene.rootNode.addChildNode(built.root)

        // --- Car at the track's spawn transform ----------------------
        let spawnPos = SCNVector3(built.spawn.m41, built.spawn.m42, built.spawn.m43)
        let (chassis, wheels) = F1Car.build(at: spawnPos, tuning: tuning)
        // Apply the spawn rotation too. We have a full 4x4; use it as the
        // chassis transform.
        chassis.transform = built.spawn
        scene.rootNode.addChildNode(chassis)
        let vehicle = VehiclePhysics(chassisNode: chassis,
                                     wheelNodes: wheels,
                                     tuning: tuning)
        vehicle.attach(to: scene.physicsWorld)

        // --- Camera ---------------------------------------------------
        let cameraRig = CameraRig(target: chassis)
        scene.rootNode.addChildNode(cameraRig.node)

        // --- Triggers (snapshot world AABBs after the scene is laid
        // out) ---------------------------------------------------------
        let checkpoints: [Checkpoint] = built.triggers.map { info in
            Checkpoint(kind: info.kind,
                       aabb: CheckpointBuilder.aabb(for: info.node))
        }

        return Scene(scene: scene, cameraRig: cameraRig,
                     vehicle: vehicle, triggers: checkpoints)
    }

    // MARK: - Lighting / sky helpers

    private static func backgroundColor(for sky: Skybox) -> PlatformColor {
        switch sky {
        case .day:    return PlatformColor(red: 0.60, green: 0.74, blue: 0.85, alpha: 1)
        case .dusk:   return PlatformColor(red: 0.85, green: 0.46, blue: 0.32, alpha: 1)
        case .night:  return PlatformColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1)
        case .desert: return PlatformColor(red: 0.92, green: 0.78, blue: 0.55, alpha: 1)
        }
    }

    private static func addLighting(to scene: SCNScene, skybox: Skybox) {
        // Ambient — fills the dark side of the car so it isn't black.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = PlatformColor(white: 0.55, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Directional sun. Cool rim from the +X side, slightly behind.
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.color = PlatformColor(white: 1.0, alpha: 1)
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowSampleCount = 8
        sun.light?.shadowRadius = 4
        sun.light?.shadowColor = PlatformColor(white: 0, alpha: 0.45)
        sun.eulerAngles = vec3(-1.0, -0.6, 0)
        sun.position = vec3(0, 200, 0)
        scene.rootNode.addChildNode(sun)
    }
}
