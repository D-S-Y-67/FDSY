import Foundation
import SceneKit
import simd

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Constructs the visible + collidable track + decorations + checkpoint
/// triggers from a `Track` model. Phase 2 entry point: replaces the bare
/// flat plane from Phase 1 inside `SceneBuilder`.
///
/// Layout strategy: walk the piece list with a running `SCNMatrix4`. For
/// each piece we build a small per-piece tarmac mesh (in piece-local
/// coords), wrap it in an `SCNNode`, and assign the accumulated world
/// transform to that node. Adjacent pieces share their entry/exit
/// vertices so seams are tight.
///
/// We deliberately keep tarmac as a top-face-only triangle strip — from
/// above you never see the underside, and a thin slab below is provided
/// by the giant slate floor in `SceneBuilder`.
enum TrackBuilder {

    struct Built {
        let root: SCNNode               // contains tarmac, decorations, trigger nodes
        let triggers: [TriggerInfo]     // one per marker, in lap order
        let spawn: SCNMatrix4           // world transform for the car
    }

    struct TriggerInfo {
        let kind: Track.Marker.Kind
        let node: SCNNode               // already added under `root`
    }

    /// Build the whole track. Static + functional; no shared state.
    static func build(_ track: Track) -> Built {
        let root = SCNNode()
        root.name = "Track.\(track.name)"

        // 1) Walk pieces, accumulating an entry transform per piece. Drop
        //    one tarmac mesh per piece into the root.
        var current: SCNMatrix4 = SCNMatrix4Identity
        var pieceEntryTransforms: [SCNMatrix4] = []
        pieceEntryTransforms.reserveCapacity(track.pieces.count)

        let tarmacColor = RGB.tarmac.platformColor()

        for piece in track.pieces {
            pieceEntryTransforms.append(current)

            let geom = tarmacMesh(for: piece, color: tarmacColor)
            let node = SCNNode(geometry: geom)
            node.transform = current
            // Static physics body so the car has something to drive on
            // even if it leaves the giant slate floor underneath.
            node.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
            node.physicsBody?.friction = 1.0
            node.castsShadow = false
            root.addChildNode(node)

            current = SCNMatrix4Mult(current, piece.entryToExit)
        }

        // 2) Triggers (start/finish + sector boundaries).
        var triggers: [TriggerInfo] = []
        for marker in track.markers {
            guard track.pieces.indices.contains(marker.pieceIndex) else { continue }
            let pieceWidth = track.pieces[marker.pieceIndex].width
            let trigger = CheckpointBuilder.makeTriggerNode(
                at: pieceEntryTransforms[marker.pieceIndex],
                trackWidth: pieceWidth,
                kind: marker.kind
            )
            root.addChildNode(trigger)
            triggers.append(TriggerInfo(kind: marker.kind, node: trigger))
        }

        // 3) Decorations.
        for deco in track.decorations {
            buildDecoration(deco, track: track,
                            pieceTransforms: pieceEntryTransforms,
                            into: root)
        }

        // 4) Spawn transform: take the spawn piece's entry transform,
        //    advance along its centerline by `offsetAlong`, lift by
        //    `rideHeight`.
        let spawn = computeSpawn(track: track, pieceTransforms: pieceEntryTransforms)

        return Built(root: root, triggers: triggers, spawn: spawn)
    }

    // MARK: - Tarmac geometry

    /// Build a top-face-only triangle strip for one piece in its
    /// entry-local coordinates. Y is up — the strip lies (approximately)
    /// on the XZ plane.
    private static func tarmacMesh(for piece: TrackPiece,
                                   color: PlatformColor) -> SCNGeometry {
        let samples = piece.defaultSampleCount
        let (left, right) = piece.sampleEdges(samples: samples)

        // Vertices: pairs (left_i, right_i) for i in 0...samples.
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity((samples + 1) * 2)
        for i in 0...samples {
            vertices.append(scnVec(left[i]))
            vertices.append(scnVec(right[i]))
        }

        // All normals point straight up.
        let up: [SCNVector3] = Array(repeating: SCNVector3(0, 1, 0),
                                     count: vertices.count)

        // Triangles: for each strip segment i, two triangles. Winding is
        // CCW viewed from above (+Y) so the up-face is the *front* face
        // and SceneKit doesn't cull it. Don't reorder these without
        // re-checking the cross product — it's load-bearing.
        var indices: [UInt32] = []
        indices.reserveCapacity(samples * 6)
        for i in 0..<samples {
            let l0 = UInt32(i * 2)
            let r0 = UInt32(i * 2 + 1)
            let l1 = UInt32((i + 1) * 2)
            let r1 = UInt32((i + 1) * 2 + 1)
            indices.append(contentsOf: [l0, r0, l1, r0, r1, l1])
        }

        let vSource = SCNGeometrySource(vertices: vertices)
        let nSource = SCNGeometrySource(normals: up)
        let iData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: iData,
            primitiveType: .triangles,
            primitiveCount: samples * 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geom = SCNGeometry(sources: [vSource, nSource], elements: [element])
        let mat = CarGeometry.flatMaterial(color)
        // Belt-and-suspenders: even if a future change inverts the winding
        // we won't end up with an invisible track.
        mat.isDoubleSided = true
        geom.firstMaterial = mat
        return geom
    }

    // MARK: - Decorations

    private static func buildDecoration(_ deco: Decoration, track: Track,
                                        pieceTransforms: [SCNMatrix4],
                                        into parent: SCNNode) {
        switch deco {
        case .building(let at, let size, let rotation, let color, let style):
            let n = makeBuilding(size: size, color: color, style: style)
            n.position = scnVec(at)
            n.eulerAngles = vec3(0, rotation, 0)
            parent.addChildNode(n)

        case .water(let at, let size, let rotation, let color):
            let plane = SCNBox(width: CGFloat(size.x),
                               height: 0.05,
                               length: CGFloat(size.z),
                               chamferRadius: 0)
            plane.firstMaterial = CarGeometry.flatMaterial(color.platformColor(alpha: 0.92))
            let n = SCNNode(geometry: plane)
            n.position = scnVec(at)
            n.eulerAngles = vec3(0, rotation, 0)
            n.castsShadow = false
            parent.addChildNode(n)

        case .yacht(let at, let length, let rotation, let color):
            let n = makeYacht(length: length, color: color)
            n.position = scnVec(at)
            n.eulerAngles = vec3(0, rotation, 0)
            parent.addChildNode(n)

        case .tunnelRoof(let from, let to, let height, let color):
            buildTunnelRoof(track: track, from: from, to: to,
                            height: height, color: color,
                            pieceTransforms: pieceTransforms,
                            into: parent)

        case .grandstand(let at, let size, let rotation, let color):
            let n = makeGrandstand(size: size, color: color)
            n.position = scnVec(at)
            n.eulerAngles = vec3(0, rotation, 0)
            parent.addChildNode(n)

        case .treeCluster(let at, let count, let radius, let color):
            let cluster = SCNNode()
            cluster.position = scnVec(at)
            for i in 0..<count {
                let angle = Double(i) / Double(max(1, count)) * 2 * .pi
                let dx = cos(angle) * radius
                let dz = sin(angle) * radius
                let tree = makeTree(color: color)
                tree.position = vec3(dx, 0, dz)
                cluster.addChildNode(tree)
            }
            parent.addChildNode(cluster)
        }
    }

    private static func makeBuilding(size: Vec3, color: RGB,
                                     style: BuildingStyle) -> SCNNode {
        let parent = SCNNode()
        // Base box, rooted at ground level (so `at.y == 0` plants it on
        // the ground). The box's origin is its center, so we lift it.
        let base = CarGeometry.box(width: CGFloat(size.x),
                                   height: CGFloat(size.y),
                                   length: CGFloat(size.z),
                                   chamfer: 0.02,
                                   color: color.platformColor())
        base.position = vec3(0, size.y / 2, 0)
        parent.addChildNode(base)

        switch style {
        case .plain:
            break

        case .casino:
            // Stepped tier on top — half the size, lifted on top of the
            // base. Adds the ornate-skyline silhouette without modelling
            // anything specific.
            let tier = CarGeometry.box(width: CGFloat(size.x * 0.65),
                                       height: CGFloat(size.y * 0.25),
                                       length: CGFloat(size.z * 0.65),
                                       chamfer: 0.02,
                                       color: color.platformColor())
            tier.position = vec3(0, size.y + size.y * 0.125, 0)
            parent.addChildNode(tier)
            // A small spire-ish accent.
            let cap = CarGeometry.box(width: CGFloat(size.x * 0.08),
                                      height: CGFloat(size.y * 0.18),
                                      length: CGFloat(size.x * 0.08),
                                      chamfer: 0.01,
                                      color: PlatformColor(white: 0.55, alpha: 1))
            cap.position = vec3(0, size.y + size.y * 0.25 + size.y * 0.09, 0)
            parent.addChildNode(cap)

        case .hotel:
            // Vertical window stripes on the long faces. We put 6 stripes
            // per long side, slightly recessed.
            let stripeColor = PlatformColor(white: 0.25, alpha: 1)
            let stripeCount = 6
            for side in [-1.0, 1.0] {
                for i in 0..<stripeCount {
                    let t = (Double(i) + 0.5) / Double(stripeCount)
                    let z = (t - 0.5) * size.z
                    let stripe = CarGeometry.box(
                        width: 0.02,
                        height: CGFloat(size.y * 0.85),
                        length: CGFloat(size.z / Double(stripeCount) * 0.6),
                        chamfer: 0,
                        color: stripeColor)
                    stripe.position = vec3(side * (size.x / 2 + 0.005),
                                           size.y / 2,
                                           z)
                    parent.addChildNode(stripe)
                }
            }

        case .tower:
            // Thin spire on top.
            let spire = CarGeometry.box(width: CGFloat(size.x * 0.18),
                                        height: CGFloat(size.y * 0.4),
                                        length: CGFloat(size.x * 0.18),
                                        chamfer: 0.01,
                                        color: color.platformColor())
            spire.position = vec3(0, size.y + size.y * 0.2, 0)
            parent.addChildNode(spire)
        }

        return parent
    }

    private static func makeYacht(length: Double, color: RGB) -> SCNNode {
        let parent = SCNNode()
        let width = length * 0.3
        // Hull
        let hull = CarGeometry.box(width: CGFloat(width),
                                   height: 0.4,
                                   length: CGFloat(length),
                                   chamfer: 0.15,
                                   color: color.platformColor())
        hull.position = vec3(0, 0.2, 0)
        parent.addChildNode(hull)
        // Cabin / superstructure
        let cabin = CarGeometry.box(width: CGFloat(width * 0.7),
                                    height: 0.6,
                                    length: CGFloat(length * 0.45),
                                    chamfer: 0.05,
                                    color: PlatformColor(white: 0.95, alpha: 1))
        cabin.position = vec3(0, 0.7, length * -0.05)
        parent.addChildNode(cabin)
        return parent
    }

    private static func makeGrandstand(size: Vec3, color: RGB) -> SCNNode {
        let parent = SCNNode()
        // A tilted slab, leaning back. Implemented as a box rotated about X.
        let slab = CarGeometry.box(width: CGFloat(size.x),
                                   height: CGFloat(size.y),
                                   length: CGFloat(size.z),
                                   chamfer: 0.05,
                                   color: color.platformColor())
        slab.eulerAngles = vec3(0.55, 0, 0) // ~32° lean
        slab.position = vec3(0, size.y / 2, 0)
        parent.addChildNode(slab)
        // Front kerb / barrier
        let barrier = CarGeometry.box(width: CGFloat(size.x),
                                      height: 0.4,
                                      length: 0.2,
                                      chamfer: 0,
                                      color: PlatformColor(white: 0.9, alpha: 1))
        barrier.position = vec3(0, 0.2, size.z / 2)
        parent.addChildNode(barrier)
        return parent
    }

    private static func makeTree(color: RGB) -> SCNNode {
        let parent = SCNNode()
        let trunkH: CGFloat = 0.6
        let trunk = SCNCylinder(radius: 0.08, height: trunkH)
        trunk.radialSegmentCount = 8
        trunk.firstMaterial = CarGeometry.flatMaterial(
            PlatformColor(red: 0.32, green: 0.22, blue: 0.10, alpha: 1))
        let trunkN = SCNNode(geometry: trunk)
        trunkN.position = vec3(0, Double(trunkH) / 2, 0)
        parent.addChildNode(trunkN)

        // Conical foliage
        let leaves = SCNCone(topRadius: 0, bottomRadius: 0.55, height: 1.2)
        leaves.radialSegmentCount = 8
        leaves.firstMaterial = CarGeometry.flatMaterial(color.platformColor())
        let leavesN = SCNNode(geometry: leaves)
        leavesN.position = vec3(0, Double(trunkH) + 0.6, 0)
        parent.addChildNode(leavesN)
        return parent
    }

    /// Build a U-channel roof spanning a contiguous run of pieces.
    /// We sample the centerline of each piece in the range and lay slabs
    /// along it at `height` metres above the tarmac.
    private static func buildTunnelRoof(track: Track,
                                        from: Int, to: Int,
                                        height: Double, color: RGB,
                                        pieceTransforms: [SCNMatrix4],
                                        into parent: SCNNode) {
        guard from <= to,
              from >= 0, to < track.pieces.count else { return }
        let mat = CarGeometry.flatMaterial(color.platformColor())
        let darkInside = CarGeometry.flatMaterial(
            color.platformColor().withSlightlyDarker())

        for i in from...to {
            let piece = track.pieces[i]
            let entry = pieceTransforms[i]
            let samples = max(4, piece.defaultSampleCount)
            let (left, right) = piece.sampleEdges(samples: samples)
            for s in 0..<samples {
                // Midpoint of the segment in piece-local coords. Used
                // for both the roof slab and its dark underside.
                let l = (left[s] + left[s + 1]) * 0.5
                let r = (right[s] + right[s + 1]) * 0.5
                let mid = Vec3((l.x + r.x) * 0.5, height, (l.z + r.z) * 0.5)
                let segLen = distance(left[s], left[s + 1])
                let segWidth = piece.width + 1.5

                // We parent everything under a node positioned at the
                // piece's world entry transform so the children's local
                // (mid) coords land in the right world location.
                let segNode = SCNNode()
                segNode.transform = entry

                // Tangent rotation: yaw of the segment direction in
                // piece-local. 0 when forward == -Z.
                let dz = right[s + 1].z - right[s].z
                let dx = right[s + 1].x - right[s].x
                let yaw = atan2(dx, -dz)

                // Roof slab.
                let slab = SCNBox(width: CGFloat(segWidth),
                                  height: 0.4,
                                  length: CGFloat(segLen + 0.05),
                                  chamferRadius: 0)
                slab.firstMaterial = mat
                let slabN = SCNNode(geometry: slab)
                slabN.position = vec3(mid.x, mid.y, mid.z)
                slabN.eulerAngles = vec3(0, yaw, 0)
                slabN.castsShadow = true
                segNode.addChildNode(slabN)

                // A thin darker slab just under the roof so the inside
                // of the tunnel reads as shaded.
                let under = SCNBox(width: CGFloat(segWidth - 0.2),
                                   height: 0.02,
                                   length: CGFloat(segLen + 0.05),
                                   chamferRadius: 0)
                under.firstMaterial = darkInside
                let underN = SCNNode(geometry: under)
                underN.position = vec3(mid.x, mid.y - 0.21, mid.z)
                underN.eulerAngles = slabN.eulerAngles
                segNode.addChildNode(underN)

                parent.addChildNode(segNode)
            }
        }
    }

    // MARK: - Spawn

    private static func computeSpawn(track: Track,
                                     pieceTransforms: [SCNMatrix4]) -> SCNMatrix4 {
        let s = track.spawn
        guard track.pieces.indices.contains(s.pieceIndex) else {
            return mat4Translation(0, s.rideHeight, 0)
        }
        let entry = pieceTransforms[s.pieceIndex]
        // Forward by `offsetAlong` along the piece (in piece-local -Z),
        // lifted by `rideHeight`.
        let local = mat4Translation(0, s.rideHeight, -s.offsetAlong)
        return SCNMatrix4Mult(entry, local)
    }
}

// MARK: - Helpers

private func scnVec(_ v: Vec3) -> SCNVector3 {
    #if os(macOS)
    return SCNVector3(v.x, v.y, v.z)
    #else
    return SCNVector3(Float(v.x), Float(v.y), Float(v.z))
    #endif
}

private func + (a: Vec3, b: Vec3) -> Vec3 {
    Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
}

private func * (a: Vec3, s: Double) -> Vec3 {
    Vec3(a.x * s, a.y * s, a.z * s)
}

private func distance(_ a: Vec3, _ b: Vec3) -> Double {
    let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
    return (dx * dx + dy * dy + dz * dz).squareRoot()
}

private extension PlatformColor {
    func withSlightlyDarker() -> PlatformColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if os(macOS)
        let conv = self.usingColorSpace(.deviceRGB) ?? self
        conv.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return PlatformColor(red: max(0, r * 0.4),
                             green: max(0, g * 0.4),
                             blue: max(0, b * 0.4),
                             alpha: a)
    }
}
