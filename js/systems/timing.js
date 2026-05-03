// Lap and sector timing — the state machine and persistent bests.
//
// Heavily commented per the original brief: this is one of the parts that
// gets the most user iteration (HUD readouts, what's "your fastest sector"
// vs "your fastest lap's sector", anti-cheat, ghost sync). Get the data
// model right and the rest falls into place.
//
// Phase 2 keeps everything in-memory only. Phase 3 will swap the
// `bestLapMs`/`bestSectors` reads-and-writes through an abstraction in
// storage.js so values survive across reloads.
//
// State machine
// -------------
//   PRE_LAP  — initial state. The car has spawned but hasn't crossed
//              start/finish in the forward direction yet. Lap timer
//              shows 0:00.000.
//   LAPPING  — timer is running. Crossing the s1End line ends sector 1
//              and starts sector 2. Crossing s2End ends sector 2.
//              Crossing start/finish (with all anti-cheat checkpoints
//              visited in this lap) ends sector 3 and finishes the lap.
//   POST_LAP — same as LAPPING for our purposes (next lap starts
//              immediately on the line). Reserved as a hook for race-end
//              chequered-flag logic in Phase 8.
//
// Anti-cheat: an array of waypoint indices the car must cross (in any
// order) before the start/finish line counts as completing a lap. This
// stops cutting across the infield to "shortcut" a lap. If the player
// crosses start/finish without all checkpoints, we INVALIDATE the lap —
// the lap timer keeps running but no best-lap update is allowed.
//
// Direction of crossing: each crossing has a tangent direction. We only
// count a crossing as "forward" if the car's velocity (or movement vector)
// has a positive dot product with the tangent. This rules out the player
// reversing through start/finish to fake laps.

const PURPLE = -1;     // personal best (overall) for this sector
const GREEN  =  0;     // faster than your previous lap's sector
const RED    = +1;     // slower than your previous lap's sector
const NONE   = null;   // no comparison available yet (first lap)

export function createTiming(track) {
  return {
    track,

    // --- state machine ---
    state: "PRE_LAP",          // PRE_LAP | LAPPING | POST_LAP
    invalidLap: false,         // if true, the lap won't count as a best

    // --- timestamps in ms (performance.now) ---
    lapStartMs: 0,
    sectorStartMs: 0,
    nowMs: 0,                  // updated every step from updateTiming(now)

    // --- current lap progress ---
    currentSector: 0,          // 0 (pre-lap) | 1 | 2 | 3
    visitedCheckpoints: new Set(),
    lapCount: 0,

    // --- live readouts (HUD reads these) ---
    currentLapMs: 0,           // wall-clock since lapStart
    currentSectorMs: 0,        // wall-clock since sectorStart
    sectorTimes: { s1: 0, s2: 0, s3: 0 },  // running this lap; locked when sector ends

    // --- bests + last-lap ---
    lastLapMs: 0,
    bestLapMs: Infinity,
    lastSectors: { s1: 0, s2: 0, s3: 0 },
    bestSectors: { s1: Infinity, s2: Infinity, s3: Infinity },

    // --- delta colours (for HUD chips after each sector locks in) ---
    deltaColours: { s1: NONE, s2: NONE, s3: NONE },

    // --- diagnostics for the UI ---
    lastEvent: null,           // string describing the most recent event
  };
}

export function resetTiming(timing) {
  timing.state = "PRE_LAP";
  timing.invalidLap = false;
  timing.currentSector = 0;
  timing.visitedCheckpoints.clear();
  timing.lapStartMs = 0;
  timing.sectorStartMs = 0;
  timing.currentLapMs = 0;
  timing.currentSectorMs = 0;
  timing.sectorTimes = { s1: 0, s2: 0, s3: 0 };
  timing.deltaColours = { s1: NONE, s2: NONE, s3: NONE };
  timing.lastEvent = null;
  // bests + lapCount + lastLapMs persist across resets — losing those on R
  // would punish the iteration loop.
}

/**
 * Run the timing state machine for one frame.
 *
 * @param {ReturnType<typeof createTiming>} t
 * @param {{kind:string, index:number, dot:number}[]} events  - from track.detectCrossings
 * @param {number} nowMs                                       - performance.now()
 */
export function updateTiming(t, events, nowMs) {
  t.nowMs = nowMs;

  // Update live wall-clock readouts every frame regardless of events.
  if (t.state !== "PRE_LAP") {
    t.currentLapMs    = nowMs - t.lapStartMs;
    t.currentSectorMs = nowMs - t.sectorStartMs;
  }

  for (const ev of events) {
    // Only forward crossings count.
    if (ev.dot <= 0) continue;

    if (ev.kind === "checkpoint") {
      t.visitedCheckpoints.add(ev.index);
      continue;
    }

    if (ev.kind === "startFinish") {
      handleStartFinish(t, nowMs);
      continue;
    }

    if (ev.kind === "sectorEnd1") {
      handleSectorEnd(t, 1, nowMs);
      continue;
    }
    if (ev.kind === "sectorEnd2") {
      handleSectorEnd(t, 2, nowMs);
      continue;
    }
  }
}

function handleStartFinish(t, nowMs) {
  if (t.state === "PRE_LAP") {
    // First crossing — start the timer.
    t.state          = "LAPPING";
    t.lapStartMs     = nowMs;
    t.sectorStartMs  = nowMs;
    t.currentSector  = 1;
    t.invalidLap     = false;
    t.visitedCheckpoints.clear();
    t.lastEvent      = "Lap started";
    return;
  }

  // Lap finishing. We need:
  //   - to be currently in sector 3 (i.e. we crossed s1End and s2End)
  //   - all anti-cheat checkpoints visited
  const cpsRequired = t.track.data.checkpointIndices.length;
  const cpsVisited  = t.visitedCheckpoints.size;
  const sectorsOk   = t.currentSector === 3;

  if (!sectorsOk || cpsVisited < cpsRequired) {
    // Lap is invalid. Restart timing as if first crossing.
    t.invalidLap = true;
    t.lapStartMs    = nowMs;
    t.sectorStartMs = nowMs;
    t.currentSector = 1;
    t.visitedCheckpoints.clear();
    t.deltaColours = { s1: NONE, s2: NONE, s3: NONE };
    t.lastEvent = `Lap invalidated (sectors:${sectorsOk ? "ok" : "skip"} cps:${cpsVisited}/${cpsRequired})`;
    return;
  }

  // Finish sector 3, finish lap.
  const s3Ms = nowMs - t.sectorStartMs;
  t.sectorTimes.s3 = s3Ms;
  t.deltaColours.s3 = compareSector(s3Ms, t.lastSectors.s3, t.bestSectors.s3);

  const lapMs = nowMs - t.lapStartMs;
  t.lastLapMs = lapMs;
  t.lastSectors = { ...t.sectorTimes };

  if (lapMs < t.bestLapMs && !t.invalidLap) {
    t.bestLapMs = lapMs;
  }
  if (s3Ms < t.bestSectors.s3 && !t.invalidLap) {
    t.bestSectors.s3 = s3Ms;
  }

  t.lapCount += 1;
  t.lastEvent = `Lap ${t.lapCount}: ${formatLapTime(lapMs)}${t.invalidLap ? " (INVALID)" : ""}`;

  // Roll into the next lap immediately.
  t.lapStartMs    = nowMs;
  t.sectorStartMs = nowMs;
  t.currentSector = 1;
  t.invalidLap    = false;
  t.visitedCheckpoints.clear();
  // Clear next lap's running sector-by-sector array; bests stay.
  t.sectorTimes = { s1: 0, s2: 0, s3: 0 };
  t.deltaColours = { s1: NONE, s2: NONE, s3: NONE };
}

function handleSectorEnd(t, n, nowMs) {
  if (t.state !== "LAPPING") return;
  if (t.currentSector !== n)  return;   // ignore out-of-order crossings

  const ms = nowMs - t.sectorStartMs;
  const key = `s${n}`;

  t.sectorTimes[key] = ms;
  t.deltaColours[key] = compareSector(ms, t.lastSectors[key], t.bestSectors[key]);

  if (ms < t.bestSectors[key] && !t.invalidLap) {
    t.bestSectors[key] = ms;
  }

  t.sectorStartMs = nowMs;
  t.currentSector = n + 1;
  t.lastEvent = `S${n} ${formatLapTime(ms)}`;
}

/**
 * Returns -1 (PB / purple), 0 (improving / green), +1 (slower / red), or
 * null (no prior comparison).
 */
function compareSector(currMs, lastMs, bestMs) {
  if (currMs < bestMs) return PURPLE;
  if (lastMs > 0 && currMs < lastMs) return GREEN;
  if (lastMs > 0 && currMs >= lastMs) return RED;
  return NONE;
}

// ---------------------------------------------------------------------------
// Formatters (used by ui.js — kept here so the format is one source of truth).
// ---------------------------------------------------------------------------

export function formatLapTime(ms) {
  if (!isFinite(ms) || ms <= 0) return "—:—.—";
  const total = Math.floor(ms);
  const min = Math.floor(total / 60000);
  const sec = Math.floor((total % 60000) / 1000);
  const milli = total % 1000;
  return `${min}:${sec.toString().padStart(2, "0")}.${milli.toString().padStart(3, "0")}`;
}

export function formatSectorTime(ms) {
  if (!isFinite(ms) || ms <= 0) return "—.—";
  const total = Math.floor(ms);
  const sec = Math.floor(total / 1000);
  const milli = total % 1000;
  return `${sec.toString().padStart(2, "0")}.${milli.toString().padStart(3, "0")}`;
}

export function formatDelta(deltaMs) {
  if (!isFinite(deltaMs)) return "";
  const sign = deltaMs >= 0 ? "+" : "−";
  const abs = Math.abs(deltaMs);
  if (abs >= 1000) return `${sign}${(abs / 1000).toFixed(2)}`;
  return `${sign}0.${Math.floor(abs).toString().padStart(3, "0")}`;
}

export const DELTA_PURPLE = PURPLE;
export const DELTA_GREEN  = GREEN;
export const DELTA_RED    = RED;
