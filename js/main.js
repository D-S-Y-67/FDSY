// Bootstrap. Async because we have to await Rapier's WASM initialisation
// before anything else can construct rigid bodies.

import { createScene } from "./rendering.js";
import { initPhysics, createWorld, createVehicle, TUNING } from "./physics.js";
import { buildF1Mesh } from "./vehicle.js";
import { startLoop } from "./game.js";
import { setLoadingDetail, hideLoading } from "./ui.js";
import { loadTrack } from "./track.js";
import { MONACO } from "./tracks/monaco.js";
import { createTiming } from "./systems/timing.js";

async function main() {
  setLoadingDetail("downloading rapier wasm");
  await initPhysics();

  const trackData = MONACO;

  setLoadingDetail("building scene");
  const { scene, camera, renderer } = createScene({
    skyColor:    trackData.theme.sky,
    groundColor: trackData.theme.runoff,
  });

  setLoadingDetail("creating physics world");
  const world = createWorld();

  setLoadingDetail(`building ${trackData.name}`);
  const track = loadTrack(world, scene, trackData);

  setLoadingDetail("spawning car");
  const vehicle = createVehicle(world, trackData.spawn);
  const mesh = buildF1Mesh();
  scene.add(mesh);

  // Lap / sector / checkpoint state machine.
  const timing = createTiming(track);

  // Expose tuning + game state on window for live iteration via DevTools.
  // e.g.  TUNING.engineForce = 13000  (changes feel within a frame)
  //       __game.vehicle.body.linvel()
  //       __game.timing.bestLapMs
  window.TUNING = TUNING;
  window.__game = { scene, camera, renderer, world, vehicle, mesh, track, timing };

  hideLoading();
  startLoop({ scene, camera, renderer, world, vehicle, mesh, track, timing });
}

main().catch((err) => {
  console.error("Boot failed:", err);
  setLoadingDetail("boot failed — check console");
});
