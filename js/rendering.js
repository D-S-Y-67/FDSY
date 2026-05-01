// Three.js scene, camera, lights, ground, and resize handling.
// Flat-shaded low-poly aesthetic — no textures, ambient + one directional
// light, soft sky-blue background. Phase 1 ground is a large flat plane
// with a faint grid for speed reference.

import * as THREE from "three";

const SKY_COLOR    = 0x9bd1ee;  // slightly desaturated sky for low-poly look
const GROUND_COLOR = 0x4a5560;  // slate grey tarmac
const GRID_COLOR   = 0x70808a;  // faint grid lines visible against tarmac

/**
 * Build the rendering objects shared by the rest of the game.
 * @returns {{
 *   scene: THREE.Scene,
 *   camera: THREE.PerspectiveCamera,
 *   renderer: THREE.WebGLRenderer,
 * }}
 */
export function createScene() {
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
  scene.background = new THREE.Color(SKY_COLOR);
  // Subtle distance fog blends the ground plane into the sky and hides the
  // far edge — cheap atmosphere for the low-poly look.
  scene.fog = new THREE.Fog(SKY_COLOR, 350, 1200);

  const camera = new THREE.PerspectiveCamera(
    70,
    window.innerWidth / window.innerHeight,
    0.5,
    2000,
  );
  camera.position.set(0, 5, 12);
  camera.lookAt(0, 1, 0);

  // --- Lighting ---
  // Ambient lifts the shadow side of the car off pure black.
  const ambient = new THREE.AmbientLight(0xffffff, 0.45);
  scene.add(ambient);

  // Single directional light is enough for flat shading; sized to cover the
  // car and a small area around it (we'll grow this when tracks arrive).
  const sun = new THREE.DirectionalLight(0xfff4e0, 0.95);
  sun.position.set(60, 120, 40);
  sun.castShadow = true;
  sun.shadow.mapSize.set(1024, 1024);
  sun.shadow.camera.near = 1;
  sun.shadow.camera.far = 300;
  sun.shadow.camera.left = -50;
  sun.shadow.camera.right = 50;
  sun.shadow.camera.top = 50;
  sun.shadow.camera.bottom = -50;
  sun.shadow.bias = -0.0005;
  scene.add(sun);

  // --- Ground plane ---
  const groundGeo = new THREE.PlaneGeometry(2000, 2000, 1, 1);
  const groundMat = new THREE.MeshStandardMaterial({
    color: GROUND_COLOR,
    flatShading: true,
    roughness: 0.95,
    metalness: 0,
  });
  const ground = new THREE.Mesh(groundGeo, groundMat);
  ground.rotation.x = -Math.PI / 2;
  ground.receiveShadow = true;
  scene.add(ground);

  // GridHelper gives a sense of speed — its lines are screen-pixel thin so
  // they don't fight the low-poly aesthetic.
  const grid = new THREE.GridHelper(2000, 200, GRID_COLOR, GRID_COLOR);
  grid.material.opacity = 0.25;
  grid.material.transparent = true;
  grid.position.y = 0.01;  // lift slightly to avoid z-fighting with the plane
  scene.add(grid);

  // Scattered low-poly cones as visual reference points so the player can
  // tell they're actually moving on an otherwise empty plane. Will go away
  // when real tracks arrive in Phase 2.
  scene.add(buildScatteredMarkers());

  // --- Resize ---
  window.addEventListener("resize", () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight, false);
  });

  return { scene, camera, renderer };
}

function buildScatteredMarkers() {
  const group = new THREE.Group();
  const coneGeo = new THREE.ConeGeometry(0.6, 1.6, 6);
  const coneMat = new THREE.MeshStandardMaterial({
    color: 0xff5a1f,
    flatShading: true,
  });
  // Deterministic pseudo-scatter so the layout is the same every load.
  let seed = 1;
  const rand = () => {
    seed = (seed * 9301 + 49297) % 233280;
    return seed / 233280;
  };
  for (let i = 0; i < 80; i++) {
    const cone = new THREE.Mesh(coneGeo, coneMat);
    const r = 30 + rand() * 350;
    const a = rand() * Math.PI * 2;
    cone.position.set(Math.cos(a) * r, 0.8, Math.sin(a) * r);
    cone.castShadow = true;
    group.add(cone);
  }
  return group;
}
