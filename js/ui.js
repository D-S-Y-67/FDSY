// HUD writer.
// Top-left block: speed/gear/inputs (driver-tuner readouts).
// Top-right block: lap timer, sector chips, last+best lap, race events.
// Full F1-broadcast styling (tire icon, ERS bar, minimap, etc.) lands in
// Phase 9 polish.

import { formatLapTime, formatSectorTime, DELTA_PURPLE, DELTA_GREEN, DELTA_RED } from "./systems/timing.js";

const el = (id) => document.getElementById(id);
const $speed     = el("speed");
const $speedUnit = el("speed-unit");
const $gear      = el("gear");
const $fps       = el("fps");
const $slip      = el("slip");
const $keyW      = el("key-w");
const $keyA      = el("key-a");
const $keyS      = el("key-s");
const $keyD      = el("key-d");
const $steerVal  = el("steer-val");
const $loading   = el("loading");
const $loadingDetail = el("loading-detail");

const $lapTimer  = el("lap-timer");
const $lastLap   = el("last-lap");
const $bestLap   = el("best-lap");
const $lapCount  = el("lap-count");
const $sectors   = [el("sector-1"), el("sector-2"), el("sector-3")];
const $raceEvent = el("race-event");

// Cached state to avoid touching the DOM every frame for unchanged values.
let lastEventStr = "";
let lastInvalid  = false;

// Threshold (m/s) below which the car is considered "in neutral" for the
// gear chip readout. Same scale as physics.js#TUNING.brakeReverseThreshold.
const NEUTRAL_BAND = 0.3;

// Rolling FPS averaging — 1/dt jitters too violently to read.
const FPS_SAMPLE_WINDOW = 30;
const fpsSamples = [];
let fpsCursor = 0;

export function setLoadingDetail(text) {
  if ($loadingDetail) $loadingDetail.textContent = text;
}

export function hideLoading() {
  if (!$loading) return;
  $loading.classList.add("hidden");
  // remove from layout once the fade-out has finished
  setTimeout(() => $loading.remove(), 500);
}

/**
 * Update the HUD.
 * @param {{ speedKmh:number, forwardSpeedSigned:number,
 *          slipAngleDeg:number, smoothedSteer:number }} vehicle
 * @param {{ throttle:number, brake:number, steer:number }} input
 * @param {object} timing       - createTiming() state object
 * @param {number} frameDtSec   - render-frame delta seconds (not the physics dt)
 */
export function updateHud(vehicle, input, timing, frameDtSec) {
  $speed.textContent = Math.max(0, Math.round(vehicle.speedKmh)).toString();

  // Direction-aware unit + gear readout. Reading vehicle.forwardSpeedSigned
  // (m/s along chassis nose, signed) lets the HUD distinguish a stationary
  // car from one slowly reversing — without this the speedometer reads "0"
  // either way and the player thinks reverse is broken.
  const fs = vehicle.forwardSpeedSigned;
  if (fs < -NEUTRAL_BAND) {
    $speedUnit.textContent = "km/h ◀ REV";
    $speedUnit.classList.add("reverse");
    $gear.textContent = "R";
  } else if (fs > NEUTRAL_BAND) {
    $speedUnit.textContent = "km/h";
    $speedUnit.classList.remove("reverse");
    $gear.textContent = "D";
  } else {
    $speedUnit.textContent = "km/h";
    $speedUnit.classList.remove("reverse");
    $gear.textContent = "N";
  }

  // rolling-window FPS average
  const fps = frameDtSec > 0 ? 1 / frameDtSec : 0;
  if (fpsSamples.length < FPS_SAMPLE_WINDOW) fpsSamples.push(fps);
  else fpsSamples[fpsCursor] = fps;
  fpsCursor = (fpsCursor + 1) % FPS_SAMPLE_WINDOW;
  let sum = 0;
  for (const f of fpsSamples) sum += f;
  $fps.textContent = Math.round(sum / fpsSamples.length).toString();

  $slip.textContent = `${Math.round(vehicle.slipAngleDeg)}°`;

  // Input debug — lights up the key chip when its control is active.
  $keyW.classList.toggle("active", input.throttle > 0);
  $keyS.classList.toggle("active", input.brake    > 0);
  $keyA.classList.toggle("active", input.steer    < 0);
  $keyD.classList.toggle("active", input.steer    > 0);
  $steerVal.textContent = vehicle.smoothedSteer.toFixed(2);

  if (timing) updateTimingHud(timing);
}

// ---------------------------------------------------------------------------
// Timing block — top-right HUD.
// ---------------------------------------------------------------------------

function updateTimingHud(t) {
  // Lap timer: live current lap if running, else 0:00.000.
  $lapTimer.textContent = t.state === "PRE_LAP"
    ? formatLapTime(0)
    : formatLapTime(t.currentLapMs);

  // Sector chips. The active sector shows the current running time;
  // completed sectors show their locked-in time + colour code.
  for (let i = 0; i < 3; i++) {
    const sec = $sectors[i];
    const key = `s${i + 1}`;
    const idx1 = i + 1;
    const time = t.sectorTimes[key];
    const colour = t.deltaColours[key];

    sec.classList.remove("active", "purple", "green", "red");

    if (t.state !== "PRE_LAP" && t.currentSector === idx1) {
      // Currently running this sector — show wall-clock time.
      sec.classList.add("active");
      sec.querySelector(".time").textContent = formatSectorTime(t.currentSectorMs);
    } else if (time > 0) {
      // Completed earlier this lap — show locked time + delta colour.
      if      (colour === DELTA_PURPLE) sec.classList.add("purple");
      else if (colour === DELTA_GREEN)  sec.classList.add("green");
      else if (colour === DELTA_RED)    sec.classList.add("red");
      sec.querySelector(".time").textContent = formatSectorTime(time);
    } else {
      sec.querySelector(".time").textContent = "—";
    }
  }

  $lastLap.textContent  = formatLapTime(t.lastLapMs);
  $bestLap.textContent  = formatLapTime(t.bestLapMs);
  $lapCount.textContent = t.lapCount.toString();

  // Race event banner (changes infrequently; only touch DOM on change).
  const evStr = t.lastEvent || "";
  if (evStr !== lastEventStr || t.invalidLap !== lastInvalid) {
    $raceEvent.textContent = evStr || " ";  // nbsp keeps line height
    $raceEvent.classList.toggle("invalid", evStr.includes("invalidated"));
    lastEventStr = evStr;
    lastInvalid  = t.invalidLap;
  }
}
