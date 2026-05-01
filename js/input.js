// Keyboard input → normalized control struct.
//
// Defensive design: we listen to BOTH `e.code` (physical key, layout-
// independent) and `e.key` (logical character). Either matches a known
// control. This handles:
//   - Dvorak÷Colemak layouts where KeyA/KeyD don't sit under the player's
//     fingers
//   - Browser quirks where `e.code` is occasionally missing
//   - The earlier bug where one direction's key seemed to "not work"
//
// We never early-return on `e.repeat`. The first press is always
// `repeat: false`, but if for any reason we miss it (window loses focus,
// DevTools opens, etc.) we want a subsequent repeat event to still set the
// held-state flag. Edge events (one-shot R for reset) are gated on `!repeat`.

const heldCodes = Object.create(null);   // by e.code  (e.g. "KeyD")
const heldKeys  = Object.create(null);   // by e.key   (e.g. "d")
const edgeCodes = Object.create(null);

const PREVENT_DEFAULT_CODES = new Set([
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space",
]);

window.addEventListener("keydown", (e) => {
  heldCodes[e.code] = true;
  if (e.key) heldKeys[e.key.toLowerCase()] = true;
  if (!e.repeat) edgeCodes[e.code] = true;
  if (PREVENT_DEFAULT_CODES.has(e.code)) e.preventDefault();
}, { passive: false });

window.addEventListener("keyup", (e) => {
  heldCodes[e.code] = false;
  if (e.key) heldKeys[e.key.toLowerCase()] = false;
});

// Wipe state if focus leaves the window — otherwise the player tabs away
// while holding W and finds the car still pinned at full throttle on return.
window.addEventListener("blur", () => {
  for (const k in heldCodes) heldCodes[k] = false;
  for (const k in heldKeys)  heldKeys[k] = false;
});

function held(...names) {
  for (const n of names) {
    if (heldCodes[n]) return true;
    if (heldKeys[n.toLowerCase()]) return true;
  }
  return false;
}

function consumeEdge(...codes) {
  let fired = false;
  for (const c of codes) {
    if (edgeCodes[c]) { fired = true; edgeCodes[c] = false; }
  }
  return fired;
}

/**
 * @returns {{
 *   throttle: number,  // 0..1
 *   brake:    number,  // 0..1 (also reverses below ~stationary)
 *   steer:    number,  // -1..1, negative = left
 *   reset:    boolean, // edge-triggered: true the frame R/Enter is pressed
 * }}
 */
export function readInput() {
  // We pass both physical codes ("KeyA") AND logical keys ("a") to held(),
  // so any mismatch in browser behaviour gets caught either way.
  const throttle = held("KeyW", "ArrowUp",    "w") ? 1 : 0;
  const brake    = held("KeyS", "ArrowDown",  "s") ? 1 : 0;
  const left     = held("KeyA", "ArrowLeft",  "a") ? 1 : 0;
  const right    = held("KeyD", "ArrowRight", "d") ? 1 : 0;
  const reset    = consumeEdge("KeyR", "Enter");
  return { throttle, brake, steer: right - left, reset };
}
