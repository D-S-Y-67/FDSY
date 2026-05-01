// =============================================================================
// PolePosition — Arcade Vehicle Physics
// =============================================================================
//
// This module owns:
//   1. Rapier world setup (`initPhysics`, `createWorld`, `createGround`)
//   2. The chassis rigid body (`createVehicle`, `resetVehicle`)
//   3. The per-step arcade physics (`stepVehicle`)
//
// We deliberately do NOT use Rapier's DynamicRayCastVehicleController. PolyTrack
// is an arcade game, not a wheel-suspension simulator, and a raycast-vehicle
// fights you on exactly the things you want here: snap turn-in, lift-off
// rotation, no wheel chatter at rest.
//
// Instead the chassis is a single dynamic rigid body and we apply five forces
// each step:
//   - throttle / brake along the body's forward axis
//   - lateral-velocity-killing impulses at front and rear axle points (front
//     grip slightly higher than rear, so the car turns in naturally)
//   - aero/rolling drag opposing the velocity vector
//   - downforce along world −Y (sticks the car to the ground at speed)
//   - yaw torque proportional to steer × speed (with a low-speed floor so you
//     can park-rotate)
//
// Lift-off oversteer is a special case at step 5: when the player releases
// throttle and brake mid-corner above a threshold speed, we multiply the rear
// grip by `liftOffOversteerMul`. That's all it takes to feel right.
//
// All tunable numbers live in the `TUNING` export at the top of this file.
// They're also published on `window.TUNING` from `main.js`, so during a run
// you can paste e.g. `TUNING.engineForce = 13000` into DevTools and feel the
// change within a frame. When you find numbers you like, fold them back here.
//
// Coordinate convention (matches three.js scene + vehicle mesh):
//   +X = right, +Y = up, −Z = forward
//
// =============================================================================

import * as THREE from "three";
import RAPIER from "rapier";

// -----------------------------------------------------------------------------
// TUNING — every knob the physics tuner can turn for Phase 1.
//
// All values are starting points. Expect to retune by feel; the intuition
// behind each number is in the comments so you know what to nudge.
// -----------------------------------------------------------------------------
export const TUNING = {
  // --- chassis / mass ---
  // Real F1 minimum weight is ~798 kg with driver. We use 780 as a round
  // number that matches the era. Lighter mass → snappier rotation but also
  // more wheelspin; heavier → more planted but slower direction change.
  chassisMass: 780,
  // Half-extents of the cuboid collider in metres: width, height, length.
  // Height is set so the bottom of the collider sits at the bottom of the
  // wheels in vehicle.js (wheel y = -0.05, radius = 0.36, so wheel bottom
  // is at car-local -0.41). Keep these in sync with the visual mesh.
  chassisHalfExtents: [0.9, 0.41, 2.2],
  // Small linear damping helps numerical stability without affecting top
  // speed much (most of the cap comes from `dragCoefficient` below).
  linearDamping: 0.05,
  // Higher angular damping kills the slow yaw drift that arcade chassis
  // rigid bodies pick up at rest. Drop this if the car feels too stable
  // mid-corner; raise it if it twitches when stationary.
  angularDamping: 2.5,
  // Spawn slightly above ground; the car settles on its collider.
  spawnHeight: 0.5,

  // --- engine / brakes ---
  // Newtons. With dragCoefficient below this gives a top speed near 310 km/h
  // and a 0–100 km/h time around 2.0 s. Raise for harder acceleration; lower
  // if the car feels twitchy on power. Real F1 traction limits are ignored
  // here on purpose (this is arcade).
  engineForce: 11000,
  // Reverse force is intentionally weak — we don't want the car launching
  // backward when the player taps S to slow down.
  reverseForce: 5000,
  // Brake force is roughly 2× engine for a satisfying stop.
  brakeForce: 22000,
  // Quadratic drag: dragForce = dragCoefficient × speed² (Newtons), opposite
  // velocity. This is the dominant top-speed cap. Lower → higher top speed.
  // 1.49 with engineForce 11000 puts terminal speed at ~309 km/h.
  dragCoefficient: 1.49,

  // --- steering ---
  // Maximum steer angle (radians) at standstill vs at top speed. We lerp by
  // a normalised speed fraction. Bigger lowSpeed = sharper city feel; bigger
  // highSpeed = darty at top speed (tends to feel arcadey but unstable).
  maxSteerLow:  22 * Math.PI / 180,
  maxSteerHigh:  8 * Math.PI / 180,
  // How fast the smoothed steer input chases the player's intent (rad/s).
  // This is INPUT smoothing only — it stops binary keyboard input from
  // producing instantaneous full-lock yaw torque. Lower = soggier, higher
  // = twitchier.
  steerInputRate: 3.0,
  // N·m per rad of steer × speed-normalised yaw factor. The single biggest
  // knob for "how much does the car rotate when I press A/D".
  yawTorqueGain: 7000,
  // Minimum yaw factor at standstill. Real cars need motion to rotate the
  // body, but for arcade forgiveness we let the player nudge the heading
  // a little even when stopped.
  yawSpeedFloor: 0.18,

  // --- grip (the most important feel knobs) ---
  // Lateral grip in m/s² of deceleration applied per m/s of lateral velocity
  // at each axle. Modeled as: lateralImpulse = mass/2 × grip × lateralVel × dt.
  // FRONT > REAR by design — that's how the car turns in. If you bump
  // frontLatGrip well above rearLatGrip you'll get a darty, oversteery feel;
  // if you flip them the car understeers like a road car.
  // (Equal here while we settle the steering feel; nudge front up by 1–2
  // once the chassis isn't oversteering from yaw torque alone.)
  frontLatGrip: 14,
  rearLatGrip:  14,
  // Axle offsets along chassis-local Z. Negative Z = forward, so the front
  // axle is at -1.5 and the rear axle is at +1.5. Wheelbase = 3.0 m, which
  // matches the visual mesh in vehicle.js. Keep in sync.
  frontAxleOffsetZ: -1.5,
  rearAxleOffsetZ:   1.5,
  // Lift-off oversteer: when the player isn't pressing throttle or brake
  // and is steering above a threshold speed, the rear grip is reduced by
  // this multiplier for that frame. 1.0 = no oversteer, 0.5 = very loose,
  // 0.7 is a good "telegraphed but not punishing" starting point.
  liftOffOversteerMul: 0.7,
  // m/s. Below this we don't trigger lift-off oversteer — protects low-
  // speed cornering from gratuitous looseness.
  liftOffSpeedThresh: 25,

  // --- aero ---
  // Downforce magnitude = downforceCoef × speed² (N), applied along world -Y.
  // Doesn't change low-speed feel; bumps high-speed grip indirectly by
  // letting the lateral-grip impulses push against more weight. Raise if
  // the car feels floaty in fast corners.
  downforceCoef: 0.5,

  // --- camera (read by game.js, lives here so all tunables are in one place) ---
  // Body-local offset from the car: behind (+Z), above (+Y), centred (X=0).
  camPosOffset: [0, 3.2, 8],
  // World-space distance ahead of the car along its velocity to look at.
  // Using velocity (not heading) means the camera "looks where you're going",
  // which gives the slight lead the brief asks for.
  camLookAheadDist: 6,
  // Spring response constants for camera position and look-at point.
  // Higher = snappier; lower = laggier. Position needs to be slightly less
  // responsive than look-at so the camera doesn't feel rigidly bolted on.
  camPosResponse: 6,
  camLookResponse: 9,
};

// Derived constants
const APPROX_TOP_SPEED_MS = Math.sqrt(TUNING.engineForce / TUNING.dragCoefficient);

// -----------------------------------------------------------------------------
// World / ground setup
// -----------------------------------------------------------------------------

/** Awaits Rapier's WASM init. Must be called once before anything else. */
export async function initPhysics() {
  await RAPIER.init();
  return RAPIER;
}

/** Creates the world, gravity, and ground plane. Returns the world handle. */
export function createWorld() {
  const gravity = { x: 0, y: -9.81, z: 0 };
  const world = new RAPIER.World(gravity);

  // Ground: a fixed cuboid 1 m thick centred at y=-0.5 so its top sits at y=0.
  // We use a thick cuboid rather than a half-space because cuboids interact
  // more predictably with the chassis collider's contact normals.
  const groundDesc = RAPIER.RigidBodyDesc.fixed().setTranslation(0, -0.5, 0);
  const ground = world.createRigidBody(groundDesc);
  const groundColliderDesc = RAPIER.ColliderDesc.cuboid(2000, 0.5, 2000)
    .setFriction(0.9)
    .setRestitution(0);
  world.createCollider(groundColliderDesc, ground);

  return world;
}

// -----------------------------------------------------------------------------
// Vehicle creation / reset
// -----------------------------------------------------------------------------

/**
 * Build a chassis rigid body. The returned object also carries scratch
 * state that `stepVehicle` reads/writes each frame.
 *
 * @param {{x:number,y:number,z:number}} [position]
 */
export function createVehicle(world, position = { x: 0, y: TUNING.spawnHeight, z: 0 }) {
  const bodyDesc = RAPIER.RigidBodyDesc.dynamic()
    .setTranslation(position.x, position.y, position.z)
    .setLinearDamping(TUNING.linearDamping)
    .setAngularDamping(TUNING.angularDamping)
    // CCD prevents the chassis tunneling through ground at high speed.
    .setCcdEnabled(true);
  const body = world.createRigidBody(bodyDesc);

  // Lock the chassis to yaw (Y) only. Without this, tiny numerical roll/pitch
  // drift makes the chase camera (which inherits the chassis quaternion) tilt
  // and produces a "W turns the car" illusion. PolyTrack-style arcade always
  // constrains the body to yaw — we'll revisit if a future track needs banking.
  body.setEnabledRotations(false, true, false, true);

  const [hx, hy, hz] = TUNING.chassisHalfExtents;
  const colliderDesc = RAPIER.ColliderDesc.cuboid(hx, hy, hz)
    .setDensity(TUNING.chassisMass / (8 * hx * hy * hz))
    .setFriction(0.6)
    .setRestitution(0.05);
  world.createCollider(colliderDesc, body);

  return {
    body,
    spawn: { ...position },
    smoothedSteer: 0,           // tracks input.steer with rate-limited slewing
    speedKmh: 0,
    slipAngleDeg: 0,
    // Render-interpolation snapshots (read by vehicle.js#updateVehicleMesh)
    prevTranslation: { x: position.x, y: position.y, z: position.z },
    prevRotation:    { x: 0, y: 0, z: 0, w: 1 },
    currTranslation: { x: position.x, y: position.y, z: position.z },
    currRotation:    { x: 0, y: 0, z: 0, w: 1 },
  };
}

/** Snap the vehicle back to its spawn pose with zero velocities. */
export function resetVehicle(vehicle) {
  vehicle.body.setTranslation(vehicle.spawn, true);
  vehicle.body.setRotation({ x: 0, y: 0, z: 0, w: 1 }, true);
  vehicle.body.setLinvel({ x: 0, y: 0, z: 0 }, true);
  vehicle.body.setAngvel({ x: 0, y: 0, z: 0 }, true);
  vehicle.smoothedSteer = 0;
  vehicle.speedKmh = 0;
  vehicle.slipAngleDeg = 0;
  // Refresh interpolation snapshots so the mesh doesn't tween across the
  // teleport (which would flash a long streak between old and new pose).
  vehicle.prevTranslation = { ...vehicle.spawn };
  vehicle.currTranslation = { ...vehicle.spawn };
  vehicle.prevRotation = { x: 0, y: 0, z: 0, w: 1 };
  vehicle.currRotation = { x: 0, y: 0, z: 0, w: 1 };
}

// -----------------------------------------------------------------------------
// stepVehicle — the per-physics-tick force/impulse application + world.step()
// -----------------------------------------------------------------------------

// Reusable Three.js math objects so we don't allocate every frame.
const _q       = new THREE.Quaternion();
const _forward = new THREE.Vector3();
const _right   = new THREE.Vector3();
const _vel     = new THREE.Vector3();
const _r       = new THREE.Vector3();   // axle offset from CoM (world)
const _vAxle   = new THREE.Vector3();   // velocity at axle point
const _imp     = new THREE.Vector3();   // impulse vector
const _F_FORWARD = new THREE.Vector3(0, 0, -1);
const _R_RIGHT   = new THREE.Vector3(1, 0, 0);

/**
 * Run one fixed-timestep physics step for the vehicle.
 *
 * Order matters:
 *   1) snapshot prev transform for render interpolation
 *   2) smooth steering input
 *   3) compute body-local axes + velocities
 *   4) apply throttle / brake
 *   5) apply per-axle lateral grip impulses (with lift-off oversteer check)
 *   6) apply downforce
 *   7) apply yaw torque from steering
 *   8) apply aero/rolling drag
 *   9) world.step()
 *  10) snapshot current transform + derived debug state (speed, slip)
 *
 * @param vehicle  result of createVehicle()
 * @param input    {throttle, brake, steer, reset} from input.js
 * @param dt       fixed seconds per step (1/60 in Phase 1)
 */
export function stepVehicle(world, vehicle, input, dt) {
  const { body } = vehicle;

  // 1) Snapshot pre-step transform — vehicle.js will lerp/slerp between this
  //    and currTranslation/currRotation by the render-frame alpha.
  const t0 = body.translation();
  const r0 = body.rotation();
  vehicle.prevTranslation.x = t0.x;
  vehicle.prevTranslation.y = t0.y;
  vehicle.prevTranslation.z = t0.z;
  vehicle.prevRotation.x = r0.x;
  vehicle.prevRotation.y = r0.y;
  vehicle.prevRotation.z = r0.z;
  vehicle.prevRotation.w = r0.w;

  // 2) Smooth the binary keyboard steer toward target by `steerInputRate`.
  const target = input.steer;
  const delta  = target - vehicle.smoothedSteer;
  const maxStep = TUNING.steerInputRate * dt;
  if (Math.abs(delta) <= maxStep) vehicle.smoothedSteer = target;
  else vehicle.smoothedSteer += Math.sign(delta) * maxStep;

  // 3) Body axes in world frame.
  _q.set(r0.x, r0.y, r0.z, r0.w);
  _forward.copy(_F_FORWARD).applyQuaternion(_q);   // body -Z
  _right  .copy(_R_RIGHT  ).applyQuaternion(_q);   // body +X

  const linvel = body.linvel();
  _vel.set(linvel.x, linvel.y, linvel.z);
  const speedAbs     = _vel.length();                                 // m/s, scalar
  const speedNorm    = Math.min(speedAbs / APPROX_TOP_SPEED_MS, 1);   // 0..1
  const forwardSpeed = _vel.dot(_forward);                            // signed m/s

  // 4) Throttle / brake. Throttle pushes along +forward; brake pushes
  //    against motion when moving forward, or applies weak reverse otherwise.
  let longForce = 0;
  if (input.throttle > 0) {
    longForce += TUNING.engineForce * input.throttle;
  }
  if (input.brake > 0) {
    if (forwardSpeed > 1) {
      longForce -= TUNING.brakeForce * input.brake;
    } else {
      longForce -= TUNING.reverseForce * input.brake;
    }
  }
  body.addForce(
    { x: _forward.x * longForce, y: _forward.y * longForce, z: _forward.z * longForce },
    true,
  );

  // 5) Lateral grip impulses at front and rear axles.
  //    Front grip slightly > rear gives natural turn-in.
  //    Lift-off oversteer = drop rear grip when player coasts and steers.
  const angvel = body.angvel();
  const liftingOff = (
    input.throttle === 0 &&
    input.brake === 0 &&
    speedAbs > TUNING.liftOffSpeedThresh &&
    Math.abs(input.steer) > 0.1
  );
  const massPerAxle = TUNING.chassisMass * 0.5;

  for (const axle of [
    { offsetZ: TUNING.frontAxleOffsetZ, grip: TUNING.frontLatGrip },
    { offsetZ: TUNING.rearAxleOffsetZ,
      grip: TUNING.rearLatGrip * (liftingOff ? TUNING.liftOffOversteerMul : 1) },
  ]) {
    // r = body→axle in world. Local axle is (0,0,offsetZ); convention has
    // -Z forward, so a negative offsetZ produces a +forward world offset.
    _r.copy(_forward).multiplyScalar(-axle.offsetZ);

    // velocity at axle = linvel + angvel × r
    _vAxle.set(
      linvel.x + (angvel.y * _r.z - angvel.z * _r.y),
      linvel.y + (angvel.z * _r.x - angvel.x * _r.z),
      linvel.z + (angvel.x * _r.y - angvel.y * _r.x),
    );

    // lateral velocity component (along chassis +X)
    const vLat = _vAxle.dot(_right);

    // Impulse opposing that lateral velocity. Magnitude derived from
    // a_lat = -grip × vLat → impulse = mass/2 × grip × (-vLat) × dt.
    const impMag = -vLat * axle.grip * massPerAxle * dt;
    _imp.copy(_right).multiplyScalar(impMag);

    body.applyImpulseAtPoint(
      { x: _imp.x, y: _imp.y, z: _imp.z },
      { x: t0.x + _r.x, y: t0.y + _r.y, z: t0.z + _r.z },
      true,
    );
  }

  // 6) Downforce. Doesn't push the body sideways at lean — by using world -Y
  //    we keep it as "stick to the ground" rather than "stick to the floor of
  //    the car". Phase 1 ground is flat so the distinction doesn't matter,
  //    but it'll matter on banked sections later.
  const downforce = TUNING.downforceCoef * speedAbs * speedAbs;
  body.addForce({ x: 0, y: -downforce, z: 0 }, true);

  // 7) Yaw torque. Note the negative sign on Y: in our coordinate system
  //    a positive Y rotation rotates +Z toward +X (right-hand rule), which
  //    means forward (-Z) rotates toward -X — a LEFT turn. Player steer +1
  //    means RIGHT, so we negate.
  const maxSteer = TUNING.maxSteerLow +
                   (TUNING.maxSteerHigh - TUNING.maxSteerLow) * speedNorm;
  const steerAng = vehicle.smoothedSteer * maxSteer;
  const yawFactor = TUNING.yawSpeedFloor +
                    (1 - TUNING.yawSpeedFloor) * speedNorm;
  const yawTorque = -steerAng * TUNING.yawTorqueGain * yawFactor;
  body.addTorque({ x: 0, y: yawTorque, z: 0 }, true);

  // 8) Aero/rolling drag opposing the velocity vector. Using velocity (not
  //    forward) ensures sideways and reverse motion both decelerate too.
  if (speedAbs > 0.1) {
    const dragMag = TUNING.dragCoefficient * speedAbs * speedAbs;
    const inv = 1 / speedAbs;
    body.addForce(
      { x: -linvel.x * inv * dragMag,
        y: -linvel.y * inv * dragMag,
        z: -linvel.z * inv * dragMag },
      true,
    );
  }

  // 9) Step.
  world.step();

  // 10) Post-step snapshot + debug derived state.
  const t1 = body.translation();
  const r1 = body.rotation();
  vehicle.currTranslation.x = t1.x;
  vehicle.currTranslation.y = t1.y;
  vehicle.currTranslation.z = t1.z;
  vehicle.currRotation.x = r1.x;
  vehicle.currRotation.y = r1.y;
  vehicle.currRotation.z = r1.z;
  vehicle.currRotation.w = r1.w;

  // Recompute speed from the post-step velocity (more accurate for HUD).
  const lv1 = body.linvel();
  const speed1 = Math.sqrt(lv1.x * lv1.x + lv1.y * lv1.y + lv1.z * lv1.z);
  vehicle.speedKmh = speed1 * 3.6;

  // Slip angle: angle between forward and velocity, signed. Positive = car
  // is sliding to the right of where it's pointed (typical drifting reading).
  if (speed1 > 1) {
    _q.set(r1.x, r1.y, r1.z, r1.w);
    _forward.copy(_F_FORWARD).applyQuaternion(_q);
    const fwdDotV = (_forward.x * lv1.x + _forward.y * lv1.y + _forward.z * lv1.z) / speed1;
    const ang = Math.acos(Math.max(-1, Math.min(1, fwdDotV)));
    // Cross-product Y component gives the sign.
    const crossY = _forward.z * lv1.x - _forward.x * lv1.z;
    vehicle.slipAngleDeg = (ang * 180 / Math.PI) * Math.sign(crossY || 1);
  } else {
    vehicle.slipAngleDeg = 0;
  }
}
