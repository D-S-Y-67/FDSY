import SwiftUI

/// Root view. Hosts the SceneKit container with the HUD overlaid on top.
/// All gameplay state flows through `AppState.snapshot` which the HUD
/// reads and the game loop writes.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            SceneContainerView()
                .ignoresSafeArea()

            HUDView(snapshot: appState.snapshot)
        }
        #if os(macOS)
        .background(Color.black)
        #endif
    }
}
