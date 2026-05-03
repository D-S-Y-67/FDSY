import SwiftUI

@main
struct PolePositionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 960, minHeight: 600)
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
