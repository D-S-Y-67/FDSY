// Monaco — Circuit de Monaco.
//
// First official track for PolePosition. We build the centerline polyline
// procedurally from a list of "moves" (straight + turn primitives) so the
// data stays human-readable and easy to tweak. Phase 2 captures the LAYOUT
// CHARACTER of Monaco — narrow, technical, the iconic Grand Hotel hairpin,
// the long tunnel-like straight, the Swimming Pool S-bends, Rascasse — but
// NOT metre-accurate geometry. Elevation comes in Phase 6 polish.
//
// All distances in metres; all angles in degrees (positive = right turn,
// negative = left turn). Heading 0° = facing -Z (the car's spawn forward).

// Monaco-flavoured layout. Two hairpins (Grand Hotel + Rascasse) plus
// balanced lefts and rights so the angles sum to exactly 360°. Position
// closure is approximate — the auto-closing straight at the end fills any
// residual gap. Phase 6 polish will iterate this layout for accuracy.
const MOVES = [
  { type: "straight", length: 130, name: "Boulevard Albert (S/F)" },
  { type: "turn",     angle:  70, radius: 20, name: "Sainte Devote" },
  { type: "straight", length:  80, name: "Beau Rivage climb" },
  { type: "turn",     angle: -70, radius: 35, name: "Massenet" },
  { type: "straight", length:  25, name: "Casino approach" },
  { type: "turn",     angle:  70, radius: 20, name: "Casino" },
  { type: "straight", length:  40, name: "Mirabeau" },
  { type: "turn",     angle: 180, radius: 12, name: "Grand Hotel hairpin" },
  { type: "straight", length:  60, name: "Portier" },
  { type: "turn",     angle: -70, radius: 20, name: "post-Portier" },
  { type: "straight", length: 200, name: "Tunnel straight" },
  { type: "turn",     angle:  90, radius:  9, name: "Nouvelle Chicane R" },
  { type: "turn",     angle: -90, radius:  9, name: "Nouvelle Chicane L" },
  { type: "straight", length:  60 },
  { type: "turn",     angle: -90, radius: 22, name: "Tabac" },
  { type: "straight", length:  30, name: "Swimming Pool" },
  { type: "turn",     angle:  90, radius: 22, name: "post-Tabac" },
  { type: "straight", length:  40 },
  { type: "turn",     angle: 180, radius: 10, name: "Rascasse" },
  { type: "straight", length:  60, name: "Anthony Noghes" },
  // Final straight is auto-sized to close the loop back to (0,0).
];

const SEGMENT_SPACING = 6; // metres between waypoints along straights/arcs

/**
 * Walk the moves list and emit centerline waypoints.
 * Each waypoint also carries `name`, `corner`, and `arcCurvature` for later
 * use (kerb placement, sector naming, lap-time-vs-corner debugging).
 */
function buildWaypoints(moves, spacing = SEGMENT_SPACING) {
  /** @type {{x:number, z:number, name?:string, curvature?:number}[]} */
  const points = [{ x: 0, z: 0, name: "start/finish" }];
  let x = 0, z = 0;
  // yaw=0 → forward direction = (sin yaw, 0, -cos yaw) = (0,0,-1).
  // Positive yaw rotates direction clockwise viewed from above (right turn).
  let yaw = 0;

  for (const move of moves) {
    if (move.type === "straight") {
      const steps = Math.max(1, Math.round(move.length / spacing));
      const stepLen = move.length / steps;
      for (let i = 0; i < steps; i++) {
        x +=  Math.sin(yaw) * stepLen;
        z += -Math.cos(yaw) * stepLen;
        points.push({
          x, z,
          name: i === steps - 1 ? move.name : undefined,
          curvature: 0,
        });
      }
    } else if (move.type === "turn") {
      const angleRad = (move.angle * Math.PI) / 180;
      const radius   = move.radius;
      const arcLen   = Math.abs(angleRad) * radius;
      const steps    = Math.max(2, Math.round(arcLen / spacing));
      const dYaw     = angleRad / steps;
      const stepLen  = arcLen / steps;
      // Curvature = 1/r, signed: positive for right turns. Used by the
      // mesh generator to decide which side of the track gets a kerb.
      const curvature = Math.sign(angleRad) / radius;
      for (let i = 0; i < steps; i++) {
        // Move first by half-step to centre each waypoint inside its arc
        // segment — slightly cleaner triangle-strip than turning fully
        // before stepping.
        yaw += dYaw / 2;
        x +=  Math.sin(yaw) * stepLen;
        z += -Math.cos(yaw) * stepLen;
        yaw += dYaw / 2;
        points.push({
          x, z,
          name: i === steps - 1 ? move.name : undefined,
          curvature,
        });
      }
    }
  }

  // Close the loop: the procedural moves above don't perfectly return to
  // (0,0) — Monaco has irrational geometry and we're approximating. Add an
  // auto-sized final straight that interpolates from the last waypoint
  // back to the origin in `spacing`-metre increments. The last waypoint
  // generated here is dropped because it'd sit on top of waypoint 0.
  const last = points[points.length - 1];
  const dx = -last.x, dz = -last.z;
  const dist = Math.hypot(dx, dz);
  if (dist > spacing) {
    const steps = Math.max(2, Math.round(dist / spacing));
    for (let i = 1; i < steps; i++) {
      const t = i / steps;
      points.push({
        x: last.x + dx * t,
        z: last.z + dz * t,
        curvature: 0,
      });
    }
  }
  return points;
}

const waypoints = buildWaypoints(MOVES);

// Anti-cheat checkpoint indices — sparse (every ~10th waypoint), evenly
// distributed along the lap. The car must cross each one before crossing
// start/finish, otherwise the lap is invalidated.
function chooseCheckpointIndices(n, total) {
  const result = [];
  for (let i = 1; i <= n; i++) {
    result.push(Math.round((total * i) / (n + 1)));
  }
  return result;
}

const N = waypoints.length;

export const MONACO = {
  id: "monaco",
  name: "Circuit de Monaco",
  country: "MC",

  // --- physical dimensions ---
  trackWidth: 12,            // metres edge-to-edge
  wallHeight: 1.4,
  wallThickness: 0.4,

  // --- spawn pose ---
  // The first waypoint sits at the start/finish line; spawn the car a few
  // metres BEHIND it on the racing line so the first crossing of the line
  // starts the timer cleanly. Yaw=0 → forward direction matches the
  // procedural generator's initial heading (-Z).
  spawn: { x: 0, y: 0.55, z: 18, yaw: 0 },

  // --- track polyline ---
  waypoints,

  // --- sectors ---
  // Sector 1 ends after Mirabeau (~30% through lap), Sector 2 ends after
  // Tabac (~65%). Phase 2 doesn't try to be canonical Monaco splits — we
  // just need three roughly-equal sectors.
  sectors: {
    s1End: Math.round(N * 0.30),
    s2End: Math.round(N * 0.65),
  },

  // --- anti-cheat checkpoints (8 around the lap) ---
  checkpointIndices: chooseCheckpointIndices(8, N),

  // --- visual theme ---
  theme: {
    tarmac:    0x3a3f47,   // slate
    runoff:    0x274d2a,   // grass / harborside
    wall:      0xeeeeee,   // Monaco's white Armco
    kerbA:     0xd62828,
    kerbB:     0xf5f5f5,
    sky:       0x88a9c9,   // dusk-ish Mediterranean blue
    line:      0xffffff,   // start/finish + sector lines
  },
};
