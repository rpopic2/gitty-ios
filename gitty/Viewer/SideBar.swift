import SwiftUI
import UIKit

/// The right sidebar's state: how far it's pulled out. Shared through the environment so a
/// screen can turn the edge swipe off (a symbol's page uses that swipe to page).
@Observable
final class SideBarState {
    /// How much of the sidebar shows, 0 (closed) to `width` (open). It changes on every frame
    /// of a swipe: only the offsets read it (`SideBarSlide`), so nothing else redraws.
    var reveal: CGFloat = 0 {
        didSet {
            let isOpen = reveal > 0
            if isOpen != self.isOpen { self.isOpen = isOpen }
        }
    }
    var width: CGFloat = 320
    /// The swipe from the right edge opens it. Off while a screen needs that swipe.
    var isEdgeSwipeEnabled = true

    /// Any of it shows. Stored, not worked out from `reveal`, so reading it only redraws when
    /// it flips, not on every frame of a swipe.
    private(set) var isOpen = false

    func open() {
        withAnimation(Self.animation) { reveal = width }
    }

    func close() {
        withAnimation(Self.animation) { reveal = 0 }
    }

    /// Ends a drag: open or close, whichever the finger was heading for.
    /// - Parameter velocity: points per second, positive toward opening (leftward).
    func settle(velocity: CGFloat) {
        let opens = velocity > 400 || (velocity > -400 && reveal > width / 2)
        opens ? open() : close()
    }

    /// Follows the finger while dragging.
    func track(_ value: CGFloat) {
        reveal = min(max(value, 0), width)
    }

    private static let animation = Animation.smooth(duration: 0.3)
}

/// The app's content with the sidebar to its right, as wide as the screen. Swiping left from the
/// right edge of the screen pushes the content off and pulls the sidebar in, following the
/// finger; swiping right on the sidebar puts it back the same way.
struct SideBarContainer<Content: View, SideBar: View>: View {
    let state: SideBarState
    let content: () -> Content
    let sideBar: () -> SideBar

    init(state: SideBarState, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder sideBar: @escaping () -> SideBar) {
        self.state = state
        self.content = content
        self.sideBar = sideBar
    }

    // This body reads none of `state`: if it did, it would run again when that changes (on
    // every frame of a swipe, for `reveal`) and build the whole app's views again each time.
    // Small modifiers read it instead (`SideBarSlide`, `SideBarDim`), and SwiftUI redraws
    // just them.
    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .overlay { SideBarDim(state: state) }
                .modifier(SideBarSlide(state: state, isSideBar: false))
                .accessibilityAction(named: "Show Projects") { state.open() }

            // Built ahead of time, off screen, so the first frame of a swipe doesn't have to
            // build its list.
            sideBar()
                .modifier(SideBarSlide(state: state, isSideBar: true))
                .accessibilityAction(.escape) { state.close() }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            state.width = width
            if state.isOpen { state.reveal = width }
        }
        .background(ScreenEdgePan(state: state))
    }

}

/// Moves the content (left) or the sidebar (in from the right) with `reveal`, and leaves
/// touches and VoiceOver to whichever shows. As a modifier, its body is all that runs again
/// while the finger moves: the views it moves aren't rebuilt.
private struct SideBarSlide: ViewModifier {
    let state: SideBarState
    let isSideBar: Bool

    func body(content: Content) -> some View {
        if isSideBar {
            content
                .frame(width: state.width)
                .offset(x: state.width - state.reveal)
                .allowsHitTesting(state.isOpen)
                .accessibilityHidden(!state.isOpen)
        } else {
            content
                .offset(x: -state.reveal)
                .accessibilityHidden(state.isOpen)
        }
    }
}

/// The content still showing while the sidebar slides: dimmed, and a tap puts it back.
/// (Swiping right is the window's pan, in `ScreenEdgePan`.)
private struct SideBarDim: View {
    let state: SideBarState

    var body: some View {
        Color.black
            .opacity(0.15 * state.reveal / max(state.width, 1))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { state.close() }
            .allowsHitTesting(state.isOpen)
    }
}

/// The sidebar's swipes, on the whole window: UIKit's screen-edge swipe from the right edge opens
/// it, and a swipe to the right anywhere closes it while it's open. They're attached to the
/// window (not to a view in front of the content), so they don't take touches from anything,
/// and scroll views wait for them to fail before they start scrolling. Neither starts for a
/// vertical swipe, so the sidebar's list scrolls as usual.
private struct ScreenEdgePan: UIViewRepresentable {
    let state: SideBarState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.recognizers = [context.coordinator.openRecognizer, context.coordinator.closeRecognizer]
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.state = state
    }

    /// Adds the recognizers to whichever window it's in.
    final class InstallerView: UIView {
        var recognizers: [UIGestureRecognizer] = []

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            for recognizer in recognizers {
                recognizer.view?.removeGestureRecognizer(recognizer)
                newWindow?.addGestureRecognizer(recognizer)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var state: SideBarState?
        let openRecognizer = UIScreenEdgePanGestureRecognizer()
        let closeRecognizer = UIPanGestureRecognizer()

        override init() {
            super.init()
            openRecognizer.edges = .right
            openRecognizer.addTarget(self, action: #selector(openPan(_:)))
            openRecognizer.delegate = self
            closeRecognizer.addTarget(self, action: #selector(closePan(_:)))
            closeRecognizer.delegate = self
        }

        @objc private func openPan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let state, let view = recognizer.view else { return }
            switch recognizer.state {
            case .changed:
                state.track(-recognizer.translation(in: view).x)
            case .ended:
                state.settle(velocity: -recognizer.velocity(in: view).x)
            case .cancelled, .failed:
                state.close()
            default:
                break
            }
        }

        @objc private func closePan(_ recognizer: UIPanGestureRecognizer) {
            guard let state, let view = recognizer.view else { return }
            switch recognizer.state {
            case .changed:
                state.track(state.width - max(recognizer.translation(in: view).x, 0))
            case .ended:
                state.settle(velocity: -recognizer.velocity(in: view).x)
            case .cancelled, .failed:
                state.open()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let state else { return false }
            guard gestureRecognizer === closeRecognizer else {
                return state.isEdgeSwipeEnabled && !state.isOpen
            }
            // Only for the sidebar itself: not for a sheet over it (Settings).
            guard state.isOpen, let window = closeRecognizer.view as? UIWindow,
                  window.rootViewController?.presentedViewController == nil
            else { return false }
            let velocity = closeRecognizer.velocity(in: window)
            return velocity.x > 0 && velocity.x > abs(velocity.y)  // mostly rightward
        }

        /// Scrolling (the file, the lists) waits until the touch is known not to be a sidebar
        /// swipe, which UIKit decides within a few points. (A row's swipe to delete is leftward,
        /// so it never closes the sidebar.)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other !== openRecognizer && other !== closeRecognizer
        }
    }
}

/// The sidebar: Files, then your projects, the code font, and Settings at the bottom. Choosing
/// Files or a project shows it in the Project tab.
struct SideBarView: View {
    /// The open project's id, or "" for Files.
    let selectedID: String
    let onSelect: @MainActor (String) -> Void
    let onDelete: @MainActor (String) -> Void
    let onSettings: @MainActor () -> Void

    @State private var projects: [ProjectInfo] = []
    /// The code font and its size, for pages and the symbol levels.
    @AppStorage(CodeTextStyle.fontKey) private var codeFont: CodeFont = .courier
    @AppStorage(CodeTextStyle.sizeKey) private var codeFontSize = Double(CodeTextStyle.defaultSize)
    /// Whether it shows: it's built ahead of time, and loads the projects each time it opens.
    @Environment(SideBarState.self) private var state: SideBarState?

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(selectedID: String, onSelect: @escaping @MainActor (String) -> Void,
         onDelete: @escaping @MainActor (String) -> Void, onSettings: @escaping @MainActor () -> Void) {
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onSettings = onSettings
    }

    var body: some View {
        List {
            Section {
                item(id: "") {
                    Label("Files", systemImage: "doc.on.doc")
                }
            }
            Section {
                ForEach(projects) { project in
                    item(id: project.id) {
                        SideBarProjectRow(project: project)
                    }
                    .swipeActions {
                        Button(role: .destructive) { delete(project) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                if projects.isEmpty {
                    Text("To add a project, enter a GitHub repository link in the bar.")
                }
            }
            Section("Code Font") {
                Picker("Font", selection: $codeFont) {
                    ForEach(CodeFont.allCases, id: \.self) { font in
                        Text(font.title).tag(font)
                    }
                }
                Stepper(value: $codeFontSize, in: CodeTextStyle.sizes, step: 1) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(codeFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // How code looks in the chosen font and size.
                Text(verbatim: "int main(void) { return 0; }")
                    .font(CodeTextStyle(font: codeFont, size: CGFloat(codeFontSize)).swiftUIFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityHidden(true)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsButton }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDisabled(!(state?.isOpen ?? true))  // off screen: leaves status-bar taps alone
        .task(id: state?.isOpen ?? true) {  // each time it opens
            if state?.isOpen ?? true { projects = await ProjectStore.shared.projects() }
        }
    }

    /// A row that's tapped to choose it, gray while it's the open one.
    private func item<RowLabel: View>(id: String, @ViewBuilder label: () -> RowLabel) -> some View {
        let isSelected = id == selectedID
        return Button { onSelect(id) } label: {
            label()
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .listRowBackground(isSelected
            ? Color(uiColor: .systemGray4)
            : Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var settingsButton: some View {
        Button { onSettings() } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Removes the project from the list. Its saved files stay on the device.
    private func delete(_ project: ProjectInfo) {
        projects.removeAll { $0.id == project.id }
        ProjectFilterStore.standard.remove(for: project.id)
        onDelete(project.id)
        Task { await ProjectStore.shared.remove(id: project.id) }
    }
}

/// A project: its name, then owner · branch (and folder).
private struct SideBarProjectRow: View {
    let project: ProjectInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .lineLimit(1)
                Text([project.link.owner, project.ref].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "shippingbox")
                .foregroundStyle(.tint)
        }
    }
}
