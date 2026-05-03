import Foundation

/// All physics dials in one place. The user is expected to tweak these to
/// taste while running the game in Xcode — recompile, drive, repeat.
///
/// Units:
///  - mass: kilograms (scene-space metres are 1 SceneKit unit per metre).
///  - forces: Newtons. Engine force is per *driven* wheel.
///  - torques: Newton·metres.
///  - angles: radians.
///  - lengths: metres, except where noted (`maxSuspensionTravel` is in
///    SceneKit's unitless centimetres — see `SCNPhysicsVehicleWheel`).
///
/// Notes from rolling this:
///  - If the car flips on light steering, drop `maxSteerRadians` and bump
///    `frictionSlipRear`.
///  - If it understeers like a bus, raise `frictionSlipFront` or drop
///    `frictionSlipRear`.
///  - If it pogos on bumps, raise `suspensionDamping`.
///  - If the rear is too loose at full throttle, drop `maxEngineForce` or
///    raise `frictionSlipRear`.
struct PhysicsTuning {
    // Chassis
    var mass: CGFloat = 800

    // Powertrain
    var maxEngineForce: CGFloat = 4000
    var maxBrakeForce: CGFloat  = 500
    /// When the brake key is held below this speed (km/h, absolute) the
    /// car drives in reverse instead of braking.
    var reverseSpeedThresholdKPH: Double = 5
    /// Reverse acceleration as a fraction of forward `maxEngineForce`.
    var reverseForceFraction: CGFloat = 0.5

    // Steering
    // Tuning history:
    //   Phase 1 default (0.55, 12.0) was twitchy on keyboard.
    //   Phase 2.2 (0.40, 6.0) was still too eager.
    //   Phase 2.3 (0.28, 3.5) plus a speed-dependent taper below.
    // Bump back up if you want kart-style handling.
    var maxSteerRadians: CGFloat = 0.28       // ≈ 16°
    var steerLerp: CGFloat       = 3.5        // larger = snappier response

    /// Steering reduction at high speed. The effective max-steer angle
    /// is multiplied by `lerp(1.0, highSpeedSteerFloor, speed/highSpeedSteerKnee)`,
    /// clamped 0–1. So at 0 km/h the player gets full lock; at the knee
    /// speed and above they get the floor fraction.
    var highSpeedSteerKnee: Double  = 150     // km/h
    var highSpeedSteerFloor: Double = 0.45    // fraction of max steer at high speed

    // Tyre grip
    var frictionSlipFront: CGFloat = 1.6
    var frictionSlipRear: CGFloat  = 1.55

    // Suspension
    var suspensionStiffness: CGFloat   = 5.5
    var suspensionDamping: CGFloat     = 2.3
    var suspensionCompression: CGFloat = 4.0
    var maxSuspensionTravel: CGFloat   = 50.0  // SceneKit centimetres
    var suspensionRestLength: CGFloat  = 0.25  // metres
    var maxSuspensionForce: CGFloat    = 6000

    // Wheels
    var wheelRadius: CGFloat    = 0.33
    var wheelHalfWidth: CGFloat = 0.18

    /// Singleton-ish default. Construct another one if you want to A/B
    /// different setups during a session.
    static let `default` = PhysicsTuning()
}
