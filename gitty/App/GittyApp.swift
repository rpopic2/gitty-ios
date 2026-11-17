import SwiftUI

@main
struct GittyApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()  // has its own NavigationStack (project folders, symbol pages)
        }
    }
}
