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

        // 1) Chassis physics body. Hand-built box shape — fast, predictable,
        //    and importantly excludes the wheel children (they get their own
        //    physics through SCNPhysicsVehicleWheel).
        //    Earlier revisions used SCNPhysicsShape(node:options:.convexHull)
        //    which can stall for seconds on a tree with many children.
        let chassisBox = SCNBox(width: 1.6, height: 0.7, length: 4.6, chamferRadius: 0.05)
        let shape = SCNPhysicsShape(geometry: chassisBox, options: nil)
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = tuning.mass
        // Lower the centre of mass so the car doesn't roll like a truck.
        // SCNPhysicsBody doesn't expose a direct CoM setter, but biasing
        // angularDamping helps in the same direction. Keep this modest —
        // values above ~0.2 absorb so much rotational energy that engine
        // torque can fail to produce visible acceleration.
        body.angularDamping = 0.1
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
            // Local-space spin axis. ALL four wheels use +X so engine force
            // pushes them in the same direction. (Earlier we used -X for
            // left wheels, which inverted their drive torque and meant left
            // and right rears were fighting each other.) `isLeft` is kept
            // around for any future per-side tuning.
            _ = isLeft
            w.axle = vec3(1, 0, 0)
            // Chassis-down. SCNPhysicsVehicleWheel uses this axis for
            // BOTH the steering rotation AND the suspension travel
            // direction — so it has to point toward the ground or the
            // wheel never reaches the floor. Keep it as -Y; we fix the
            // steering-direction sign in `update(axes:dt:)` instead.
            w.steeringAxis = vec3(0, -1, 0)
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
    func attach(to world: SCNPhysicsWorld) {
        world.addBehavior(vehicle)
    }

    /// Per-frame update. Call from the renderer delegate.
    func update(axes: InputManager.Axes, dt: TimeInterval) {
        // --- Steering -------------------------------------------------
        // Target steering angle in radians. Negated because steeringAxis
        // is -Y (chassis-down), which inverts the rotation direction
        // relative to the user's intent (positive steer = turn right).
        let target = -CGFloat(axes.steer) * tuning.maxSteerRadians
        // Frame-rate independent exponential lerp:
        //   value += (target - value) * (1 - exp(-rate * dt))
        // At 60 fps with rate = 12 this resolves ~80 % toward target each
        // 100 ms, which feels analog without being floaty.
        let alpha = 1 - exp(-tuning.steerLerp * CGFloat(dt))
        currentSteer += (target - currentSteer) * alpha

        // SCNPhysicsVehicle steering is on the front wheels (0 = FL, 1 = FR).
        vehicle.setSteeringAngle(currentSteer, forWheelAt: 0)
        vehicle.setSteeringAngle(currentSteer, forWheelAt: 1)

        // --- Engine + brake -------------------------------------------
        // RWD: drive only the rear wheels (2 = RL, 3 = RR). The brake key
        // (S) does double duty: above the reverse threshold it applies
        // brake torque, below it it applies a backward engine force so
        // the car backs up. This is the standard arcade-racer behaviour.
        let speedKPH = vehicle.speedInKilometersPerHour
        let throttle = CGFloat(axes.throttle)
        let brakeIn  = CGFloat(axes.brake)

        var engineForce: CGFloat = throttle * tuning.maxEngineForce
        if throttle == 0 && brakeIn > 0 && abs(Double(speedKPH)) <= tuning.reverseSpeedThresholdKPH {
            // Reverse — half the forward force is plenty for arcade backing-up.
            engineForce = -brakeIn * tuning.maxEngineForce * tuning.reverseForceFraction
        }
        vehicle.applyEngineForce(engineForce, forWheelAt: 2)
        vehicle.applyEngineForce(engineForce, forWheelAt: 3)

        // Brake torque on all four wheels — only when actually braking
        // (not while we're using the brake key as reverse), and only when
        // moving fast enough that "brake" is meaningful.
        let isReversing = throttle == 0 && brakeIn > 0 &&
            abs(Double(speedKPH)) <= tuning.reverseSpeedThresholdKPH
        let brakeTorque: CGFloat = (brakeIn > 0 && !isReversing) ?
            brakeIn * tuning.maxBrakeForce : 0
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
