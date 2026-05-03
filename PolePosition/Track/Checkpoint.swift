import Foundation
import SceneKit
import simd

/// A trigger volume that fires when the car drives through it. Used for
/// sector boundaries and start/finish.
///
/// We don't use `SCNPhysicsContactDelegate` here. Detection is a simple
/// per-frame AABB-vs-position test: check if the car's chassis position
/// is inside any trigger's world AABB. With only 3 triggers per track,
/// this is trivial.
///
/// Triggers are *thick* — at least 5 m along the racing direction — so
/// a car at 360 km/h (100 m/s) at 60 fps still moves only ~1.7 m per
/// frame and can't tunnel through them.
struct Checkpoint: Equatable {
    let kind: Track.Marker.Kind
    let aabb: AABB
}

/// Axis-aligned bounding box in world space.
struct AABB: Equatable {
    var min: simd_float3
    var max: simd_float3

    func contains(_ p: simd_float3) -> Bool {
        return p.x >= min.x && p.x <= max.x
            && p.y >= min.y && p.y <= max.y
            && p.z >= min.z && p.z <= max.z
    }

    /// Build an AABB around a center point with given half-extents.
    init(center: simd_float3, halfExtents: simd_float3) {
        self.min = center - halfExtents
        self.max = center + halfExtents
    }

    init(min: simd_float3, max: simd_float3) {
        self.min = min
        self.max = max
    }
}

enum CheckpointBuilder {
    /// Default trigger thickness along the racing direction (metres).
    /// Wider than seems necessary so fast cars still hit it.
    static let triggerLength: Double = 6.0

    /// Trigger vertical extent — generously tall so a car bouncing over
    /// kerbs at full speed doesn't fly over it.
    static let triggerHeight: Double = 4.0

    /// Build an invisible trigger node at the given world transform,
    /// spanning the given track width.
    static func makeTriggerNode(at worldTransform: SCNMatrix4,
                                trackWidth: Double,
                                kind: Track.Marker.Kind) -> SCNNode {
        let g = SCNBox(width:  CGFloat(trackWidth + 4),
                       height: CGFloat(triggerHeight),
                       length: CGFloat(triggerLength),
                       chamferRadius: 0)
        // Visible-but-mostly-translucent strip across the track so the
        // start/finish line reads visually too. Sector triggers we hide.
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = kind == .startFinish
            ? PlatformColor(white: 1, alpha: 0.55)
            : PlatformColor(white: 1, alpha: 0)
        mat.transparency = kind == .startFinish ? 1 : 0
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = true
        g.firstMaterial = mat
        let n = SCNNode(geometry: g)
        n.transform = worldTransform
        // Hoist a hair so the strip sits *just above* the tarmac and
        // doesn't z-fight with it on the start-finish line.
        n.position = SCNVector3(n.position.x,
                                n.position.y + (kind == .startFinish ? 0.02 : 0),
                                n.position.z)
        n.name = "trigger.\(kind.rawValue)"
        return n
    }

    /// Compute the world-space AABB for a trigger node (used by the
    /// timing system every frame).
    static func aabb(for triggerNode: SCNNode) -> AABB {
        let (lmin, lmax) = triggerNode.boundingBox
        // Convert the node's local BB corners to world.
        let corners: [SCNVector3] = [
            SCNVector3(lmin.x, lmin.y, lmin.z),
            SCNVector3(lmax.x, lmin.y, lmin.z),
            SCNVector3(lmin.x, lmax.y, lmin.z),
            SCNVector3(lmax.x, lmax.y, lmin.z),
            SCNVector3(lmin.x, lmin.y, lmax.z),
            SCNVector3(lmax.x, lmin.y, lmax.z),
            SCNVector3(lmin.x, lmax.y, lmax.z),
            SCNVector3(lmax.x, lmax.y, lmax.z),
        ]
        let worldCorners = corners.map { triggerNode.convertPosition($0, to: nil) }
        var minP = simd_float3(.infinity, .infinity, .infinity)
        var maxP = simd_float3(-.infinity, -.infinity, -.infinity)
        for c in worldCorners {
            let v = simd_float3(Float(c.x), Float(c.y), Float(c.z))
            minP = simd_min(minP, v)
            maxP = simd_max(maxP, v)
        }
        return AABB(min: minP, max: maxP)
    }
}
