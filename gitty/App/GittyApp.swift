import SwiftUI

@main
struct GittyApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CodeTextStyle.registerBundledFonts()  // JetBrains Mono, for the code font option
        _ = NetworkCost.shared  // watching the network from the start, so it's known when asked
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()  // has its own NavigationStack (project folders, symbol pages)
                .task { await CloneStore.shared.restoreAllFiles() }  // clones of filtered files only, from before
                // What's been read of a project's symbols, before the app may be closed.
                .onChange(of: scenePhase) { old, phase in
                    if phase == .background { Task { await ProjectSymbolIndex.shared.saveIndex() } }
                    // Back in the app: local folders read again (edited elsewhere meanwhile), and
                    // the Code level follows the ones that changed.
                    if phase == .active, old != .active {  // on a Mac, often just inactive
                        Task {
                            for projectID in await CloneStore.shared.refreshLocalFolders() {
                                CloneChanges.shared.didPull(projectID)
                            }
                        }
                    }
                }
        }
    }
}
