import SwiftUI
import SceneKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SwiftUI bridge to `SCNView`. Owns the `InputManager` and the
/// `GameLoopController` (held via Coordinator), builds the scene once.
///
/// Phase 1 input wiring:
///   - macOS: subclass SCNView, override keyDown/keyUp.
///   - iOS  : stub. Touch + MFi controllers come in a later phase.

#if os(macOS)
struct SceneContainerView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    final class Coordinator {
        let input = InputManager()
        var loop: GameLoopController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyboardSCNView {
        let built = SceneBuilder.build()

        let view = KeyboardSCNView(frame: .zero)
        view.scene = built.scene
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.pointOfView = built.cameraRig.node
        view.input = context.coordinator.input

        let loop = GameLoopController(
            input: context.coordinator.input,
            vehicle: built.vehicle,
            cameraRig: built.cameraRig,
            appState: appState
        )
        context.coordinator.loop = loop
        view.delegate = loop
        view.isPlaying = true
        return view
    }

    func updateNSView(_ nsView: KeyboardSCNView, context: Context) {}
}

/// SCNView subclass that captures keyboard events. Standard pattern: become
/// first responder when added to a window, route key events through
/// `InputManager`.
final class KeyboardSCNView: SCNView {
    weak var input: InputManager?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Defer to next runloop tick so the window's first-responder state
        // is settled before we ask for it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        if let key = InputManager.keyForMacKeyCode(event.keyCode) {
            input?.keyDown(key)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let key = InputManager.keyForMacKeyCode(event.keyCode) {
            input?.keyUp(key)
            return
        }
        super.keyUp(with: event)
    }

    @objc private func windowResignedKey() {
        // User alt-tabbed away — don't keep "driving" until they return.
        input?.clear()
    }
}

#else // iOS / iPadOS — Phase 1 stub: render the scene, no input yet.
struct SceneContainerView: UIViewRepresentable {
    @Environment(AppState.self) private var appState

    final class Coordinator {
        let input = InputManager()
        var loop: GameLoopController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let built = SceneBuilder.build()

        let view = SCNView(frame: .zero)
        view.scene = built.scene
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.pointOfView = built.cameraRig.node

        let loop = GameLoopController(
            input: context.coordinator.input,
            vehicle: built.vehicle,
            cameraRig: built.cameraRig,
            appState: appState
        )
        context.coordinator.loop = loop
        view.delegate = loop
        view.isPlaying = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
#endif
