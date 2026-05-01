// Debug HUD writer for Phase 1.
// The full F1-broadcast HUD (lap timer, sectors, deltas, tire icon, ERS bar,
// minimap, etc.) lands in Phase 9 polish. This is just the readouts a
// physics-tuner needs: speed, FPS, slip angle. Gear is a placeholder until
// we wire a gearbox simulation in a later phase.

const el = (id) => document.getElementById(id);
const $speed = el("speed");
const $fps   = el("fps");
const $slip  = el("slip");
const $loading = el("loading");
const $loadingDetail = el("loading-detail");

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
 * @param {{ speedKmh: number, slipAngleDeg: number }} vehicle
 * @param {number} frameDtSec  - render-frame delta seconds (not the physics dt)
 */
export function updateHud(vehicle, frameDtSec) {
  $speed.textContent = Math.max(0, Math.round(vehicle.speedKmh)).toString();

  // rolling-window FPS average
  const fps = frameDtSec > 0 ? 1 / frameDtSec : 0;
  if (fpsSamples.length < FPS_SAMPLE_WINDOW) fpsSamples.push(fps);
  else fpsSamples[fpsCursor] = fps;
  fpsCursor = (fpsCursor + 1) % FPS_SAMPLE_WINDOW;
  let sum = 0;
  for (const f of fpsSamples) sum += f;
  $fps.textContent = Math.round(sum / fpsSamples.length).toString();

  $slip.textContent = `${Math.round(vehicle.slipAngleDeg)}°`;
}
