import Foundation
import SceneKit

/// A non-racing-surface prop attached to a track. Decorations are
/// authored in world coordinates (the same coords pieces lay out into) so
/// hand-positioning landmarks like the Casino is straightforward: figure
/// out where Casino Square ends up after walking the piece chain, then
/// drop a `building` decoration there.
///
/// Phase 2 ships a small set; later phases extend the enum with more
/// kinds (kerb strips, marshal posts, podium, pit complex pieces, etc.).
enum Decoration: Codable, Equatable {
    /// A simple stack-of-boxes building. `style` controls what extra
    /// detail `TrackBuilder` adds on top of the base block (a stepped
    /// roof for casinos, vertical window stripes for hotels, a thin
    /// spire for towers).
    case building(at: Vec3, size: Vec3, rotation: Double = 0,
                  color: RGB, style: BuildingStyle = .plain)

    /// A flat coloured plane — for the harbor water, swimming pool, etc.
    /// Sits at `at.y` with extents `size.x × size.z` centered on `at.xz`.
    case water(at: Vec3, size: Vec2, rotation: Double = 0,
               color: RGB = .harborBlue)

    /// A boat hull. `length` is metres bow-to-stern; width is computed as
    /// `length * 0.3` for a generic motor-yacht silhouette.
    case yacht(at: Vec3, length: Double, rotation: Double = 0,
               color: RGB = .yachtWhite)

    /// Tunnel ceiling spanning a contiguous range of pieces. The roof
    /// follows the centerline at a fixed height above the tarmac.
    case tunnelRoof(fromPiece: Int, toPieceInclusive: Int,
                    height: Double = 4.5,
                    color: RGB = RGB(0.18, 0.16, 0.16))

    /// Simple grandstand: a tilted slab. `at` is the bottom-front center.
    case grandstand(at: Vec3, size: Vec3, rotation: Double = 0,
                    color: RGB = RGB(0.55, 0.55, 0.58))

    /// Cluster of low-poly trees (cones on cylinders).
    case treeCluster(at: Vec3, count: Int = 5, radius: Double = 4,
                     color: RGB = .foliage)
}

/// Building variant. Drives only cosmetic details added on top of a
/// uniformly-coloured base box.
enum BuildingStyle: String, Codable, Equatable {
    case plain      // just the base box
    case casino     // stepped tier on top
    case hotel      // vertical window stripes on the long faces
    case tower      // base box + thin spire on top
}
