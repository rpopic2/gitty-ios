import SwiftUI

/// The levels, out to in, like Years / Months / Days / All in Photos: the selector under the
/// bar switches between them.
enum ViewMode: String, CaseIterable, Identifiable {
    /// The open project's files (chosen in the sidebar), or Files.
    case project
    /// Symbols as one-line rows, grouped under a header per file.
    case files
    /// Each symbol (and file) as a card.
    case symbols
    /// Every symbol's whole code, edge to edge.
    case code

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .project: "Project"
        case .files: "Files"
        case .symbols: "Symbols"
        case .code: "Code"
        }
    }

    /// The levels that show the symbols (all but Project).
    var showsSymbols: Bool { self != .project }
}

/// The Photos-style segmented control under the bottom bar.
struct ModeSelector: View {
    @Binding var mode: ViewMode

    var body: some View {
        let picker = Picker("View", selection: $mode) {
            ForEach(ViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: FileBarMetrics.selectorMaxWidth)
        .frame(height: FileBarMetrics.selectorHeight)

        if #available(iOS 26.0, *) {
            // Photos 26 floats its selector on glass.
            picker
                .padding(4)
                .glassEffect(.regular, in: Capsule())
        } else {
            picker
        }
    }
}
