import Foundation
import simd

/// Three-sector lap timing state machine.
///
/// Driven from the game loop. Every frame it gets the car's current
/// world position and the list of trigger AABBs (start/finish + sector
/// boundaries). When the car enters a trigger volume, the state machine
/// records the time and moves on.
///
/// Sequence we expect for a normal lap:
///     startFinish  →  sector2  →  sector3  →  startFinish  →  …
///
/// Anything else (wrong-way drive, skipping a checkpoint) is **ignored**
/// for Phase 2. Track-limit / cut detection is a Phase 3+ concern.
///
/// Times are taken from SceneKit's render-loop `TimeInterval`, not wall
/// clock — keeps everything synchronous with the simulation.
final class Timing {
    private(set) var snapshot = LapTiming()

    /// Tracks which trigger we just exited so we don't fire continuously
    /// while the car sits on top of one. We only register an event on
    /// the leading edge (outside → inside).
    private var inside: Set<Track.Marker.Kind> = []

    /// What checkpoint kind we expect next. Drives the state machine.
    private var expecting: Track.Marker.Kind = .startFinish

    /// Time of the most recent start-finish crossing (i.e. start of the
    /// current lap). `nil` until the very first start-finish hit.
    private var lapStartTime: TimeInterval? = nil

    /// Time of the most recent sector-boundary crossing. Used to derive
    /// the per-sector split times.
    private var sectorStartTime: TimeInterval? = nil

    /// Per-sector best times kept across the session (in addition to the
    /// best lap as a whole).
    private var bestSectorTimes: [TimeInterval?] = [nil, nil, nil]

    /// Tunable: ignore lap times shorter than this many seconds. Stops
    /// micro-laps if the spawn point ends up next to a trigger.
    static let minimumLapTime: TimeInterval = 8.0

    /// Tunable: how many ms of improvement counts as "purple" for sector
    /// PB flashing. Below this, just colour green.
    static let purpleThresholdMs: Double = 1.0

    /// Reset everything (called on `R`/respawn).
    func reset(at time: TimeInterval) {
        snapshot = LapTiming()
        inside.removeAll()
        expecting = .startFinish
        lapStartTime = nil
        sectorStartTime = nil
        // Note: bestLap and bestSectorTimes are intentionally NOT reset —
        // a respawn doesn't wipe your session bests.
        snapshot.bestLap = bestLapBuffer
        snapshot.sectorPBs = bestSectorTimes
    }

    /// Per-frame update.
    /// - Parameters:
    ///   - carPosition: chassis world position
    ///   - time: render-loop monotonic time
    ///   - triggers: world AABBs for each marker, in lap order. Order
    ///     doesn't actually matter — we read each one's `kind`.
    func update(carPosition: simd_float3,
                time: TimeInterval,
                triggers: [Checkpoint]) {
        // Update the running lap clock display.
        if let start = lapStartTime {
            snapshot.currentLap = max(0, time - start)
        }

        // Edge-detect entries into trigger volumes.
        var nowInside: Set<Track.Marker.Kind> = []
        for tr in triggers where tr.aabb.contains(carPosition) {
            nowInside.insert(tr.kind)
        }

        // Newly-entered triggers this frame
        for kind in nowInside.subtracting(inside) {
            handle(crossing: kind, at: time)
        }

        inside = nowInside
    }

    // MARK: - State transitions

    private func handle(crossing kind: Track.Marker.Kind, at time: TimeInterval) {
        // Out-of-order crossings are ignored entirely — better to do
        // nothing than to corrupt the state machine.
        guard kind == expecting else { return }

        switch kind {
        case .startFinish:
            if let lapStart = lapStartTime {
                // Closing a lap.
                let lap = time - lapStart
                if lap >= Timing.minimumLapTime {
                    finalizeSector(index: 2, at: time)  // close S3
                    snapshot.lastLap = lap
                    if bestLapBuffer == nil || lap < (bestLapBuffer ?? .infinity) {
                        bestLapBuffer = lap
                        snapshot.bestLap = lap
                        snapshot.didSetPB = true
                    } else {
                        snapshot.didSetPB = false
                    }
                }
            }
            // Open a new lap.
            lapStartTime = time
            sectorStartTime = time
            snapshot.sector = 1
            // Clear deltas at the top of a new lap so the HUD can show
            // splits as they accumulate.
            snapshot.lastSectorDeltas = [nil, nil, nil]
            snapshot.sectorSplits = [nil, nil, nil]
            expecting = .sector2

        case .sector2:
            finalizeSector(index: 0, at: time)
            snapshot.sector = 2
            sectorStartTime = time
            expecting = .sector3

        case .sector3:
            finalizeSector(index: 1, at: time)
            snapshot.sector = 3
            sectorStartTime = time
            expecting = .startFinish
        }
    }

    /// Close out a sector — record split, compare to PB, push to snapshot.
    private func finalizeSector(index: Int, at time: TimeInterval) {
        guard let start = sectorStartTime,
              (0...2).contains(index) else { return }
        let split = time - start
        snapshot.sectorSplits[index] = split

        if let pb = bestSectorTimes[index] {
            snapshot.lastSectorDeltas[index] = split - pb
            if split < pb {
                bestSectorTimes[index] = split
                snapshot.sectorPBs = bestSectorTimes
            }
        } else {
            // No PB yet — first time through this sector becomes the PB.
            bestSectorTimes[index] = split
            snapshot.sectorPBs = bestSectorTimes
            snapshot.lastSectorDeltas[index] = 0  // shows "—" in HUD
        }
    }

    // MARK: - Internal storage shadowed onto snapshot for stability

    private var bestLapBuffer: TimeInterval? = nil
}

/// Snapshot pushed to `AppState` once per ~100 ms. Equatable so the HUD
/// only redraws when something actually changed.
struct LapTiming: Equatable {
    var currentLap: TimeInterval = 0
    var lastLap: TimeInterval? = nil
    var bestLap: TimeInterval? = nil

    /// 1, 2, or 3.
    var sector: Int = 1

    /// Sector split times — `sectorSplits[0]` = S1, etc. `nil` until
    /// the corresponding boundary is crossed this lap.
    var sectorSplits: [TimeInterval?] = [nil, nil, nil]

    /// Signed delta vs personal-best for the matching sector.
    /// Negative = improved. Used by the HUD to colour the pill.
    var lastSectorDeltas: [TimeInterval?] = [nil, nil, nil]

    /// Personal-best sector times (for HUD reference).
    var sectorPBs: [TimeInterval?] = [nil, nil, nil]

    /// Flips true on a new fastest lap; HUD reads then resets it.
    var didSetPB: Bool = false
}

extension TimeInterval {
    /// `MM:SS.mmm` formatting for the lap clock and split readouts.
    var asLapString: String {
        guard self.isFinite, self >= 0 else { return "—:——.———" }
        let total = self
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, seconds)
    }
}
