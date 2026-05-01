// Bootstrap. Async because we have to await Rapier's WASM initialisation
// before anything else can construct rigid bodies.

import { createScene } from "./rendering.js";
import { initPhysics, createWorld, createVehicle, TUNING } from "./physics.js";
import { buildF1Mesh } from "./vehicle.js";
import { startLoop } from "./game.js";
import { setLoadingDetail, hideLoading } from "./ui.js";

async function main() {
  setLoadingDetail("downloading rapier wasm");
  await initPhysics();

  setLoadingDetail("building scene");
  const { scene, camera, renderer } = createScene();

  setLoadingDetail("creating physics world");
  const world = createWorld();

  setLoadingDetail("spawning car");
  const vehicle = createVehicle(world);
  const mesh = buildF1Mesh();
  scene.add(mesh);

  // Expose tuning + game state on window for live iteration via DevTools.
  // e.g.  TUNING.engineForce = 13000  (changes feel within a frame)
  //       __game.vehicle.body.linvel()
  window.TUNING = TUNING;
  window.__game = { scene, camera, renderer, world, vehicle, mesh };

  hideLoading();
  startLoop({ scene, camera, renderer, world, vehicle, mesh });
}

main().catch((err) => {
  console.error("Boot failed:", err);
  setLoadingDetail("boot failed — check console");
});
