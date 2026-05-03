import Foundation
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A low-poly open-wheel car assembled from primitives. Returns a chassis
/// `SCNNode` containing all the cosmetic geometry, plus four separate wheel
/// nodes positioned in the world ready for `VehiclePhysics`.
///
/// Phase 1: a single hard-coded papaya-orange livery (because this is for
/// driving feel, not visual variety). Livery and team selection arrive in
/// Phase 5.
enum F1Car {

    /// Wheel positions in chassis-local space. Order: FL, FR, RL, RR — the
    /// same order `VehiclePhysics` and `SCNPhysicsVehicle` expect.
    static var wheelLocalPositions: [SCNVector3] {
        [
            vec3(-0.78, 0.0, -1.55),  // FL
            vec3( 0.78, 0.0, -1.55),  // FR
            vec3(-0.85, 0.0,  1.55),  // RL
            vec3( 0.85, 0.0,  1.55),  // RR
        ]
    }

    /// Builds the car. Pass the spawn position (world space).
    /// Returns:
    ///   - `chassisNode`: parent of all visible geometry; receives the
    ///     dynamic SCNPhysicsBody.
    ///   - `wheelNodes`: 4 wheel nodes, parented to chassisNode, positioned
    ///     in chassis-local space.
    static func build(at spawn: SCNVector3 = vec3(0, 0.6, 0),
                      tuning: PhysicsTuning = .default) -> (chassis: SCNNode, wheels: [SCNNode]) {

        // Livery — hardcoded papaya for Phase 1.
        let primary = PlatformColor(red: 1.00, green: 0.52, blue: 0.0, alpha: 1.0)
        let dark    = PlatformColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
        let accent  = PlatformColor(red: 0.18, green: 0.78, blue: 0.78, alpha: 1.0)

        let chassis = SCNNode()
        chassis.name = "F1Car"

        // Main chassis tub — the bit that sits between the wheels.
        let tub = CarGeometry.box(width: 0.95, height: 0.32, length: 2.6,
                                  chamfer: 0.04, color: primary)
        tub.position = vec3(0, 0.30, 0)
        chassis.addChildNode(tub)

        // Floor / underwing — a slightly wider, very thin slab. Helps the
        // car silhouette read as flat-bottomed.
        let floor = CarGeometry.box(width: 1.30, height: 0.06, length: 3.6,
                                    chamfer: 0.02, color: dark)
        floor.position = vec3(0, 0.10, 0)
        chassis.addChildNode(floor)

        // Nose cone — a long thin trapezoid-ish box pointing forward (-Z).
        let nose = CarGeometry.box(width: 0.38, height: 0.18, length: 1.4,
                                   chamfer: 0.04, color: primary)
        nose.position = vec3(0, 0.30, -1.85)
        chassis.addChildNode(nose)

        // Front wing — wide, low, two endplates.
        let frontWing = CarGeometry.box(width: 1.65, height: 0.08, length: 0.40,
                                        chamfer: 0.02, color: dark)
        frontWing.position = vec3(0, 0.18, -2.45)
        chassis.addChildNode(frontWing)
        for sign in [-1.0, 1.0] {
            let endplate = CarGeometry.box(width: 0.08, height: 0.30, length: 0.40,
                                           chamfer: 0.02, color: primary)
            endplate.position = vec3(sign * 0.82, 0.30, -2.45)
            chassis.addChildNode(endplate)
        }

        // Sidepods (left + right). Slightly tapered visually by being
        // shorter-front, but for Phase 1 a plain box reads fine.
        for sign in [-1.0, 1.0] {
            let sidepod = CarGeometry.box(width: 0.34, height: 0.45, length: 1.6,
                                          chamfer: 0.05, color: primary)
            sidepod.position = vec3(sign * 0.62, 0.36, 0.30)
            chassis.addChildNode(sidepod)
        }

        // Cockpit / monocoque opening — a small dark box in front of the
        // airbox so it reads as the cockpit cutout.
        let cockpit = CarGeometry.box(width: 0.45, height: 0.20, length: 0.85,
                                      chamfer: 0.04, color: dark)
        cockpit.position = vec3(0, 0.55, -0.55)
        chassis.addChildNode(cockpit)

        // Airbox / engine cover — sits behind the driver, slopes back to
        // the rear wing.
        let airbox = CarGeometry.box(width: 0.45, height: 0.42, length: 1.2,
                                     chamfer: 0.05, color: primary)
        airbox.position = vec3(0, 0.65, 0.55)
        chassis.addChildNode(airbox)

        // Halo — a stylised overhead bar above the cockpit. Single piece,
        // not the real F1 wishbone. Reads fine at low poly.
        let halo = CarGeometry.box(width: 0.38, height: 0.04, length: 0.5,
                                   chamfer: 0.02, color: dark)
        halo.position = vec3(0, 0.85, -0.45)
        chassis.addChildNode(halo)

        // Rear wing — main plane plus two endplates.
        let rearWing = CarGeometry.box(width: 1.05, height: 0.08, length: 0.42,
                                       chamfer: 0.02, color: dark)
        rearWing.position = vec3(0, 0.95, 1.95)
        chassis.addChildNode(rearWing)
        for sign in [-1.0, 1.0] {
            let endplate = CarGeometry.box(width: 0.08, height: 0.45, length: 0.42,
                                           chamfer: 0.02, color: primary)
            endplate.position = vec3(sign * 0.52, 0.80, 1.95)
            chassis.addChildNode(endplate)
        }

        // Tiny accent stripe down the airbox so the car has *some* visual
        // variety. Gives the camera something to track.
        let stripe = CarGeometry.box(width: 0.08, height: 0.01, length: 1.2,
                                     chamfer: 0.0, color: accent)
        stripe.position = vec3(0, 0.87, 0.55)
        chassis.addChildNode(stripe)

        // Wheels.
        var wheelNodes: [SCNNode] = []
        for pos in wheelLocalPositions {
            let w = CarGeometry.wheel(radius: tuning.wheelRadius,
                                      halfWidth: tuning.wheelHalfWidth)
            w.position = pos
            chassis.addChildNode(w)
            wheelNodes.append(w)
        }

        // Place the chassis at the spawn point.
        chassis.position = spawn

        return (chassis, wheelNodes)
    }
}
