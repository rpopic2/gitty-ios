import SwiftUI
import UIKit

/// One file, full screen, with a Safari-style bar at the bottom.
struct CodeScreen: View {
    @State private var model: CodeDocumentModel

    init(url: URL, store: DocumentStore = .shared) {
        _model = State(initialValue: CodeDocumentModel(url: url, store: store))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            FileBar(
                title: model.fileName,
                isCollapsed: model.isBarCollapsed,
                progressFraction: model.progressFraction,
                isProgressVisible: model.isProgressVisible,
                onExpand: { model.expandBarFromTap() }
            )
        }
        .overlay(alignment: .top) { StatusBarBackdrop() }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .alert("Couldn’t Refresh", isPresented: refreshAlertIsPresented, presenting: model.refreshError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            // A blank page while the progress line runs, as in Safari.
            Color(uiColor: RawTextStyle.backgroundColor)
                .ignoresSafeArea()
        case .loaded(let text, let version):
            CodeTextView(
                text: text,
                version: version,
                documentURL: model.url,
                bottomBarHeight: FileBarMetrics.expandedHeight,
                isBarCollapsed: model.isBarCollapsed,
                barTapCount: model.barTapCount,
                onRefresh: { await model.refresh() },
                onBarCollapsedChange: { model.setBarCollapsed($0) }
            )
            .ignoresSafeArea()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load File", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.retry() } }
            }
        }
    }

    private var refreshAlertIsPresented: Binding<Bool> {
        Binding(
            get: { model.refreshError != nil },
            set: { if !$0 { model.refreshError = nil } }
        )
    }
}

/// iOS 18 Safari tints the status bar area with bar material. iOS 26 uses the text view's
/// scroll edge effect instead (see `CodeTextView`).
private struct StatusBarBackdrop: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            EmptyView()
        } else {
            Color.clear
                .frame(height: 0)
                .background(.bar, ignoresSafeAreaEdges: .top)
        }
    }
}
