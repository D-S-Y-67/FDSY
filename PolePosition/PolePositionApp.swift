import SwiftUI

@main
struct PolePositionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 960, idealWidth: 1280,
                       minHeight: 600, idealHeight: 800)
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }
}
