import Foundation

/// Loads `Track` JSON from the app bundle.
///
/// All official circuits sit in `Circuits/` as JSON resources registered
/// in `project.pbxproj`'s resources phase. Custom tracks (Phase 4) take
/// a different path (FileManager / SwiftData / pasteboard base64).
enum TrackLoader {

    enum LoadError: Error {
        case resourceMissing(name: String)
        case decodeFailed(name: String, underlying: Error)
    }

    /// Load a bundled track JSON by basename (no extension).
    static func loadBundled(_ name: String) throws -> Track {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw LoadError.resourceMissing(name: name)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Track.self, from: data)
        } catch {
            throw LoadError.decodeFailed(name: name, underlying: error)
        }
    }

    /// Convenience: load the named track or fall back to a hard-coded
    /// emergency oval if anything goes wrong. Used by `SceneBuilder` so
    /// the scene always has *something* to render even when the JSON
    /// resources aren't bundled correctly (a common Xcode-target gotcha).
    static func loadOrFallback(_ choice: TrackChoice) -> Track {
        do {
            return try loadBundled(choice.rawValue)
        } catch {
            print("[TrackLoader] failed to load \(choice.rawValue): \(error). Using emergency oval.")
            return emergencyOval
        }
    }

    /// A four-corner oval generated in code so we never end up rendering
    /// nothing. The fallback is also useful in unit tests and previews.
    static var emergencyOval: Track {
        let w = 14.0
        let r = 28.0
        let len = 60.0
        return Track(
            name: "Emergency Oval",
            pieces: [
                .straight(length: len, width: w),
                .curve(angle: .pi, radius: r, width: w),
                .straight(length: len, width: w),
                .curve(angle: .pi, radius: r, width: w),
            ],
            markers: [
                .init(kind: .startFinish, pieceIndex: 0),
                .init(kind: .sector2,     pieceIndex: 1),
                .init(kind: .sector3,     pieceIndex: 2),
            ],
            spawn: .init(pieceIndex: 0, offsetAlong: 4, rideHeight: 1.5),
            decorations: [],
            skybox: .day,
            groundColor: .pavementGrey
        )
    }
}
