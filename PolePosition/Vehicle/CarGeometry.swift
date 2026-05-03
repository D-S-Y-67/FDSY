import Foundation
import SceneKit

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Cross-platform SCNVector3 constructor. SCNVector3 components are `Float`
/// on iOS but `CGFloat` (i.e. Double on 64-bit) on macOS. Sticking to one
/// helper keeps the geometry code identical on both platforms.
@inlinable
func vec3(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
    #if os(macOS)
    return SCNVector3(x, y, z)
    #else
    return SCNVector3(Float(x), Float(y), Float(z))
    #endif
}

/// Cross-platform SCNMatrix4 translation. Same Float/CGFloat split as
/// `vec3` — `SCNMatrix4MakeTranslation` is `CGFloat`-typed on macOS and
/// `Float`-typed on iOS.
@inlinable
func mat4Translation(_ x: Double, _ y: Double, _ z: Double) -> SCNMatrix4 {
    #if os(macOS)
    return SCNMatrix4MakeTranslation(x, y, z)
    #else
    return SCNMatrix4MakeTranslation(Float(x), Float(y), Float(z))
    #endif
}

/// Cross-platform SCNMatrix4 rotation around an axis (radians).
@inlinable
func mat4Rotation(_ angle: Double, _ x: Double, _ y: Double, _ z: Double) -> SCNMatrix4 {
    #if os(macOS)
    return SCNMatrix4MakeRotation(angle, x, y, z)
    #else
    return SCNMatrix4MakeRotation(Float(angle), Float(x), Float(y), Float(z))
    #endif
}

/// Tiny helpers for building flat-shaded primitives. Phase 1 uses these to
/// assemble the F1 car procedurally from boxes and cylinders.
///
/// Everything here is stateless. We hand back fully-configured `SCNNode`s.
enum CarGeometry {

    /// A flat-shaded material with no specular highlight. PolyTrack-style.
    static func flatMaterial(_ color: PlatformColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.specular.contents = PlatformColor.black
        m.lightingModel = .blinn
        m.locksAmbientWithDiffuse = true
        m.isDoubleSided = false
        return m
    }

    /// A box primitive wrapped in a node. `chamfer` rounds the edges
    /// slightly so polys catch the directional light a bit more cleanly.
    static func box(width: CGFloat, height: CGFloat, length: CGFloat,
                    chamfer: CGFloat = 0.01,
                    color: PlatformColor) -> SCNNode {
        let g = SCNBox(width: width, height: height, length: length, chamferRadius: chamfer)
        g.firstMaterial = flatMaterial(color)
        return SCNNode(geometry: g)
    }

    /// A cylinder. Default orientation is along Y in SceneKit; pass
    /// `rotationAxis` and `rotationAngle` if you want it lying along
    /// another axis.
    static func cylinder(radius: CGFloat, height: CGFloat,
                         color: PlatformColor) -> SCNNode {
        let g = SCNCylinder(radius: radius, height: height)
        g.radialSegmentCount = 18 // low-poly
        g.firstMaterial = flatMaterial(color)
        return SCNNode(geometry: g)
    }

    /// A wheel: a cylinder lying on its side along the X axis (its long
    /// axis is the spin axle). Wrapped in a parent node so that
    /// SCNPhysicsVehicleWheel — which overwrites the *wheel node's*
    /// transform every frame — doesn't undo our 90° rotation. The parent
    /// is what gets handed to the physics; the cylinder is its child and
    /// keeps its orientation relative to the parent.
    static func wheel(radius: CGFloat, halfWidth: CGFloat,
                      color: PlatformColor = .black) -> SCNNode {
        let parent = SCNNode()
        let inner = cylinder(radius: radius, height: halfWidth * 2, color: color)
        // Rotate so the cylinder's long axis aligns with the parent's
        // local X (the axle direction). +π/2 around Z maps local Y → -X.
        inner.eulerAngles = vec3(0, 0, .pi / 2)
        parent.addChildNode(inner)

        // A small contrasting marker on the rim so spin is visible. The
        // marker is positioned at the top of the wheel; as the wheel
        // rotates around its X axis the marker sweeps round, which gives
        // the eye something to track.
        let marker = box(width: halfWidth * 1.2, height: 0.04,
                         length: radius * 0.45, chamfer: 0,
                         color: PlatformColor(white: 0.85, alpha: 1))
        marker.position = vec3(0, Double(radius) - 0.01, 0)
        parent.addChildNode(marker)

        return parent
    }
}
