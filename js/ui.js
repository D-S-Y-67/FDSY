// Debug HUD writer for Phase 1.
// The full F1-broadcast HUD (lap timer, sectors, deltas, tire icon, ERS bar,
// minimap, etc.) lands in Phase 9 polish. This is just the readouts a
// physics-tuner needs: speed, FPS, slip angle. Gear is a placeholder until
// we wire a gearbox simulation in a later phase.

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
 * @param {number} frameDtSec  - render-frame delta seconds (not the physics dt)
 */
export function updateHud(vehicle, input, frameDtSec) {
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
}
