import SwiftUI

@main
struct GittyApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CodeScreen(url: Sources.step1)
            }
        }
    }
}
