// Game loop, fixed-timestep physics + render-rate interpolation, chase camera.
//
// We run physics at a hard 60 Hz inside a `while` accumulator. The render loop
// fires every `requestAnimationFrame` and lerps the visual mesh between the
// last two physics snapshots by `alpha = accumulator / FIXED_DT`. This is the
// same pattern PolyTrack and most arcade racers use, and it's worth getting
// right in Phase 1 because variable-dt arcade physics produces speed-dependent
// feel changes when framerate dips.

import * as THREE from "three";
import { TUNING, stepVehicle, resetVehicle } from "./physics.js";
import { updateVehicleMesh } from "./vehicle.js";
import { readInput } from "./input.js";
import { updateHud } from "./ui.js";
import { detectCrossings } from "./track.js";
import { updateTiming, resetTiming } from "./systems/timing.js";

const FIXED_DT = 1 / 60;          // physics tick — do NOT vary this
const MAX_FRAME_DT = 0.25;        // clamp to survive tab-switches / breakpoints

// Chase-camera state. Held outside the loop so we keep continuity across rAF
// frames; both vectors lerp toward target each frame for that "looks slightly
// laggy, in a good way" feel.
const _camPos       = new THREE.Vector3();
const _camLookAt    = new THREE.Vector3();
const _camTargetPos = new THREE.Vector3();
const _camTargetLook= new THREE.Vector3();
const _carPos       = new THREE.Vector3();
const _carQuat      = new THREE.Quaternion();
const _carVel       = new THREE.Vector3();
const _localOffset  = new THREE.Vector3();
const _forward      = new THREE.Vector3();
const _yawQuat      = new THREE.Quaternion();
const _F            = new THREE.Vector3(0, 0, -1);
const _UP           = new THREE.Vector3(0, 1, 0);

let cameraInitialized = false;

/**
 * Start the main game loop. Returns the frame-id of the active rAF if you
 * ever need to cancel it (unused in Phase 1).
 */
export function startLoop({ scene, camera, renderer, world, vehicle, mesh, track, timing }) {
  let lastTime = performance.now();
  let accumulator = 0;
  let frameId = 0;

  // Track previous XZ to detect crossings (segment intersection between
  // prev → curr and each crossing line). Initialise from spawn so the
  // first physics step doesn't false-trigger on a giant jump from origin.
  let prevX = vehicle.spawn.x;
  let prevZ = vehicle.spawn.z;

  function frame(now) {
    frameId = requestAnimationFrame(frame);

    // dt for this rendered frame (seconds)
    let frameDt = (now - lastTime) / 1000;
    lastTime = now;
    if (frameDt > MAX_FRAME_DT) frameDt = MAX_FRAME_DT;

    // Read input once per render frame; physics gets the same struct on
    // every sub-step within that frame so behaviour stays deterministic
    // regardless of how many physics steps happen between renders.
    const input = readInput();
    if (input.reset) {
      resetVehicle(vehicle);
      resetTiming(timing);
      prevX = vehicle.spawn.x;
      prevZ = vehicle.spawn.z;
    }

    // --- physics: fixed-timestep accumulator ---
    accumulator += frameDt;
    let physicsSteps = 0;
    while (accumulator >= FIXED_DT) {
      stepVehicle(world, vehicle, input, FIXED_DT);

      // Crossing detection runs at the same rate as physics so we never
      // miss a thin sector line between frames at high speed.
      const ct = vehicle.body.translation();
      const events = detectCrossings(track, prevX, prevZ, ct.x, ct.z);
      if (events.length) {
        updateTiming(timing, events, performance.now());
      }
      prevX = ct.x;
      prevZ = ct.z;

      accumulator -= FIXED_DT;
      // Safety: don't spiral the simulation if a long pause happened.
      if (++physicsSteps >= 5) { accumulator = 0; break; }
    }

    // Wall-clock readouts (current lap/sector ms) tick every render frame
    // even when no crossings happen.
    updateTiming(timing, [], performance.now());

    // --- render: interpolate visual mesh between physics snapshots ---
    const alpha = accumulator / FIXED_DT;
    updateVehicleMesh(mesh, vehicle, alpha);

    // --- chase camera ---
    updateChaseCamera(camera, vehicle, mesh, frameDt);

    updateHud(vehicle, input, timing, frameDt);
    renderer.render(scene, camera);
  }

  frameId = requestAnimationFrame(frame);
  return () => cancelAnimationFrame(frameId);
}

/**
 * Spring-damped chase camera. Position trails the car from a body-local
 * offset (behind+above) and the look-at point sits a few metres ahead of the
 * car along its velocity direction (so the camera "looks where you're going",
 * not where you're pointed — gives the slight lead the brief asks for).
 *
 * Critically damped feel comes from `1 - exp(-k*dt)` blending, which is
 * framerate-independent (vs `lerp(t, k*dt)` which is not).
 */
function updateChaseCamera(camera, vehicle, mesh, dt) {
  // Read interpolated mesh transform (rather than physics body) so the
  // camera tracks exactly what the player sees on screen.
  _carPos.copy(mesh.position);
  _carQuat.copy(mesh.quaternion);

  // Velocity from physics body (not interpolated, but we just need direction)
  const lv = vehicle.body.linvel();
  _carVel.set(lv.x, lv.y, lv.z);
  const speed = _carVel.length();

  // Build a yaw-only quaternion from the chassis heading. Even though the
  // physics body is now constrained to Y-axis rotation, we keep the camera
  // strictly yaw-driven as defense in depth — a tilted camera makes the
  // world appear to spin (the "W turns the car" symptom from earlier).
  _forward.copy(_F).applyQuaternion(_carQuat);
  const yaw = Math.atan2(_forward.x, _forward.z);  // 0 when forward = -Z
  _yawQuat.setFromAxisAngle(_UP, yaw + Math.PI);    // +π because forward is -Z

  // --- target camera position: body-local offset rotated by YAW ONLY ---
  _localOffset.fromArray(TUNING.camPosOffset).applyQuaternion(_yawQuat);
  _camTargetPos.copy(_carPos).add(_localOffset);

  // --- target look-at ---
  // Normally we look ahead along the velocity vector (gives the slight lead
  // that "looks where you're going" feel). But when reversing, that would
  // whip the camera around behind the car. So if the car is moving with
  // negative forward-speed (= reversing), we look along the chassis heading
  // instead — camera stays oriented along the nose, world scrolls past.
  if (speed > 1 && vehicle.forwardSpeedSigned > 0) {
    _camTargetLook.copy(_carVel).normalize().multiplyScalar(TUNING.camLookAheadDist);
  } else {
    _camTargetLook.copy(_forward).multiplyScalar(TUNING.camLookAheadDist);
  }
  _camTargetLook.add(_carPos);

  if (!cameraInitialized) {
    _camPos.copy(_camTargetPos);
    _camLookAt.copy(_camTargetLook);
    cameraInitialized = true;
  } else {
    const aPos  = 1 - Math.exp(-TUNING.camPosResponse  * dt);
    const aLook = 1 - Math.exp(-TUNING.camLookResponse * dt);
    _camPos.lerp(_camTargetPos, aPos);
    _camLookAt.lerp(_camTargetLook, aLook);
  }

  camera.position.copy(_camPos);
  camera.lookAt(_camLookAt);
}
