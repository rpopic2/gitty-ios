import SwiftUI

@main
struct GittyApp: App {
    init() {
        CodeTextStyle.registerBundledFonts()  // JetBrains Mono, for the code font option
        _ = NetworkCost.shared  // watching the network from the start, so it's known when asked
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()  // has its own NavigationStack (project folders, symbol pages)
                .task { await CloneStore.shared.restoreAllFiles() }  // clones of filtered files only, from before
        }
    }
}
