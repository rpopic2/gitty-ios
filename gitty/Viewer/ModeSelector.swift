import SwiftUI

/// The levels, like Photos' Years and All: the project's files, and its code as an outline.
/// The selector under the bar switches between them.
enum ViewMode: String, CaseIterable, Identifiable {
    /// The open project's files (chosen in the sidebar), or Files.
    case project
    /// Every symbol's whole code, edge to edge.
    case code

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .project: "Project"
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
