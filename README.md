# PolePosition

An F1-themed low-poly time-trial racer for iOS, iPadOS, and macOS. SwiftUI shell, SceneKit rendering, `SCNPhysicsVehicle` for the car. Inspired by [PolyTrack](https://kodub.itch.io/polytrack).

> **Status: Phase 1 — driving prototype.** Bare scene, flat plane, one car, keyboard input on Mac. The other 9 phases (tracks, ghosts, editor, teams, F1 systems, modes, audio, polish, community) build on top of this once the physics feels right.

## Build

Requires Xcode 15.3+ on macOS 14+. Single target, multiplatform.

```sh
open PolePosition.xcodeproj
```

Pick the `PolePosition` scheme. Run on **My Mac**. The window opens with an F1 car on a slate plane.

If the project file fails to open (hand-written `project.pbxproj`, no Mac available to test before commit) — see [Recovery](#recovery) below.

## Controls (Phase 1, macOS only)

| Action     | Key                  |
|------------|----------------------|
| Throttle   | `W` or `↑`           |
| Brake      | `S` or `↓`           |
| Steer L/R  | `A` `D` or `←` `→`   |
| Handbrake  | `Space`              |
| Respawn    | `R` or `Return`      |

Telemetry overlay (top-left): speed in KPH, throttle/brake/steer values, key hints.

iOS / iPadOS builds compile and render the scene but have no input wired yet — touch and MFi controllers come in a later phase.

## What to verify

1. The car spawns at origin and sits on its wheels (no clipping into the ground, no immediate flip).
2. Hold `W`: car accelerates, rear gets a touch loose.
3. Tap `A` / `D`: steering self-centres when you let go.
4. Hard brake (`S`) at speed: car stops in a reasonable distance, doesn't dive into the floor.
5. `Space` at speed: handbrake locks rears (currently treated same as brake — Phase 7 differentiates them).
6. Respawn (`R`) returns the car to origin, zero velocity, camera snaps back behind it.
7. Camera trails behind the car with a slight lag, doesn't snap.

If any of those feel wrong, the dial is in `PolePosition/Game/Physics/PhysicsTuning.swift`. Edit, ⌘B, drive, repeat.

## Tuning

`PhysicsTuning` is the single source of truth for the dials. Defaults aim for an arcade RWD feel:

| Constant | Default | Effect |
|---|---|---|
| `mass` | 800 kg | Heavier = harder to flip, slower to react |
| `maxEngineForce` | 1400 N (per rear wheel) | Acceleration |
| `maxBrakeForce` | 60 N·m | Stopping power |
| `maxSteerRadians` | 0.55 (~31°) | Steering lock |
| `steerLerp` | 12.0 / s | Steering responsiveness |
| `frictionSlipFront` | 1.6 | Front grip — raise to fix understeer |
| `frictionSlipRear` | 1.4 | Rear grip — raise to fix oversteer |
| `suspensionStiffness` | 5.5 | Spring rate |
| `suspensionDamping` | 2.3 | Wobble — raise if it pogos |
| `suspensionCompression` | 4.0 | Spring response under load |
| `wheelRadius` | 0.33 m | Visual + physics |

Quick rules of thumb:
- *Understeers like a bus*: raise front friction, drop rear.
- *Spins on the throttle*: drop `maxEngineForce` or raise rear friction.
- *Pogos on bumps*: raise `suspensionDamping`.
- *Camera too jittery*: drop `damping` in `CameraRig` (default 5.0).

## Project layout

```
PolePosition/
├── PolePositionApp.swift            @main entry
├── App/
│   ├── AppState.swift               @Observable telemetry holder
│   ├── RootView.swift               SwiftUI root (scene + overlay)
│   └── GameLoopController.swift     SCNSceneRendererDelegate; per-frame update
├── Game/
│   ├── Engine/
│   │   └── InputManager.swift       Thread-safe keyboard state machine
│   ├── Physics/
│   │   ├── VehiclePhysics.swift     SCNPhysicsVehicle wrapper (well-commented)
│   │   └── PhysicsTuning.swift      Tunable constants
│   └── Rendering/
│       ├── SceneBuilder.swift       Initial scene (lights, floor, car)
│       └── CameraRig.swift          Smoothed chase camera
├── Vehicle/
│   ├── CarGeometry.swift            Primitive helpers (box, cylinder, wheel)
│   └── F1Car.swift                  Procedural low-poly open-wheeler
├── UI/
│   └── SceneContainerView.swift     SwiftUI ↔ SCNView bridge
└── Resources/
    └── PolePosition.entitlements    App sandbox
```

## Phase plan

1. **Driving feel** *(this phase)* — scene + car + physics + camera.
2. Monaco track, checkpoints, three-sector timing, HUD.
3. Ghost recordings, SwiftData persistence, up to 10 ghosts.
4. Track editor with snap grid and base64 export/import.
5. Eleven 2026 teams, liveries, driver/profile selection.
6. Remaining 11 official circuits.
7. F1 systems: DRS, ERS, tires, pit lane.
8. Modes: Practice → Qualifying (Q1/Q2/Q3) → Sprint → Race.
9. Polish: race control banners, flags, team radio (AVSpeechSynthesizer), procedural engine audio (AVAudioEngine), broadcast-style title cards.
10. Community: custom track gallery, share codes.

## Recovery

If `PolePosition.xcodeproj` won't open (parse error, missing references, etc.):

1. In Xcode: **File → New → Project → Multiplatform → App**.
2. Product Name: `PolePosition`. Interface: SwiftUI. Language: Swift. Storage: None.
3. Save it inside this repo, replacing the existing `PolePosition.xcodeproj`.
4. Delete Xcode's auto-generated `ContentView.swift` and `PolePositionApp.swift`.
5. Drag the `PolePosition/` source folder into the Project Navigator. Choose **Create groups**, **Add to target: PolePosition**.
6. Target settings → Signing & Capabilities → enable **App Sandbox** (already configured via the entitlements file).
7. ⌘R.

Takes about 60 seconds.

## License

MIT. Trademarks for F1, real teams, and real drivers belong to their respective rightsholders — see the spec in the issue tracker for the personal-use → fan-naming swap plan if shipping.
