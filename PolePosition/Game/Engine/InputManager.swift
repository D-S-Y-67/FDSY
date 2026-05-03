import Foundation

#if os(macOS)
import AppKit
#endif

/// Holds the current input state. The view layer pushes raw key events in;
/// the game loop polls the resolved analog axes (steering / throttle / brake)
/// each frame and forwards them to `VehiclePhysics`.
///
/// Thread-safety note: keyDown/keyUp arrive on the main thread (NSResponder),
/// but `SCNSceneRendererDelegate.renderer(_:updateAtTime:)` runs on a render
/// thread. We guard internal state with a single `NSLock`. The lock is held
/// only briefly — never around any other code — so contention is negligible.
///
/// Phase 1 only wires up macOS keyboard. Touch and GameController are added
/// in later phases — they'll just push into the same axis struct.
final class InputManager {
    /// Resolved analog inputs in [-1, 1] / [0, 1].
    struct Axes: Equatable {
        var steer: Double = 0      // -1 (full left) ... +1 (full right)
        var throttle: Double = 0   // 0 ... 1
        var brake: Double = 0      // 0 ... 1
    }

    enum Key: Hashable {
        case left, right, accel, brake, handbrake, restart
    }

    private let lock = NSLock()
    private var _axes = Axes()
    private var _restartRequested = false
    private var pressed: Set<Key> = []

    /// Snapshot of resolved axes. Cheap copy.
    var axes: Axes {
        lock.lock(); defer { lock.unlock() }
        return _axes
    }

    /// Edge-triggered "restart" flag. The game loop reads + clears this each
    /// frame so a single tap of R/Return triggers exactly one respawn.
    func consumeRestart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let r = _restartRequested
        _restartRequested = false
        return r
    }

    /// Map a macOS virtual key code to one of our logical keys.
    /// Codes from common knowledge / Carbon's `Events.h`.
    static func keyForMacKeyCode(_ code: UInt16) -> Key? {
        switch code {
        case 0:   return .left      // A
        case 2:   return .right     // D
        case 13:  return .accel     // W
        case 1:   return .brake     // S
        case 123: return .left      // ←
        case 124: return .right     // →
        case 126: return .accel     // ↑
        case 125: return .brake     // ↓
        case 49:  return .handbrake // Space
        case 15:  return .restart   // R
        case 36:  return .restart   // Return
        default:  return nil
        }
    }

    func keyDown(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        if key == .restart {
            // Edge-triggered: don't latch. Just flag once.
            _restartRequested = true
            return
        }
        pressed.insert(key)
        recomputeLocked()
    }

    func keyUp(_ key: Key) {
        lock.lock(); defer { lock.unlock() }
        pressed.remove(key)
        recomputeLocked()
    }

    /// Drop everything (e.g. on window blur) so the car doesn't keep driving.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        pressed.removeAll()
        recomputeLocked()
    }

    // MARK: - Resolution (caller must hold the lock)

    private func recomputeLocked() {
        var steer: Double = 0
        if pressed.contains(.left)  { steer -= 1 }
        if pressed.contains(.right) { steer += 1 }

        let throttle: Double = pressed.contains(.accel) ? 1 : 0
        // Hold S/↓ for brake; Space is a stronger handbrake (locks rears).
        // Phase 1 treats them the same — in Phase 7 the handbrake will get
        // its own behavior (no engine cut, max rear brake torque).
        let brakeKey   = pressed.contains(.brake)     ? 1.0 : 0.0
        let handbrake  = pressed.contains(.handbrake) ? 1.0 : 0.0
        let brake = max(brakeKey, handbrake)

        _axes = Axes(steer: steer, throttle: throttle, brake: brake)
    }
}
