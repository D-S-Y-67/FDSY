// Track loading: data → THREE meshes + Rapier static colliders.
//
// Public API:
//   loadTrack(world, scene, trackData) → {
//     group:           THREE.Group,
//     crossings:       array of { kind, index, segment, dirX, dirZ },
//     wallColliders:   Rapier Colliders[]
//   }
//   detectCrossings(track, prevX, prevZ, currX, currZ) → array of fired events
//
// `crossings` is an immutable list built once at load time. Each entry
// describes a 2D line segment perpendicular to the centerline at a specific
// waypoint index. detectCrossings tests the car's per-frame movement
// (prev → curr) against each crossing line. We test both directions of
// crossing — caller decides which direction "counts" via the dot product
// of car's forward direction and the crossing's tangent.

import * as THREE from "three";
import RAPIER from "rapier";

// ---------------------------------------------------------------------------
// Math helpers
// ---------------------------------------------------------------------------

/** Returns true if segments AB and CD intersect (strict, no endpoint touches). */
function segmentsIntersect(ax, az, bx, bz, cx, cz, dx, dz) {
  const d1x = bx - ax, d1z = bz - az;
  const d2x = dx - cx, d2z = dz - cz;
  const denom = d1x * d2z - d1z * d2x;
  if (Math.abs(denom) < 1e-9) return false;     // parallel
  const sx = ax - cx, sz = az - cz;
  const t = (sx * d2z - sz * d2x) / denom;
  const u = (sx * d1z - sz * d1x) / denom;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1;
}

/** Tangent direction at waypoint i (from i-1 to i+1, normalised). */
function tangentAt(waypoints, i) {
  const N = waypoints.length;
  const a = waypoints[(i - 1 + N) % N];
  const b = waypoints[(i + 1) % N];
  const dx = b.x - a.x;
  const dz = b.z - a.z;
  const len = Math.hypot(dx, dz) || 1;
  return { x: dx / len, z: dz / len };
}

/**
 * Mitered perpendicular at waypoint i. For straight sections the miter
 * matches the unit perpendicular to the segment direction; on corners it
 * lengthens to keep the offset edges parallel to neighbouring segments
 * (avoids gaps and overlaps). Returned vector points to the LEFT of the
 * direction of travel.
 */
function leftMiterAt(waypoints, i) {
  const N = waypoints.length;
  const prev = waypoints[(i - 1 + N) % N];
  const curr = waypoints[i];
  const next = waypoints[(i + 1) % N];

  const inX = curr.x - prev.x, inZ = curr.z - prev.z;
  const ouX = next.x - curr.x, ouZ = next.z - curr.z;
  const inLen = Math.hypot(inX, inZ) || 1;
  const ouLen = Math.hypot(ouX, ouZ) || 1;

  // Left perpendicular to a forward direction (fx, fz) is (-fz, fx) — that's
  // a 90° CCW rotation viewed from above, which is "left" of forward in our
  // top-down convention.
  const inLx = -inZ / inLen, inLz = inX / inLen;
  const ouLx = -ouZ / ouLen, ouLz = ouX / ouLen;

  const mx = inLx + ouLx, mz = inLz + ouLz;
  const mLen = Math.hypot(mx, mz) || 1;

  // Miter length scaling: 1 / (m̂ · n̂) where n̂ is one of the perpendiculars.
  // This keeps the offset edge consistently `width` away from the centerline.
  const dot = (mx / mLen) * inLx + (mz / mLen) * inLz;
  const scale = dot > 0.05 ? 1 / dot : 1;     // clamp on near-180° folds
  return {
    x: (mx / mLen) * scale,
    z: (mz / mLen) * scale,
  };
}

// ---------------------------------------------------------------------------
// Tarmac strip — single BufferGeometry covering the whole lap.
// ---------------------------------------------------------------------------

function buildTarmacGeometry(waypoints, halfWidth) {
  const N = waypoints.length;
  // Two vertices per waypoint (left edge, right edge), closed loop — last
  // waypoint connects back to the first. Hence (N) pairs and (N) quads.
  const positions = new Float32Array(N * 2 * 3);
  const indices   = new Uint32Array(N * 2 * 3);

  for (let i = 0; i < N; i++) {
    const w = waypoints[i];
    const m = leftMiterAt(waypoints, i);
    const lx = w.x + m.x * halfWidth;
    const lz = w.z + m.z * halfWidth;
    const rx = w.x - m.x * halfWidth;
    const rz = w.z - m.z * halfWidth;
    // Slightly above ground (0.02m) to avoid z-fighting with the infield.
    positions[i * 6 + 0] = lx;  positions[i * 6 + 1] = 0.02;  positions[i * 6 + 2] = lz;
    positions[i * 6 + 3] = rx;  positions[i * 6 + 4] = 0.02;  positions[i * 6 + 5] = rz;
  }

  // Quad i connects vertices (2i, 2i+1, 2(i+1), 2(i+1)+1).
  for (let i = 0; i < N; i++) {
    const a = (2 * i) % (2 * N);
    const b = a + 1;
    const c = (2 * (i + 1)) % (2 * N);
    const d = c + 1;
    const idx = i * 6;
    // Two triangles per quad. Wind both CCW from above (normal = +Y).
    indices[idx + 0] = a;
    indices[idx + 1] = c;
    indices[idx + 2] = b;
    indices[idx + 3] = b;
    indices[idx + 4] = c;
    indices[idx + 5] = d;
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geo.setIndex(new THREE.BufferAttribute(indices, 1));
  geo.computeVertexNormals();
  return geo;
}

// ---------------------------------------------------------------------------
// Walls — thin upright cuboids along left/right offset paths.
// ---------------------------------------------------------------------------

function buildWalls(world, scene, waypoints, halfWidth, wallHeight, wallThickness, wallColor) {
  const N = waypoints.length;
  const wallMat = new THREE.MeshStandardMaterial({
    color: wallColor,
    flatShading: true,
    roughness: 0.85,
  });
  const colliders = [];

  // For each segment between consecutive waypoints, build a left wall and
  // a right wall as thin oriented boxes. Visuals use BoxGeometry; physics
  // uses a Rapier static cuboid collider with the same transform.
  for (let i = 0; i < N; i++) {
    const a = waypoints[i];
    const b = waypoints[(i + 1) % N];
    const ma = leftMiterAt(waypoints, i);
    const mb = leftMiterAt(waypoints, (i + 1) % N);

    for (const side of [+1, -1]) {
      const ax = a.x + ma.x * halfWidth * side;
      const az = a.z + ma.z * halfWidth * side;
      const bx = b.x + mb.x * halfWidth * side;
      const bz = b.z + mb.z * halfWidth * side;

      const segLen = Math.hypot(bx - ax, bz - az);
      if (segLen < 0.01) continue;

      const cx = (ax + bx) * 0.5;
      const cz = (az + bz) * 0.5;
      const cy = wallHeight * 0.5;
      // Yaw to rotate a box (default long axis +Z) to align its +Z with the
      // segment direction (bx-ax, bz-az). Three.js Y-rotation maps +Z to
      // (sin yaw, 0, cos yaw), so yaw = atan2(dx, dz).
      const yaw = Math.atan2(bx - ax, bz - az);

      // Visual mesh
      const geo = new THREE.BoxGeometry(wallThickness, wallHeight, segLen);
      const m = new THREE.Mesh(geo, wallMat);
      m.position.set(cx, cy, cz);
      m.rotation.y = yaw;
      m.castShadow = true;
      m.receiveShadow = true;
      scene.add(m);

      // Physics collider — fixed body + cuboid. Rapier's cuboid is
      // half-extents.
      const bodyDesc = RAPIER.RigidBodyDesc.fixed()
        .setTranslation(cx, cy, cz)
        .setRotation({
          x: 0,
          y: Math.sin(yaw / 2),
          z: 0,
          w: Math.cos(yaw / 2),
        });
      const body = world.createRigidBody(bodyDesc);
      const colDesc = RAPIER.ColliderDesc.cuboid(
        wallThickness * 0.5,
        wallHeight   * 0.5,
        segLen        * 0.5,
      ).setFriction(0.4).setRestitution(0.05);
      const col = world.createCollider(colDesc, body);
      colliders.push(col);
    }
  }

  return colliders;
}

// ---------------------------------------------------------------------------
// Kerbs — visual-only red/white striped quads on the inside of tight corners.
// ---------------------------------------------------------------------------

function buildKerbs(scene, waypoints, halfWidth, kerbA, kerbB) {
  const N = waypoints.length;
  const kerbWidth = 0.7;          // metres protruding from track edge
  const stripeLen = 1.2;          // metres per stripe
  const matA = new THREE.MeshStandardMaterial({ color: kerbA, flatShading: true });
  const matB = new THREE.MeshStandardMaterial({ color: kerbB, flatShading: true });

  const group = new THREE.Group();
  group.name = "kerbs";
  let stripeIdx = 0;

  for (let i = 0; i < N; i++) {
    const w = waypoints[i];
    const next = waypoints[(i + 1) % N];
    const curv = w.curvature || 0;
    if (Math.abs(curv) < 1 / 35) continue;       // only tight corners get kerbs

    // Inside of the corner is the side the curvature points toward. Right
    // turn (positive curvature) → inside is the LEFT of travel direction
    // (because right turn pulls the car right, the apex is on the right
    // wait — the inside of a right turn is on the right side of the car).
    // Reason: curvature positive = right turn = car arcs to the right =
    // the corner's apex is on the right. So we offset to the RIGHT (i.e.
    // -leftMiter). Conversely, left-turn (curvature negative) → kerb on left.
    const insideSide = curv > 0 ? -1 : +1;
    const m = leftMiterAt(waypoints, i);

    // Place kerb on the track edge at insideSide
    const ex = w.x + m.x * halfWidth * insideSide;
    const ez = w.z + m.z * halfWidth * insideSide;
    // Extend kerb outward from the track another kerbWidth in the same
    // direction (off-track side = same direction as insideSide miter).
    const ox = ex + m.x * kerbWidth * insideSide;
    const oz = ez + m.z * kerbWidth * insideSide;

    // Distance to next waypoint along same edge — this is the stripe length
    const nm = leftMiterAt(waypoints, (i + 1) % N);
    const ex2 = next.x + nm.x * halfWidth * insideSide;
    const ez2 = next.z + nm.z * halfWidth * insideSide;
    const ox2 = ex2 + nm.x * kerbWidth * insideSide;
    const oz2 = ez2 + nm.z * kerbWidth * insideSide;

    const segLen = Math.hypot(ex2 - ex, ez2 - ez);
    const stripes = Math.max(1, Math.round(segLen / stripeLen));
    const stripeStep = segLen / stripes;
    const dx = (ex2 - ex) / segLen;
    const dz = (ez2 - ez) / segLen;
    // Cross-track direction (from track edge to outside edge of kerb)
    const cx = (ox - ex) / kerbWidth;
    const cz = (oz - ez) / kerbWidth;

    for (let s = 0; s < stripes; s++) {
      const t0 = s * stripeStep;
      const t1 = (s + 1) * stripeStep;
      // Quad corners: edge-side at t0, edge-side at t1, outside at t1, outside at t0
      const v00x = ex + dx * t0,      v00z = ez + dz * t0;
      const v10x = ex + dx * t1,      v10z = ez + dz * t1;
      const v11x = v10x + cx * kerbWidth, v11z = v10z + cz * kerbWidth;
      const v01x = v00x + cx * kerbWidth, v01z = v00z + cz * kerbWidth;

      const geo = new THREE.BufferGeometry();
      const pos = new Float32Array([
        v00x, 0.04, v00z,
        v10x, 0.04, v10z,
        v11x, 0.04, v11z,
        v01x, 0.04, v01z,
      ]);
      geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
      // Normal-up only — tarmac and kerb are coplanar with infield.
      geo.setIndex([0, 2, 1, 0, 3, 2]);
      geo.computeVertexNormals();
      const mat = (stripeIdx++ & 1) ? matA : matB;
      const m2 = new THREE.Mesh(geo, mat);
      group.add(m2);
    }
  }
  scene.add(group);
  return group;
}

// ---------------------------------------------------------------------------
// Start/finish + sector + anti-cheat crossing lines.
// Built once; stored as a list. detectCrossings tests each one each frame.
// ---------------------------------------------------------------------------

function buildCrossings(waypoints, sectors, checkpointIndices, halfWidth) {
  const out = [];
  const make = (idx, kind) => {
    const w = waypoints[idx];
    const m = leftMiterAt(waypoints, idx);
    const t = tangentAt(waypoints, idx);
    out.push({
      kind, index: idx,
      // Two endpoints of the perpendicular line (on the track edges).
      ax: w.x + m.x * halfWidth, az: w.z + m.z * halfWidth,
      bx: w.x - m.x * halfWidth, bz: w.z - m.z * halfWidth,
      // Track tangent direction at this point — used to filter crossings
      // by direction of travel.
      tx: t.x, tz: t.z,
    });
  };
  make(0,             "startFinish");
  make(sectors.s1End, "sectorEnd1");
  make(sectors.s2End, "sectorEnd2");
  for (const ci of checkpointIndices) {
    make(ci, "checkpoint");
  }
  return out;
}

// ---------------------------------------------------------------------------
// Detect which crossings the car traversed since last frame.
// Called from game.js each physics step with the car's previous and current
// XZ positions. Returns an array of events:
//   { kind, index, dot }   where dot > 0 = crossed in forward direction
// ---------------------------------------------------------------------------

export function detectCrossings(track, prevX, prevZ, currX, currZ) {
  const events = [];
  // Cheap early-out: ignore if barely moved.
  if (Math.abs(currX - prevX) < 1e-4 && Math.abs(currZ - prevZ) < 1e-4) return events;

  const dx = currX - prevX, dz = currZ - prevZ;
  for (const c of track.crossings) {
    if (!segmentsIntersect(prevX, prevZ, currX, currZ, c.ax, c.az, c.bx, c.bz)) continue;
    // Direction of crossing: dot of car movement with track tangent.
    const dot = dx * c.tx + dz * c.tz;
    events.push({ kind: c.kind, index: c.index, dot });
  }
  return events;
}

// ---------------------------------------------------------------------------
// Main entry point.
// ---------------------------------------------------------------------------

export function loadTrack(world, scene, trackData) {
  const halfWidth = trackData.trackWidth * 0.5;

  const group = new THREE.Group();
  group.name = `track:${trackData.id}`;

  // Tarmac strip
  const tarmacGeo = buildTarmacGeometry(trackData.waypoints, halfWidth);
  const tarmacMat = new THREE.MeshStandardMaterial({
    color: trackData.theme.tarmac,
    flatShading: true,
    roughness: 0.95,
  });
  const tarmac = new THREE.Mesh(tarmacGeo, tarmacMat);
  tarmac.receiveShadow = true;
  group.add(tarmac);
  scene.add(group);

  // Walls (visual + collider)
  const wallColliders = buildWalls(
    world, scene, trackData.waypoints,
    halfWidth, trackData.wallHeight, trackData.wallThickness,
    trackData.theme.wall,
  );

  // Kerbs (visual only)
  buildKerbs(scene, trackData.waypoints, halfWidth, trackData.theme.kerbA, trackData.theme.kerbB);

  // Start/finish line — bright white quad on track surface, painted
  // perpendicular to centerline at waypoint 0.
  const sf = drawLineMarker(scene, trackData.waypoints, 0, halfWidth, trackData.theme.line, 1.2);
  // Sector boundary markers — narrower, also white.
  drawLineMarker(scene, trackData.waypoints, trackData.sectors.s1End, halfWidth, trackData.theme.line, 0.6);
  drawLineMarker(scene, trackData.waypoints, trackData.sectors.s2End, halfWidth, trackData.theme.line, 0.6);

  const crossings = buildCrossings(
    trackData.waypoints,
    trackData.sectors,
    trackData.checkpointIndices,
    halfWidth,
  );

  return {
    data: trackData,
    group,
    crossings,
    wallColliders,
    halfWidth,
    startFinishMesh: sf,
  };
}

function drawLineMarker(scene, waypoints, idx, halfWidth, color, thicknessMetres) {
  const w = waypoints[idx];
  const m = leftMiterAt(waypoints, idx);
  const t = tangentAt(waypoints, idx);
  const w0x = w.x + m.x * halfWidth, w0z = w.z + m.z * halfWidth;
  const w1x = w.x - m.x * halfWidth, w1z = w.z - m.z * halfWidth;
  // Extend a small distance along tangent for a visible line strip.
  const half = thicknessMetres * 0.5;
  const ax = w0x - t.x * half, az = w0z - t.z * half;
  const bx = w1x - t.x * half, bz = w1z - t.z * half;
  const cx = w1x + t.x * half, cz = w1z + t.z * half;
  const dx = w0x + t.x * half, dz = w0z + t.z * half;

  const geo = new THREE.BufferGeometry();
  geo.setAttribute("position", new THREE.BufferAttribute(new Float32Array([
    ax, 0.05, az,
    bx, 0.05, bz,
    cx, 0.05, cz,
    dx, 0.05, dz,
  ]), 3));
  geo.setIndex([0, 2, 1, 0, 3, 2]);
  geo.computeVertexNormals();
  const mat = new THREE.MeshStandardMaterial({
    color, flatShading: true, roughness: 0.6,
  });
  const m2 = new THREE.Mesh(geo, mat);
  scene.add(m2);
  return m2;
}
