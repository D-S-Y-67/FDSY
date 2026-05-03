// Three.js scene, camera, lights, ground, and resize handling.
// Flat-shaded low-poly aesthetic — no textures, ambient + one directional
// light. Phase 2 makes the ground the off-track infield (green); the track
// itself (tarmac, walls, kerbs) is built by track.js and added on top.

import * as THREE from "three";

const SKY_COLOR    = 0x9bd1ee;  // slightly desaturated sky for low-poly look
const GROUND_COLOR = 0x274d2a;  // grass / harborside infield (Monaco theme)

/**
 * Build the rendering objects shared by the rest of the game.
 * @param {object}  [opts]
 * @param {number}  [opts.skyColor]
 * @param {number}  [opts.groundColor]
 * @returns {{
 *   scene: THREE.Scene,
 *   camera: THREE.PerspectiveCamera,
 *   renderer: THREE.WebGLRenderer,
 * }}
 */
export function createScene(opts = {}) {
  const sky    = opts.skyColor    ?? SKY_COLOR;
  const ground = opts.groundColor ?? GROUND_COLOR;
  const canvas = document.getElementById("game-canvas");

  const renderer = new THREE.WebGLRenderer({
    canvas,
    antialias: true,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setSize(window.innerWidth, window.innerHeight, false);
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.outputColorSpace = THREE.SRGBColorSpace;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(sky);
  // Distance fog hides the far edge of the ground plane — cheap atmosphere.
  scene.fog = new THREE.Fog(sky, 600, 1800);

  const camera = new THREE.PerspectiveCamera(
    70,
    window.innerWidth / window.innerHeight,
    0.5,
    3000,
  );
  camera.position.set(0, 5, 12);
  camera.lookAt(0, 1, 0);

  // --- Lighting ---
  const ambient = new THREE.AmbientLight(0xffffff, 0.45);
  scene.add(ambient);

  // Wide directional light covering the whole circuit. The shadow camera
  // frustum is big — track wraps roughly 350m in each axis — so we pick a
  // generous orthographic box here. Shadow map resolution scaled up to keep
  // shadows from looking blocky over that wider area.
  const sun = new THREE.DirectionalLight(0xfff4e0, 0.95);
  sun.position.set(180, 350, 120);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  sun.shadow.camera.near = 1;
  sun.shadow.camera.far  = 900;
  sun.shadow.camera.left = -300;
  sun.shadow.camera.right = 300;
  sun.shadow.camera.top = 300;
  sun.shadow.camera.bottom = -300;
  sun.shadow.bias = -0.0005;
  scene.add(sun);

  // --- Infield (off-track surface) ---
  // The track is added on top of this by track.js, raised a few cm above
  // to avoid z-fighting. Plane is large enough to extend well past the
  // track in any direction so the player never sees an edge.
  const groundGeo = new THREE.PlaneGeometry(3000, 3000, 1, 1);
  const groundMat = new THREE.MeshStandardMaterial({
    color: ground,
    flatShading: true,
    roughness: 0.95,
    metalness: 0,
  });
  const groundMesh = new THREE.Mesh(groundGeo, groundMat);
  groundMesh.rotation.x = -Math.PI / 2;
  groundMesh.receiveShadow = true;
  scene.add(groundMesh);

  // --- Resize ---
  window.addEventListener("resize", () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight, false);
  });

  return { scene, camera, renderer };
}
