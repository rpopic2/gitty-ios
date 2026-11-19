import SwiftUI

/// What the screen shows: the Code level, or Project (tapping the bar shows it, like Safari's
/// start page, with the search field).
enum ViewMode: String {
    /// The open project (chosen in the sidebar), or Files.
    case project
    /// Every symbol's whole code, edge to edge.
    case code

    /// The levels that show the symbols (all but Project).
    var showsSymbols: Bool { self != .project }
}
