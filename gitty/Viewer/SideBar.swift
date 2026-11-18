import SwiftUI
import UIKit

/// The right sidebar's state: how far it's pulled out. Shared through the environment so a
/// screen can turn the edge swipe off (a symbol's page uses that swipe to page).
@Observable
final class SideBarState {
    /// How much of the sidebar shows, 0 (closed) to `width` (open).
    var reveal: CGFloat = 0
    var width: CGFloat = 320
    /// The swipe from the right edge opens it. Off while a screen needs that swipe.
    var isEdgeSwipeEnabled = true

    var isOpen: Bool { reveal > 0 }

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

/// The app's content with the sidebar to its right. Swiping left from the right edge of the
/// screen pushes the content aside and pulls the sidebar in, following the finger. Tapping or
/// swiping right on the content that's still showing puts it back.
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .overlay { if state.isOpen { closeArea } }
                .offset(x: -state.reveal)
                .accessibilityHidden(state.isOpen)
                .accessibilityAction(named: "Show Projects") { state.open() }

            // Built only while it shows: nothing to keep up to date while it's closed.
            if state.isOpen {
                sideBar()
                    .frame(width: state.width)
                    .offset(x: state.width - state.reveal)
                    .accessibilityAction(.escape) { state.close() }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            min(340, (proxy.size.width * 0.82).rounded())
        } action: { width in
            state.width = width
            if state.isOpen { state.reveal = width }
        }
        .background(ScreenEdgePan(state: state))
    }

    /// The content that still shows beside the open sidebar: dimmed, tap or swipe right to close.
    private var closeArea: some View {
        Color.black
            .opacity(0.15 * state.reveal / max(state.width, 1))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { state.close() }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag in state.track(state.width - max(drag.translation.width, 0)) }
                    .onEnded { drag in state.settle(velocity: -drag.velocity.width) }
            )
    }
}

/// UIKit's screen-edge swipe, from the right edge, on the whole window. It's attached to the
/// window (not to a view in front of the content), so it doesn't take touches from anything,
/// and scroll views wait for it to fail before they start scrolling.
private struct ScreenEdgePan: UIViewRepresentable {
    let state: SideBarState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.recognizer = context.coordinator.recognizer
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.state = state
    }

    /// Adds the recognizer to whichever window it's in.
    final class InstallerView: UIView {
        var recognizer: UIGestureRecognizer?

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard let recognizer else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var state: SideBarState?
        let recognizer = UIScreenEdgePanGestureRecognizer()

        override init() {
            super.init()
            recognizer.edges = .right
            recognizer.addTarget(self, action: #selector(pan(_:)))
            recognizer.delegate = self
        }

        @objc private func pan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
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

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let state else { return false }
            return state.isEdgeSwipeEnabled && !state.isOpen
        }

        /// Scrolling (the file, the lists) waits until the touch is known not to be an edge
        /// swipe, which UIKit decides within a few points.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && !(other is UIScreenEdgePanGestureRecognizer)
        }
    }
}

/// The sidebar: Files, then your projects, and Settings at the bottom. Choosing one shows it in
/// the Project tab.
struct SideBarView: View {
    /// The open project's id, or "" for Files.
    let selectedID: String
    let onSelect: @MainActor (String) -> Void
    let onDelete: @MainActor (String) -> Void
    let onSettings: @MainActor () -> Void

    @State private var projects: [ProjectInfo] = []

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
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsButton }
        .background(Color(uiColor: .systemGroupedBackground))
        .task { projects = await ProjectStore.shared.projects() }  // each time it opens
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
