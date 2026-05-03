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
    var maxBrakeForce: CGFloat  = 60

    // Steering
    var maxSteerRadians: CGFloat = 0.55       // ≈ 31°
    var steerLerp: CGFloat       = 12.0       // larger = snappier response

    // Tyre grip
    var frictionSlipFront: CGFloat = 1.6
    var frictionSlipRear: CGFloat  = 1.4

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
