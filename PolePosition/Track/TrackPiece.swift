import Foundation
import SceneKit

/// A single piece of track. Pieces chain together via their
/// `entryToExit` transform — `TrackBuilder` walks the list with a running
/// `SCNMatrix4` and lays each piece's geometry in the right place.
///
/// Two cases for now (Phase 2). Phase 4's editor will introduce a few more
/// (kerb-decorated variants, pit-lane fork) but they reduce to these two
/// in terms of physics and timing.
///
/// Conventions:
/// - The car drives in chassis-local -Z direction. So a piece's "forward"
///   axis is also -Z in its entry frame; "+X" is to the car's right.
/// - `angle` for curves is in radians and is *positive for a right turn*
///   (clockwise viewed from above). Negative for a left turn. This is
///   the user-friendly convention; the matrix maths in `entryToExit`
///   converts it to the right-handed-coords negative rotation around +Y.
enum TrackPiece: Codable, Equatable {
    case straight(length: Double, width: Double, rise: Double = 0,
                  inTunnel: Bool = false)
    case curve(angle: Double, radius: Double, width: Double,
               rise: Double = 0, inTunnel: Bool = false)

    var width: Double {
        switch self {
        case .straight(_, let w, _, _): return w
        case .curve(_, _, let w, _, _): return w
        }
    }

    var inTunnel: Bool {
        switch self {
        case .straight(_, _, _, let t): return t
        case .curve(_, _, _, _, let t): return t
        }
    }

    /// Approximate length along the centerline. For a curve, arc length
    /// `radius * |angle|`.
    var centerlineLength: Double {
        switch self {
        case .straight(let l, _, _, _): return l
        case .curve(let a, let r, _, _, _): return r * abs(a)
        }
    }

    /// Transform that takes a point at the piece's *entry* (origin, facing
    /// -Z) to the corresponding point at its *exit*. Compose these along
    /// the piece chain to lay out a track.
    var entryToExit: SCNMatrix4 {
        switch self {
        case .straight(let length, _, let rise, _):
            return mat4Translation(0, rise, -length)

        case .curve(let angle, let radius, _, let rise, _):
            // Right turn (positive `angle`) = clockwise viewed from above
            // = NEGATIVE rotation around +Y in right-handed coords.
            //
            // Geometry: arc center is at +X in the entry frame, distance
            // = radius. Travelling along the arc by angle θ moves the car
            // by Δ = (radius·(1 − cos θ), 0, −radius·sin θ).
            let dx = radius * (1 - cos(angle))   // sideways toward the turn
            let dz = -radius * sin(angle)         // along forward (-Z)
            let translate = mat4Translation(dx, rise, dz)
            let rotate    = mat4Rotation(-angle, 0, 1, 0)
            // Apply rotation first, then translation: M = T · R.
            return SCNMatrix4Mult(translate, rotate)
        }
    }

    /// Sample N+1 points along the centerline from entry to exit, in the
    /// piece's *entry-local* frame. Used for path tessellation in
    /// `TrackBuilder` and for marker-position computation.
    /// - Parameter samples: number of segments (N). Returns N+1 points.
    func sampleCenterline(samples: Int) -> [Vec3] {
        let n = max(1, samples)
        switch self {
        case .straight(let length, _, let rise, _):
            return (0...n).map { i in
                let t = Double(i) / Double(n)
                return Vec3(0, rise * t, -length * t)
            }

        case .curve(let angle, let radius, _, let rise, _):
            return (0...n).map { i in
                let t = Double(i) / Double(n)
                let a = angle * t
                let dx = radius * (1 - cos(a))
                let dz = -radius * sin(a)
                return Vec3(dx, rise * t, dz)
            }
        }
    }

    /// Sample edge points (left and right) along the piece in its entry
    /// frame, with the given number of segments. Returned tuple is
    /// `(leftEdge, rightEdge)`. Each array has `samples + 1` points.
    func sampleEdges(samples: Int) -> (left: [Vec3], right: [Vec3]) {
        let halfW = width / 2
        let n = max(1, samples)
        switch self {
        case .straight(let length, _, let rise, _):
            var left:  [Vec3] = []
            var right: [Vec3] = []
            for i in 0...n {
                let t = Double(i) / Double(n)
                let cy = rise * t
                let cz = -length * t
                left.append(Vec3(-halfW, cy, cz))
                right.append(Vec3(halfW, cy, cz))
            }
            return (left, right)

        case .curve(let angle, let radius, _, let rise, _):
            var left:  [Vec3] = []
            var right: [Vec3] = []
            for i in 0...n {
                let t = Double(i) / Double(n)
                let a = angle * t
                // Centerline point + side offset rotated by -a.
                let cx = radius * (1 - cos(a))
                let cy = rise * t
                let cz = -radius * sin(a)
                // The "right" of the centerline at angle a is the
                // direction perpendicular to the tangent, pointing toward
                // +X side at a=0. Unit right = (cos a, 0, sin a) (verify:
                // at a=0 this is (1,0,0) = +X; at a=π/2, (0,0,1) = +Z,
                // correct since after a 90° right turn the driver's right
                // is now +Z).
                let rx = cos(a)
                let rz = sin(a)
                left.append(Vec3(cx - halfW * rx, cy, cz - halfW * rz))
                right.append(Vec3(cx + halfW * rx, cy, cz + halfW * rz))
            }
            return (left, right)
        }
    }

    /// Number of segments to sample for tessellation. Curves get more so
    /// they look round. Straights only need their endpoints.
    var defaultSampleCount: Int {
        switch self {
        case .straight: return 1
        case .curve(let angle, _, _, _, _):
            // ~12 segments per 90° arc; bump tighter angles slightly so
            // the Fairmont hairpin doesn't look hexagonal.
            let perRad = 12.0 / (.pi / 2)
            return max(6, Int((perRad * abs(angle)).rounded()))
        }
    }
}
