import Foundation
import SceneKit
import simd

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Constructs the visible + collidable track + decorations + checkpoint
/// triggers from a `Track` model. Phase 2.1 entry point.
///
/// Phase 2.1 change vs Phase 2: tarmac is now built as a **single
/// SCNGeometry** spanning the whole track, with shared boundary vertices
/// between adjacent pieces. This eliminates the per-piece-mesh seams /
/// z-fighting / floating-piece appearance from the first cut.
///
/// Curves additionally get a thin red kerb on the inside edge so corners
/// read as corners.
enum TrackBuilder {

    struct Built {
        let root: SCNNode               // contains tarmac, kerbs, decorations, trigger nodes
        let triggers: [TriggerInfo]     // one per marker, in lap order
        let spawn: SCNMatrix4           // world transform for the car
    }

    struct TriggerInfo {
        let kind: Track.Marker.Kind
        let node: SCNNode
    }

    /// Build the whole track. Static + functional; no shared state.
    static func build(_ track: Track) -> Built {
        let root = SCNNode()
        root.name = "Track.\(track.name)"

        // 1) Walk the piece chain once, building:
        //    - cumulative entry transforms (used for marker placement,
        //      decoration anchoring, spawn computation)
        //    - a single big tarmac mesh (vertices in world coords)
        //    - kerb strips for curves
        let (tarmacNode, kerbNodes, pieceEntryTransforms, finalTransform)
            = buildTarmacAndKerbs(for: track)
        root.addChildNode(tarmacNode)
        for kn in kerbNodes { root.addChildNode(kn) }

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

        // 4) Spawn transform.
        let spawn = computeSpawn(track: track,
                                 pieceTransforms: pieceEntryTransforms)

        // 5) Diagnostic: print piece anchors so we can position
        //    decorations from the actual world coords.
        printAnchors(track: track,
                     pieceTransforms: pieceEntryTransforms,
                     finalTransform: finalTransform)

        return Built(root: root, triggers: triggers, spawn: spawn)
    }

    // MARK: - Tarmac + kerbs (single mesh)

    /// Build the tarmac as one SCNNode containing one SCNGeometry covering
    /// every piece, plus a separate SCNNode per curve carrying its kerb.
    /// The cumulative entry transforms are returned so callers can place
    /// markers and decorations relative to the actual world geometry.
    private static func buildTarmacAndKerbs(for track: Track)
        -> (tarmac: SCNNode, kerbs: [SCNNode],
            entries: [SCNMatrix4], finalTransform: SCNMatrix4)
    {
        var vertices: [SCNVector3] = []
        var normals:  [SCNVector3] = []
        var indices:  [UInt32] = []

        var entries: [SCNMatrix4] = []
        entries.reserveCapacity(track.pieces.count)
        var current: SCNMatrix4 = SCNMatrix4Identity

        // Carry the previous piece's exit-edge vertex indices forward so
        // adjacent pieces literally share the same vertex (no seam).
        var prevLeftIdx: UInt32? = nil
        var prevRightIdx: UInt32? = nil

        var kerbNodes: [SCNNode] = []

        for piece in track.pieces {
            entries.append(current)

            let samples = piece.defaultSampleCount
            let (leftLocal, rightLocal) = piece.sampleEdges(samples: samples)

            // Per-piece arrays of vertex indices into the global buffer.
            var leftIdx: [UInt32] = []
            var rightIdx: [UInt32] = []

            // First sample reuses the previous piece's exit vertices.
            let startSample: Int
            if let pl = prevLeftIdx, let pr = prevRightIdx {
                leftIdx.append(pl)
                rightIdx.append(pr)
                startSample = 1
            } else {
                startSample = 0
            }

            for i in startSample...samples {
                let lWorld = transformPoint(leftLocal[i],  by: current)
                let rWorld = transformPoint(rightLocal[i], by: current)
                vertices.append(scnVec(lWorld))
                normals.append(scnVec(Vec3(0, 1, 0)))
                leftIdx.append(UInt32(vertices.count - 1))
                vertices.append(scnVec(rWorld))
                normals.append(scnVec(Vec3(0, 1, 0)))
                rightIdx.append(UInt32(vertices.count - 1))
            }

            // Triangle indices for this piece's strip. Winding is CCW
            // viewed from +Y so the up-face is the front face.
            for s in 0..<samples {
                let l0 = leftIdx[s]
                let r0 = rightIdx[s]
                let l1 = leftIdx[s + 1]
                let r1 = rightIdx[s + 1]
                indices.append(contentsOf: [l0, r0, l1, r0, r1, l1])
            }

            prevLeftIdx = leftIdx.last
            prevRightIdx = rightIdx.last

            // Kerb: only on curves, on the inside edge.
            if case .curve(let angle, _, _, _, _) = piece, abs(angle) > 0.05 {
                let edgeLocal = angle > 0 ? rightLocal : leftLocal
                let kerb = makeKerb(edgeLocal: edgeLocal,
                                    pieceWidth: piece.width,
                                    isInside: true,
                                    transform: current)
                kerbNodes.append(kerb)
            }

            // Walls on both sides of every piece, with static physics so
            // the car can't drive off. Returned flat (one node per
            // segment) so each gets its own bounding box and SceneKit
            // can't accidentally cull a parent that "looks small."
            let leftWalls  = makeWallNodes(edgeLocal: leftLocal,  transform: current,
                                           color: RGB.hotelWhite.platformColor())
            let rightWalls = makeWallNodes(edgeLocal: rightLocal, transform: current,
                                           color: RGB.hotelWhite.platformColor())
            kerbNodes.append(contentsOf: leftWalls)
            kerbNodes.append(contentsOf: rightWalls)

            // Advance to next piece.
            current = SCNMatrix4Mult(current, piece.entryToExit)
        }

        let geom = makeGeometry(vertices: vertices,
                                normals: normals,
                                indices: indices,
                                color: RGB.tarmac.platformColor())

        let tarmacNode = SCNNode(geometry: geom)
        tarmacNode.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        tarmacNode.physicsBody?.friction = 1.0
        tarmacNode.castsShadow = false
        tarmacNode.name = "tarmac"

        return (tarmacNode, kerbNodes, entries, current)
    }

    /// Build a kerb strip as a series of small red boxes hugging an edge
    /// of a curve piece. Cosmetic only — no physics. The edge points are
    /// in piece-local; we transform them to world via `transform`.
    private static func makeKerb(edgeLocal: [Vec3],
                                 pieceWidth: Double,
                                 isInside: Bool,
                                 transform: SCNMatrix4) -> SCNNode {
        let parent = SCNNode()
        parent.name = "kerb"
        let mat = CarGeometry.flatMaterial(RGB.kerb.platformColor())
        mat.isDoubleSided = true

        for i in 0..<(edgeLocal.count - 1) {
            let a = transformPoint(edgeLocal[i], by: transform)
            let b = transformPoint(edgeLocal[i + 1], by: transform)
            let mid = Vec3((a.x + b.x) * 0.5,
                           (a.y + b.y) * 0.5 + 0.05,
                           (a.z + b.z) * 0.5)
            let dx = b.x - a.x
            let dz = b.z - a.z
            let len = (dx * dx + dz * dz).squareRoot()
            let yaw = atan2(dx, -dz)
            let strip = SCNBox(width: 0.6,
                               height: 0.1,
                               length: CGFloat(len + 0.1),
                               chamferRadius: 0)
            strip.firstMaterial = mat
            let n = SCNNode(geometry: strip)
            n.position = vec3(mid.x, mid.y, mid.z)
            n.eulerAngles = vec3(0, yaw, 0)
            // Push the kerb a hair INWARD or OUTWARD relative to the
            // edge — for a kerb on the inside of a turn we shift toward
            // the track center by half the kerb width.
            let _ = pieceWidth
            let _ = isInside
            parent.addChildNode(n)
        }
        return parent
    }

    /// Build the wall along an edge as a flat array of `SCNNode`s — one
    /// box per segment of the piece. Returning them flat (vs nested under
    /// a parent) means each node carries its own bounding box and
    /// SceneKit's frustum culling won't accidentally drop the whole row
    /// once the camera turns.
    private static func makeWallNodes(edgeLocal: [Vec3],
                                      transform: SCNMatrix4,
                                      color: PlatformColor) -> [SCNNode] {
        let mat = CarGeometry.flatMaterial(color)
        var out: [SCNNode] = []
        out.reserveCapacity(edgeLocal.count - 1)

        for i in 0..<(edgeLocal.count - 1) {
            let a = transformPoint(edgeLocal[i], by: transform)
            let b = transformPoint(edgeLocal[i + 1], by: transform)
            let midX = (a.x + b.x) * 0.5
            let midZ = (a.z + b.z) * 0.5
            let dx = b.x - a.x
            let dz = b.z - a.z
            let len = (dx * dx + dz * dz).squareRoot()
            let yaw = atan2(dx, -dz)

            let box = SCNBox(width: 0.4,
                             height: 1.6,
                             length: CGFloat(len + 0.05),
                             chamferRadius: 0)
            box.firstMaterial = mat
            let n = SCNNode(geometry: box)
            n.position = vec3(midX, 0.8, midZ)
            n.eulerAngles = vec3(0, yaw, 0)
            n.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
            n.physicsBody?.friction = 0.3
            n.physicsBody?.restitution = 0.1
            // No shadow casting — at ~800 walls the deferred shadow pass
            // can drop the whole batch on Apple Silicon.
            n.castsShadow = false
            n.name = "wall"
            out.append(n)
        }
        return out
    }

    private static func makeGeometry(vertices: [SCNVector3],
                                     normals: [SCNVector3],
                                     indices: [UInt32],
                                     color: PlatformColor) -> SCNGeometry {
        let vSource = SCNGeometrySource(vertices: vertices)
        let nSource = SCNGeometrySource(normals: normals)
        let iData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: iData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geom = SCNGeometry(sources: [vSource, nSource], elements: [element])
        let mat = CarGeometry.flatMaterial(color)
        mat.isDoubleSided = true
        geom.firstMaterial = mat
        return geom
    }

    // MARK: - Anchor diagnostics

    /// Print piece-by-piece world positions so authoring decoration
    /// `at` values is straightforward (just read off the console after a
    /// run and copy the numbers into Monaco.json).
    private static func printAnchors(track: Track,
                                     pieceTransforms: [SCNMatrix4],
                                     finalTransform: SCNMatrix4) {
        #if DEBUG
        print("[TrackBuilder] \(track.name) anchors:")
        for (i, m) in pieceTransforms.enumerated() {
            let pos = (Double(m.m41), Double(m.m42), Double(m.m43))
            let heading = atan2(-Double(m.m31), Double(m.m33)) * 180 / .pi
            print(String(format: "  piece %2d entry: (%7.2f, %5.2f, %7.2f) heading: %+7.2f°",
                         i, pos.0, pos.1, pos.2, heading))
        }
        let endPos = (Double(finalTransform.m41), Double(finalTransform.m42),
                      Double(finalTransform.m43))
        print(String(format: "  loop end:        (%7.2f, %5.2f, %7.2f)",
                     endPos.0, endPos.1, endPos.2))
        let dx = endPos.0 - 0, dz = endPos.2 - 0
        let gap = (dx * dx + dz * dz).squareRoot()
        print(String(format: "  loop closure gap: %.2f m", gap))
        #endif
    }

    // MARK: - Decorations (unchanged from Phase 2 except tunnel uses new
    // entries array — no more per-piece transform caching to recompute).

    private static func buildDecoration(_ deco: Decoration, track: Track,
                                        pieceTransforms: [SCNMatrix4],
                                        into parent: SCNNode) {
        switch deco {
        case .building(let at, let size, let rotation, let color, let style):
            let n = makeBuilding(size: size, color: color, style: style)
            n.position = vec3(at.x, at.y, at.z)
            n.eulerAngles = vec3(0, rotation, 0)
            parent.addChildNode(n)

        case .water(let at, let size, let rotation, let color):
            let plane = SCNBox(width: CGFloat(size.x),
                               height: 0.05,
                               length: CGFloat(size.z),
                               chamferRadius: 0)
            plane.firstMaterial = CarGeometry.flatMaterial(color.platformColor(alpha: 0.92))
            let n = SCNNode(geometry: plane)
            n.position = vec3(at.x, at.y, at.z)
            n.eulerAngles = vec3(0, rotation, 0)
            n.castsShadow = false
            parent.addChildNode(n)

        case .yacht(let at, let length, let rotation, let color):
            let n = makeYacht(length: length, color: color)
            n.position = vec3(at.x, at.y, at.z)
            n.eulerAngles = vec3(0, rotation, 0)
            parent.addChildNode(n)

        case .tunnelRoof(let from, let to, let height, let color):
            buildTunnelRoof(track: track, from: from, to: to,
                            height: height, color: color,
                            pieceTransforms: pieceTransforms,
                            into: parent)

        case .grandstand(let at, let size, let rotation, let color):
            let n = makeGrandstand(size: size, color: color)
            n.position = vec3(at.x, at.y, at.z)
            n.eulerAngles = vec3(0, rotation, 0)
            parent.addChildNode(n)

        case .treeCluster(let at, let count, let radius, let color):
            let cluster = SCNNode()
            cluster.position = vec3(at.x, at.y, at.z)
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
            let tier = CarGeometry.box(width: CGFloat(size.x * 0.65),
                                       height: CGFloat(size.y * 0.25),
                                       length: CGFloat(size.z * 0.65),
                                       chamfer: 0.02,
                                       color: color.platformColor())
            tier.position = vec3(0, size.y + size.y * 0.125, 0)
            parent.addChildNode(tier)
            let cap = CarGeometry.box(width: CGFloat(size.x * 0.08),
                                      height: CGFloat(size.y * 0.18),
                                      length: CGFloat(size.x * 0.08),
                                      chamfer: 0.01,
                                      color: PlatformColor(white: 0.55, alpha: 1))
            cap.position = vec3(0, size.y + size.y * 0.25 + size.y * 0.09, 0)
            parent.addChildNode(cap)

        case .hotel:
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
        let hull = CarGeometry.box(width: CGFloat(width),
                                   height: 0.4,
                                   length: CGFloat(length),
                                   chamfer: 0.15,
                                   color: color.platformColor())
        hull.position = vec3(0, 0.2, 0)
        parent.addChildNode(hull)
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
        let slab = CarGeometry.box(width: CGFloat(size.x),
                                   height: CGFloat(size.y),
                                   length: CGFloat(size.z),
                                   chamfer: 0.05,
                                   color: color.platformColor())
        slab.eulerAngles = vec3(0.55, 0, 0)
        slab.position = vec3(0, size.y / 2, 0)
        parent.addChildNode(slab)
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
        let leaves = SCNCone(topRadius: 0, bottomRadius: 0.55, height: 1.2)
        leaves.radialSegmentCount = 8
        leaves.firstMaterial = CarGeometry.flatMaterial(color.platformColor())
        let leavesN = SCNNode(geometry: leaves)
        leavesN.position = vec3(0, Double(trunkH) + 0.6, 0)
        parent.addChildNode(leavesN)
        return parent
    }

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
                let l = (left[s] + left[s + 1]) * 0.5
                let r = (right[s] + right[s + 1]) * 0.5
                let mid = Vec3((l.x + r.x) * 0.5, height, (l.z + r.z) * 0.5)
                let segLen = distance(left[s], left[s + 1])
                let segWidth = piece.width + 1.5

                let segNode = SCNNode()
                segNode.transform = entry

                let dz = right[s + 1].z - right[s].z
                let dx = right[s + 1].x - right[s].x
                let yaw = atan2(dx, -dz)

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
        let local = mat4Translation(0, s.rideHeight, -s.offsetAlong)
        return SCNMatrix4Mult(entry, local)
    }
}

// MARK: - Helpers

/// Apply an SCNMatrix4 to a Vec3 point (treating the point as a row
/// vector multiplied on the right by the matrix). SCNMatrix4 is
/// row-major-named with translation in m41/m42/m43, so this matches the
/// same convention SceneKit uses internally for `node.transform`.
private func transformPoint(_ p: Vec3, by m: SCNMatrix4) -> Vec3 {
    let x = p.x * Double(m.m11) + p.y * Double(m.m21) + p.z * Double(m.m31) + Double(m.m41)
    let y = p.x * Double(m.m12) + p.y * Double(m.m22) + p.z * Double(m.m32) + Double(m.m42)
    let z = p.x * Double(m.m13) + p.y * Double(m.m23) + p.z * Double(m.m33) + Double(m.m43)
    return Vec3(x, y, z)
}

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
