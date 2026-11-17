import SwiftUI

/// How the file is shown, like Years / Months / All in Photos.
enum ViewMode: String, CaseIterable, Identifiable {
    /// The whole repository. Comes in a later step.
    case project
    /// The raw file, as in Safari.
    case file
    /// Each top-level definition as a card.
    case symbols

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .project: "Project"
        case .file: "File"
        case .symbols: "Symbols"
        }
    }
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
