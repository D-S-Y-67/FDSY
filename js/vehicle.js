// Low-poly F1 car mesh + interpolated transform sync.
//
// Coordinate convention used throughout the codebase:
//   +X = right, +Y = up, -Z = forward
// The car is built so its "nose" points down -Z; chassis length runs along Z.
//
// All geometry is programmatic (no GLTF), all materials are flat-shaded.
// Phase 5 will introduce a livery system that paints `primary` and `accent`
// from the player's selected team — for now the defaults give a McLaren-ish
// papaya placeholder.

import * as THREE from "three";

// --- Default placeholder livery (papaya orange + carbon black) ---
const DEFAULT_PRIMARY = 0xff8000;
const DEFAULT_ACCENT  = 0x111111;
const TIRE_COLOR      = 0x1a1a1a;
const RIM_COLOR       = 0xc8c8cc;
const HELMET_COLOR    = 0xfafafa;
const HALO_COLOR      = 0x222222;
const DRIVER_VISOR    = 0x101820;

/**
 * Build the F1 car mesh. The returned Group's local origin sits at the
 * chassis centre of mass — this matches the rigid body in physics.js so we
 * can copy translation/rotation directly without offset math.
 *
 * @param {{ primary?: number, accent?: number }} [colors]
 * @returns {THREE.Group}
 */
export function buildF1Mesh({ primary = DEFAULT_PRIMARY, accent = DEFAULT_ACCENT } = {}) {
  const car = new THREE.Group();
  car.name = "F1Car";

  const bodyMat   = new THREE.MeshStandardMaterial({ color: primary, flatShading: true, roughness: 0.55 });
  const accentMat = new THREE.MeshStandardMaterial({ color: accent,  flatShading: true, roughness: 0.45 });
  const tireMat   = new THREE.MeshStandardMaterial({ color: TIRE_COLOR, flatShading: true, roughness: 0.85 });
  const rimMat    = new THREE.MeshStandardMaterial({ color: RIM_COLOR,  flatShading: true, roughness: 0.4, metalness: 0.6 });
  const helmetMat = new THREE.MeshStandardMaterial({ color: HELMET_COLOR, flatShading: true, roughness: 0.3 });
  const haloMat   = new THREE.MeshStandardMaterial({ color: HALO_COLOR, flatShading: true, roughness: 0.5 });
  const visorMat  = new THREE.MeshStandardMaterial({ color: DRIVER_VISOR, flatShading: true, roughness: 0.2 });

  // --- Chassis (monocoque) ---
  // Long thin slab. Nose/wings/airbox attach to it.
  const chassis = new THREE.Mesh(new THREE.BoxGeometry(1.0, 0.45, 3.2), bodyMat);
  chassis.position.set(0, 0.05, 0);
  chassis.castShadow = chassis.receiveShadow = true;
  car.add(chassis);

  // Floor — wide flat plate giving the car visual width near the ground.
  const floor = new THREE.Mesh(new THREE.BoxGeometry(1.7, 0.08, 4.0), accentMat);
  floor.position.set(0, -0.18, 0);
  floor.castShadow = floor.receiveShadow = true;
  car.add(floor);

  // --- Nose cone ---
  // Tapered prism from chassis front to front wing. We build a custom
  // BufferGeometry: trapezoidal box where the front face is narrower and
  // shorter than the rear face.
  const nose = new THREE.Mesh(buildTaperedBoxGeometry({
    rearWidth: 0.7, rearHeight: 0.4,
    frontWidth: 0.2, frontHeight: 0.18,
    length: 1.4,
  }), bodyMat);
  nose.position.set(0, 0.08, -2.1);  // sits ahead of chassis
  nose.castShadow = nose.receiveShadow = true;
  car.add(nose);

  // --- Front wing ---
  const fWing = new THREE.Mesh(new THREE.BoxGeometry(1.7, 0.06, 0.55), bodyMat);
  fWing.position.set(0, -0.16, -2.7);
  fWing.castShadow = fWing.receiveShadow = true;
  car.add(fWing);

  // Front-wing endplates (two thin verticals at the wing tips)
  for (const x of [-0.85, 0.85]) {
    const ep = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.28, 0.55), accentMat);
    ep.position.set(x, -0.05, -2.7);
    ep.castShadow = true;
    car.add(ep);
  }

  // --- Sidepods ---
  // Two slim tapered blocks flanking the cockpit. Visual mass at midship.
  for (const x of [-0.65, 0.65]) {
    const pod = new THREE.Mesh(buildTaperedBoxGeometry({
      rearWidth: 0.45, rearHeight: 0.45,
      frontWidth: 0.25, frontHeight: 0.3,
      length: 1.6,
    }), bodyMat);
    pod.position.set(x, -0.02, 0.1);
    pod.castShadow = pod.receiveShadow = true;
    car.add(pod);
  }

  // --- Cockpit opening + helmet ---
  // A small inset block carved into the chassis top suggests the cockpit;
  // the helmet sits inside it.
  const cockpit = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.12, 0.7), accentMat);
  cockpit.position.set(0, 0.32, -0.4);
  car.add(cockpit);

  const helmet = new THREE.Mesh(new THREE.SphereGeometry(0.22, 8, 6), helmetMat);
  helmet.position.set(0, 0.5, -0.35);
  helmet.scale.set(1, 0.95, 1.05);
  helmet.castShadow = true;
  car.add(helmet);

  // Visor — flat strip clipped to the helmet front
  const visor = new THREE.Mesh(new THREE.BoxGeometry(0.32, 0.08, 0.05), visorMat);
  visor.position.set(0, 0.52, -0.55);
  car.add(visor);

  // --- Halo ---
  // A thin curved arch over the cockpit. We approximate with a torus rotated
  // so half of it sits above the cockpit, plus a forward strut.
  const halo = new THREE.Mesh(new THREE.TorusGeometry(0.35, 0.035, 6, 18, Math.PI), haloMat);
  halo.rotation.set(0, 0, Math.PI);  // flip so the curve opens downward
  halo.position.set(0, 0.62, -0.4);
  halo.castShadow = true;
  car.add(halo);

  const haloStrut = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.05, 0.4), haloMat);
  haloStrut.position.set(0, 0.62, -0.6);
  car.add(haloStrut);

  // --- Airbox / engine cover ---
  // Tall scoop behind the cockpit feeding the engine in real F1 cars.
  const airbox = new THREE.Mesh(buildTaperedBoxGeometry({
    rearWidth: 0.55, rearHeight: 0.2,
    frontWidth: 0.45, frontHeight: 0.45,
    length: 1.3,
  }), bodyMat);
  airbox.position.set(0, 0.42, 0.55);
  airbox.castShadow = airbox.receiveShadow = true;
  car.add(airbox);

  // --- Rear wing ---
  // Raised on a thin pylon behind the rear axle.
  const rPylon = new THREE.Mesh(new THREE.BoxGeometry(0.1, 0.45, 0.18), accentMat);
  rPylon.position.set(0, 0.5, 1.95);
  car.add(rPylon);

  const rWing = new THREE.Mesh(new THREE.BoxGeometry(1.3, 0.06, 0.4), bodyMat);
  rWing.position.set(0, 0.7, 1.95);
  rWing.castShadow = true;
  car.add(rWing);

  // Rear-wing endplates
  for (const x of [-0.65, 0.65]) {
    const ep = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.45, 0.4), accentMat);
    ep.position.set(x, 0.55, 1.95);
    ep.castShadow = true;
    car.add(ep);
  }

  // --- Wheels ---
  // Cylinders rotated 90° so their axis runs along X. Positions match the
  // axle offsets used by the physics step in physics.js (TUNING.frontAxleOffsetZ
  // = -1.5 / rearAxleOffsetZ = +1.5). If you change those numbers, mirror them
  // here so the visuals follow.
  const wheelGeo = new THREE.CylinderGeometry(0.36, 0.36, 0.32, 14);
  wheelGeo.rotateZ(Math.PI / 2);

  const wheels = [];
  const frontWheels = [];
  const wheelPositions = [
    { x: -0.85, y: -0.05, z: -1.5, name: "FL", front: true  },
    { x:  0.85, y: -0.05, z: -1.5, name: "FR", front: true  },
    { x: -0.85, y: -0.05, z:  1.5, name: "RL", front: false },
    { x:  0.85, y: -0.05, z:  1.5, name: "RR", front: false },
  ];
  for (const p of wheelPositions) {
    const wheel = new THREE.Mesh(wheelGeo, tireMat);
    wheel.position.set(p.x, p.y, p.z);
    wheel.castShadow = true;
    wheel.name = `wheel_${p.name}`;

    // Rim disc — visual interest at the wheel face. Phase 1 doesn't spin
    // the wheels independently (we'd need angular wheel state from physics
    // for that — comes in Phase 7 alongside tire compounds).
    const rim = new THREE.Mesh(
      new THREE.CylinderGeometry(0.18, 0.18, 0.34, 8),
      rimMat,
    );
    rim.rotation.z = Math.PI / 2;
    wheel.add(rim);

    car.add(wheel);
    wheels.push(wheel);
    if (p.front) frontWheels.push(wheel);
  }

  // Stash references on the group so future phases (tire deg colour shifts,
  // wheel-spin once we track angular state, etc.) can grab them without
  // re-traversing the scene tree. `frontWheels` is updated each frame by
  // updateVehicleMesh() so the wheels visibly turn with the steering input.
  car.userData.wheels = wheels;
  car.userData.frontWheels = frontWheels;
  car.userData.bodyMaterial = bodyMat;
  car.userData.accentMaterial = accentMat;

  return car;
}

// Visual steer angle for the front wheels (radians at full lock). Real F1
// cars only steer ~14°, so even at smoothedSteer=±1 the wheels don't crank
// to the chassis-yaw maxSteerLow value (which can be 28°).
const VISUAL_STEER_LOCK = 16 * Math.PI / 180;

// ---------------------------------------------------------------------------
// Mesh sync — copies the interpolated physics transform onto the visual mesh.
// `vehicle.prev*` is the transform at the start of the most recent fixed
// physics step, `vehicle.curr*` at the end. `alpha` ∈ [0,1] is how far through
// the next step we are at render time (see game.js for the accumulator).
// ---------------------------------------------------------------------------

const _tmpPos = new THREE.Vector3();
const _tmpQuat = new THREE.Quaternion();
const _prevPos = new THREE.Vector3();
const _prevQuat = new THREE.Quaternion();

export function updateVehicleMesh(mesh, vehicle, alpha) {
  _prevPos.set(vehicle.prevTranslation.x, vehicle.prevTranslation.y, vehicle.prevTranslation.z);
  _tmpPos.set(vehicle.currTranslation.x, vehicle.currTranslation.y, vehicle.currTranslation.z);
  mesh.position.lerpVectors(_prevPos, _tmpPos, alpha);

  _prevQuat.set(vehicle.prevRotation.x, vehicle.prevRotation.y, vehicle.prevRotation.z, vehicle.prevRotation.w);
  _tmpQuat.set(vehicle.currRotation.x, vehicle.currRotation.y, vehicle.currRotation.z, vehicle.currRotation.w);
  mesh.quaternion.slerpQuaternions(_prevQuat, _tmpQuat, alpha);

  // Front-wheel steer visualisation. Sign is negated so positive steer
  // (right) rotates the wheels clockwise viewed from above, matching the
  // chassis yaw direction we apply in physics.
  const steerVis = -vehicle.smoothedSteer * VISUAL_STEER_LOCK;
  const fronts = mesh.userData.frontWheels;
  if (fronts) {
    for (const w of fronts) w.rotation.y = steerVis;
  }
}

// ---------------------------------------------------------------------------
// Tapered-box geometry helper.
// Builds a 6-face polyhedron whose front face (at -Z half-length) has a
// different width and height than the rear face (at +Z half-length). Used for
// noses, sidepods, and airbox where simple BoxGeometry would look too brick-like.
// ---------------------------------------------------------------------------
function buildTaperedBoxGeometry({ rearWidth, rearHeight, frontWidth, frontHeight, length }) {
  const rw = rearWidth / 2,  rh = rearHeight / 2;
  const fw = frontWidth / 2, fh = frontHeight / 2;
  const hl = length / 2;

  // 8 corners: 4 at rear (z=+hl), 4 at front (z=-hl)
  const v = [
    -rw, -rh,  hl,   rw, -rh,  hl,   rw,  rh,  hl,  -rw,  rh,  hl,   // rear face (0..3)
    -fw, -fh, -hl,   fw, -fh, -hl,   fw,  fh, -hl,  -fw,  fh, -hl,   // front face (4..7)
  ];
  // CCW winding for outward-facing normals.
  const idx = [
    // rear (looking from +Z): 0,1,2,3 wound CCW => 0,1,2 + 0,2,3
    0, 1, 2,  0, 2, 3,
    // front (looking from -Z): reversed
    4, 6, 5,  4, 7, 6,
    // bottom (y=-h): 0,1 rear, 5,4 front
    0, 4, 5,  0, 5, 1,
    // top (y=+h): 3,2 rear, 6,7 front
    3, 2, 6,  3, 6, 7,
    // left (x=-): 0,3 rear, 7,4 front
    0, 3, 7,  0, 7, 4,
    // right (x=+): 1,5 front, 6,2 rear
    1, 5, 6,  1, 6, 2,
  ];

  const geo = new THREE.BufferGeometry();
  geo.setAttribute("position", new THREE.Float32BufferAttribute(v, 3));
  geo.setIndex(idx);
  geo.computeVertexNormals();
  return geo;
}
