import Foundation
import SceneKit

/// Top-level track model. Codable for JSON resources now and base64
/// share-codes in Phase 4. The same struct is the source of truth for
/// official circuits (`Circuits/Monaco.json`) and editor-built custom
/// tracks (Phase 4).
struct Track: Codable, Equatable {
    var name: String
    var pieces: [TrackPiece]
    var markers: [Marker]
    var spawn: Spawn
    var decorations: [Decoration]
    var skybox: Skybox = .day
    var groundColor: RGB = .pavementGrey

    /// Sector boundary / start-finish locator. Each marker sits at the
    /// *entry* of `pieces[pieceIndex]`.
    struct Marker: Codable, Equatable {
        var kind: Kind
        var pieceIndex: Int

        enum Kind: String, Codable, Equatable {
            case startFinish    // also the S1 start
            case sector2        // S1 → S2
            case sector3        // S2 → S3
        }
    }

    /// Where the car appears on `R` / first launch. Always sits on the
    /// centerline at the start of `pieces[pieceIndex]`, offset forward by
    /// `offsetAlong` metres along that piece. Y is the spawn ride-height
    /// above the tarmac.
    struct Spawn: Codable, Equatable {
        var pieceIndex: Int = 0
        var offsetAlong: Double = 2.0
        var rideHeight: Double = 1.5
    }
}

/// Backdrop preset. Phase 2 ships only `.day`; the rest are wired into
/// `SceneBuilder`'s lighting profiles in Phase 6+ when the other circuits
/// land.
enum Skybox: String, Codable, Equatable {
    case day, dusk, night, desert
}

// MARK: - Tiny Codable value types

/// 2D point. Used for water plane sizes and similar.
struct Vec2: Codable, Equatable {
    var x: Double
    var z: Double
    init(_ x: Double, _ z: Double) { self.x = x; self.z = z }
}

/// 3D point. Used everywhere decorations are placed.
struct Vec3: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }
}

/// Plain sRGB triple in 0...1. Decoded transparently from JSON arrays
/// (`[r, g, b]`) for compactness.
struct RGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        r = try c.decode(Double.self)
        g = try c.decode(Double.self)
        b = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(r); try c.encode(g); try c.encode(b)
    }

    /// Convert to the platform-specific colour type used by `CarGeometry`.
    func platformColor(alpha: Double = 1) -> PlatformColor {
        PlatformColor(red: r, green: g, blue: b, alpha: alpha)
    }

    // Shared default palette — used as Codable defaults.
    static let pavementGrey = RGB(0.62, 0.60, 0.55)
    static let tarmac       = RGB(0.20, 0.21, 0.23)
    static let harborBlue   = RGB(0.10, 0.32, 0.48)
    static let casinoCream  = RGB(0.90, 0.86, 0.74)
    static let hotelWhite   = RGB(0.93, 0.92, 0.88)
    static let residential  = RGB(0.78, 0.74, 0.66)
    static let yachtWhite   = RGB(0.96, 0.96, 0.94)
    static let kerb         = RGB(0.85, 0.10, 0.10)
    static let foliage      = RGB(0.18, 0.45, 0.22)
}
