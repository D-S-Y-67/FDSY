import Foundation
import SceneKit
import simd

/// Wraps `SCNPhysicsVehicle` and a chassis `SCNPhysicsBody`, exposing a tiny
/// surface to the game loop: build, update each frame, reset.
///
/// Wheel ordering convention used everywhere in this file:
///   - 0: front-left
///   - 1: front-right
///   - 2: rear-left
///   - 3: rear-right
///
/// SCNPhysicsVehicle gotchas, distilled from a few hours of trial and error:
///
///   1. `connectionPosition` is in *chassis-local* space and is the point
///      where the suspension *anchors to the chassis*, not where the wheel
///      sits. The wheel hangs below it by `suspensionRestLength` plus
///      compression/extension.
///   2. `axle` is the wheel's spin axis in chassis-local space. For a car
///      driving along -Z (SceneKit's "forward"), the axle is ±X. We use
///      (-1, 0, 0) for left wheels and (1, 0, 0) for right wheels — the
///      sign matters for which way the wheel visually spins, but not for
///      physics.
///   3. `steeringAxis` defaults to chassis-up which is what we want.
///   4. `applyEngineForce` and `applyBrakingForce` are *additive each
///      simulation step* — you have to call them every frame or the car
///      coasts. Setting force to 0 explicitly when the player isn't on
///      throttle is fine.
///   5. `setSteeringAngle` is absolute, not incremental.
///   6. `vehicle.speedInKilometersPerHour` is signed (negative when
///      reversing). HUD wants the absolute value.
final class VehiclePhysics {
    let vehicle: SCNPhysicsVehicle
    let chassisNode: SCNNode
    private let wheels: [SCNPhysicsVehicleWheel]
    private var tuning: PhysicsTuning

    /// Smoothed steering angle (radians). Lerped toward `target = axes.steer
    /// * tuning.maxSteerRadians` each frame so binary keyboard input feels
    /// analog.
    private var currentSteer: CGFloat = 0

    /// Spawn transform — used to respawn the car on R/Return.
    private let spawnTransform: SCNMatrix4

    /// Live readouts for the HUD / camera.
    var speedKPH: Double { abs(Double(vehicle.speedInKilometersPerHour)) }
    var worldPosition: SCNVector3 { chassisNode.presentation.worldPosition }
    var worldOrientation: SCNQuaternion { chassisNode.presentation.orientation }

    /// Constructs the vehicle physics.
    /// - Parameters:
    ///   - chassisNode: the SCNNode containing the visible car geometry. It
    ///     gets a dynamic SCNPhysicsBody attached. The node should already
    ///     be positioned in the world.
    ///   - wheelNodes: 4 wheel nodes (positioned in chassis-local space) —
    ///     SceneKit drives their world transform from the physics
    ///     simulation. Order is FL, FR, RL, RR.
    ///   - tuning: physics constants.
    init(chassisNode: SCNNode, wheelNodes: [SCNNode], tuning: PhysicsTuning = .default) {
        precondition(wheelNodes.count == 4, "Need exactly 4 wheels (FL, FR, RL, RR)")
        self.chassisNode = chassisNode
        self.tuning = tuning
        self.spawnTransform = chassisNode.transform

        // 1) Chassis physics body. We use the chassis node's geometry as
        //    the collision shape via .convexHull — fast, slightly larger
        //    than the box but totally fine for an arcade racer. We could
        //    use a hand-tuned compound shape later if needed, but the
        //    hull is fine for Phase 1.
        let shape = SCNPhysicsShape(node: chassisNode, options: [
            SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.convexHull,
            SCNPhysicsShape.Option.keepAsCompound: false
        ])
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = tuning.mass
        // Lower the centre of mass so the car doesn't roll like a truck.
        // SCNPhysicsBody doesn't expose a direct CoM setter, but biasing
        // angularDamping helps in the same direction.
        body.angularDamping = 0.35
        body.damping = 0.05
        body.friction = 0.5
        body.rollingFriction = 0.05
        // Allow it to sleep if we ever go idle for a while.
        body.allowsResting = true
        chassisNode.physicsBody = body

        // 2) Wheels. Each gets its own connection point + suspension/grip
        //    config. The connection point is read from the wheel node's
        //    *local* position relative to the chassis — set by F1Car when
        //    it placed them.
        var built: [SCNPhysicsVehicleWheel] = []
        built.reserveCapacity(4)
        for (i, wheelNode) in wheelNodes.enumerated() {
            let isLeft  = (i == 0 || i == 2)
            let isFront = (i == 0 || i == 1)

            let w = SCNPhysicsVehicleWheel(node: wheelNode)
            w.connectionPosition = wheelNode.position
            // Local-space spin axis. Negative X for left, positive X for
            // right — keeps cosmetic spin direction consistent if we ever
            // animate the wheel mesh by hand.
            w.axle = vec3(isLeft ? -1 : 1, 0, 0)
            w.steeringAxis = vec3(0, -1, 0) // chassis-down, as default
            w.radius = tuning.wheelRadius
            w.frictionSlip = isFront ? tuning.frictionSlipFront : tuning.frictionSlipRear
            w.suspensionStiffness = tuning.suspensionStiffness
            w.suspensionDamping = tuning.suspensionDamping
            w.suspensionCompression = tuning.suspensionCompression
            w.maximumSuspensionTravel = tuning.maxSuspensionTravel
            w.suspensionRestLength = tuning.suspensionRestLength
            w.maximumSuspensionForce = tuning.maxSuspensionForce
            built.append(w)
        }
        self.wheels = built

        self.vehicle = SCNPhysicsVehicle(chassisBody: body, wheels: built)
    }

    /// Add this vehicle's behaviour to the scene's physics world. Call once
    /// after the scene is built.
    func attach(to physicsWorld: SCNPhysicsWorld) {
        physicsWorld.addBehavior(vehicle)
    }

    /// Per-frame update. Call from the renderer delegate.
    func update(axes: InputManager.Axes, dt: TimeInterval) {
        // --- Steering -------------------------------------------------
        // Target steering angle in radians.
        let target = CGFloat(axes.steer) * tuning.maxSteerRadians
        // Frame-rate independent exponential lerp:
        //   value += (target - value) * (1 - exp(-rate * dt))
        // At 60 fps with rate = 12 this resolves ~80 % toward target each
        // 100 ms, which feels analog without being floaty.
        let alpha = 1 - exp(-tuning.steerLerp * CGFloat(dt))
        currentSteer += (target - currentSteer) * alpha

        // SCNPhysicsVehicle steering is on the front wheels (0 = FL, 1 = FR).
        vehicle.setSteeringAngle(currentSteer, forWheelAt: 0)
        vehicle.setSteeringAngle(currentSteer, forWheelAt: 1)

        // --- Engine ---------------------------------------------------
        // RWD: drive only the rear wheels (2 = RL, 3 = RR). This gives the
        // characteristic F1-feeling "rear gets loose under power" without
        // us simulating tyres yet.
        //
        // We don't apply engine force while the brake is held — saves the
        // user from accidentally "throttle-locking" against the brakes.
        let engineForce = axes.brake > 0 ? 0 : CGFloat(axes.throttle) * tuning.maxEngineForce
        vehicle.applyEngineForce(engineForce, forWheelAt: 2)
        vehicle.applyEngineForce(engineForce, forWheelAt: 3)

        // --- Brakes ---------------------------------------------------
        // Brake on all four. An F1 car has way more front than rear bias,
        // but evenly applied is fine for arcade.
        let brakeTorque = CGFloat(axes.brake) * tuning.maxBrakeForce
        for i in 0..<4 {
            vehicle.applyBrakingForce(brakeTorque, forWheelAt: i)
        }
    }

    /// Teleport back to the spawn point with zero velocity. Triggered on
    /// R/Return.
    func respawn() {
        guard let body = chassisNode.physicsBody else { return }
        // Stop steering pinned over.
        currentSteer = 0
        // Reset transform on the model node, then tell the physics body to
        // resync from it — otherwise the simulation snaps the node back to
        // wherever it thought the body was last frame.
        chassisNode.transform = spawnTransform
        body.resetTransform()
        // Zero velocities so the car doesn't keep its momentum across the
        // teleport. Calling clearAllForces ensures the next physics step
        // starts cleanly.
        body.velocity = vec3(0, 0, 0)
        body.angularVelocity = SCNVector4Zero
        body.clearAllForces()
        // Cancel any leftover engine/brake commands too.
        for i in 0..<4 {
            vehicle.applyEngineForce(0, forWheelAt: i)
            vehicle.applyBrakingForce(0, forWheelAt: i)
            vehicle.setSteeringAngle(0, forWheelAt: i)
        }
    }
}
