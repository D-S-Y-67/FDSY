// Keyboard input → normalized control struct.
//
// We keep this module tiny and deliberate so the physics layer never sees
// raw key state. Future phases (gamepad, touch, replay-driven ghosts) can
// produce the same shape and slot in without changing physics code.

const keys = Object.create(null);

// edge-triggered keys are consumed once per readInput() call; raw held
// state alone isn't enough for actions like "reset" that should fire on
// the press event, not every frame the key is held.
const edge = Object.create(null);

const PREVENT_DEFAULT_CODES = new Set([
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space",
]);

window.addEventListener("keydown", (e) => {
  if (e.repeat) return;
  keys[e.code] = true;
  edge[e.code] = true;
  if (PREVENT_DEFAULT_CODES.has(e.code)) e.preventDefault();
}, { passive: false });

window.addEventListener("keyup", (e) => {
  keys[e.code] = false;
});

// keys lose state when the tab/window loses focus; otherwise the player
// returns and finds their car still pinned at full throttle.
window.addEventListener("blur", () => {
  for (const k in keys) keys[k] = false;
});

function held(...codes) {
  for (const c of codes) if (keys[c]) return true;
  return false;
}

function consumeEdge(...codes) {
  let fired = false;
  for (const c of codes) {
    if (edge[c]) { fired = true; edge[c] = false; }
  }
  return fired;
}

/**
 * @returns {{
 *   throttle: number,  // 0..1
 *   brake:    number,  // 0..1 (also reverses below ~stationary)
 *   steer:    number,  // -1..1, negative = left
 *   reset:    boolean, // edge-triggered: true the frame R is pressed
 * }}
 */
export function readInput() {
  const throttle = held("KeyW", "ArrowUp") ? 1 : 0;
  const brake    = held("KeyS", "ArrowDown") ? 1 : 0;
  const left     = held("KeyA", "ArrowLeft") ? 1 : 0;
  const right    = held("KeyD", "ArrowRight") ? 1 : 0;
  const reset    = consumeEdge("KeyR", "Enter");
  return { throttle, brake, steer: right - left, reset };
}
