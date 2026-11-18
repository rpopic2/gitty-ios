import SwiftUI
import UIKit

/// One symbol at a time, full screen, like a photo opened in Photos.
/// Swipe left/right for the previous/next symbol. Swipe down to zoom back to the list
/// (the zoom navigation transition provides that gesture).
struct SymbolPager: View {
    let symbols: [CodeSymbol]
    /// The symbol that was tapped. The pager opens on it.
    let initialID: Int
    /// The symbol on screen. Reported only after the pager has opened on `initialID`.
    @Binding var currentID: Int?
    let text: @MainActor (CodeSymbol) -> NSAttributedString?
    /// Called with the symbol on screen when the pager starts to close (the swipe down begins).
    let onWillClose: @MainActor (Int) -> Void
    /// Tapping the caption: close the pager and show the symbol in File.
    let onShowInFile: @MainActor (CodeSymbol) -> Void
    /// Jump to Definition in a page's text menu: close the pager and search symbols.
    let symbolSearchTerm: @MainActor (String) -> String?
    let onSearchSymbols: @MainActor (String) -> Void

    @State private var scrolledID: Int?
    @State private var isPositioned = false
    /// Swiping from the right edge pages here, so it doesn't open the sidebar.
    @Environment(SideBarState.self) private var sideBar: SideBarState?

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(symbols: [CodeSymbol], initialID: Int, currentID: Binding<Int?>,
         text: @escaping @MainActor (CodeSymbol) -> NSAttributedString?,
         onWillClose: @escaping @MainActor (Int) -> Void,
         onShowInFile: @escaping @MainActor (CodeSymbol) -> Void,
         symbolSearchTerm: @escaping @MainActor (String) -> String?,
         onSearchSymbols: @escaping @MainActor (String) -> Void) {
        self.symbols = symbols
        self.initialID = initialID
        _currentID = currentID
        self.text = text
        self.onWillClose = onWillClose
        self.onShowInFile = onShowInFile
        self.symbolSearchTerm = symbolSearchTerm
        self.onSearchSymbols = onSearchSymbols
    }

    private var visibleID: Int { scrolledID ?? initialID }

    private var current: CodeSymbol? {
        symbols.first { $0.id == visibleID }
    }

    var body: some View {
        // Pages sit inside a scroll view, where UIKit gives them no safe-area insets. Read the
        // screen's safe area here and hand it to each page.
        GeometryReader { proxy in
            let safeArea = proxy.safeAreaInsets
            let pageInsets = EdgeInsets(
                top: safeArea.top,
                leading: safeArea.leading,
                bottom: safeArea.bottom + SymbolCaption.reservedHeight,
                trailing: safeArea.trailing
            )
            ZStack(alignment: .bottom) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(symbols) { symbol in
                                ReadOnlyTextView(
                                    text: text(symbol) ?? NSAttributedString(),
                                    textID: symbol.id,
                                    insets: pageInsets,
                                    isCurrent: symbol.id == visibleID,
                                    symbolSearchTerm: symbolSearchTerm,
                                    onSearchSymbols: onSearchSymbols
                                )
                                .containerRelativeFrame([.horizontal, .vertical])
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $scrolledID)
                    .scrollIndicators(.hidden)
                    .background(Color(uiColor: RawTextStyle.backgroundColor))
                    .ignoresSafeArea()
                    .onAppear {
                        // `scrollPosition(id:)` ignores a starting value during the first layout and
                        // opens on the first page. Move to the tapped symbol explicitly.
                        reader.scrollTo(initialID, anchor: .leading)
                        scrolledID = initialID
                        isPositioned = true
                    }
                }

                if let current {
                    SymbolCaption(symbol: current, onShowInFile: { onShowInFile(current) })
                        .padding(.bottom, 8)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { sideBar?.isEdgeSwipeEnabled = false }
        .onDisappear { sideBar?.isEdgeSwipeEnabled = true }
        .background(WillDisappearObserver { onWillClose(visibleID) })
        .onChange(of: scrolledID) { _, id in
            // Until the pager is on the tapped symbol, don't let the first layout overwrite it.
            guard isPositioned, let id else { return }
            currentID = id
        }
    }
}

/// Reports when the screen it's on starts to go away. For the zoom transition that's the moment
/// the swipe down begins. It's also called if the swipe is then cancelled, which is harmless here.
/// SwiftUI has no hook for this, so it uses a UIKit view controller's `viewWillDisappear`.
private struct WillDisappearObserver: UIViewControllerRepresentable {
    let onWillDisappear: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onWillDisappear = onWillDisappear
    }

    final class Controller: UIViewController {
        var onWillDisappear: (@MainActor () -> Void)?

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onWillDisappear?()
        }
    }
}

/// "name · Line N" in a small capsule at the bottom, in place of the bar and selector.
/// Tapping it shows the symbol in File.
private struct SymbolCaption: View {
    let symbol: CodeSymbol
    let onShowInFile: @MainActor () -> Void

    static let height: CGFloat = 36
    /// Space kept free under the text so its end isn't hidden behind the caption.
    static let reservedHeight: CGFloat = height + 16

    var body: some View {
        Button(action: onShowInFile) {
            capsule
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows this symbol in File"))
    }

    @ViewBuilder
    private var capsule: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbol.kind.systemImage)
                .foregroundStyle(.tint)
            Text(symbol.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("· Line \(symbol.line)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .contentShape(Capsule())

        if #available(iOS 26.0, *) {
            label.glassEffect(.regular.interactive(), in: Capsule())
                .padding(.horizontal, 24)
        } else {
            label.background(.bar, in: Capsule())
                .padding(.horizontal, 24)
        }
    }
}

/// A read-only raw-text view for one symbol: the same Safari style as the file.
struct ReadOnlyTextView: UIViewRepresentable {
    let text: NSAttributedString
    /// Text is replaced only when this changes.
    let textID: Int
    /// Safe area (plus room for the caption at the bottom) to keep the text clear of.
    let insets: EdgeInsets
    /// Only the page on screen answers a tap on the status bar.
    let isCurrent: Bool
    /// Jump to Definition in the text menu (see `CodeTextView`).
    var symbolSearchTerm: (@MainActor (String) -> String?)? = nil
    var onSearchSymbols: (@MainActor (String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        RawTextStyle.configure(textView)
        textView.contentInsetAdjustmentBehavior = .never  // insets come from `insets` instead
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.scrollsToTop = isCurrent
        context.coordinator.symbolSearchTerm = symbolSearchTerm
        context.coordinator.onSearchSymbols = onSearchSymbols

        let contentInset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        if textView.contentInset != contentInset {
            textView.contentInset = contentInset
            textView.verticalScrollIndicatorInsets = contentInset
        }
        // Sideways, keep the text clear of the notch in landscape.
        let base = RawTextStyle.insets
        let containerInset = UIEdgeInsets(top: base.top, left: base.left + insets.leading,
                                          bottom: base.bottom, right: base.right + insets.trailing)
        if textView.textContainerInset != containerInset {
            textView.textContainerInset = containerInset
        }

        guard context.coordinator.textID != textID else { return }
        context.coordinator.textID = textID
        textView.attributedText = text
        textView.contentOffset.y = -contentInset.top
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var textID: Int?
        var symbolSearchTerm: (@MainActor (String) -> String?)?
        var onSearchSymbols: (@MainActor (String) -> Void)?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let extra = RawTextStyle.jumpToDefinitionItems(for: range, in: textView,
                                                           searchTerm: symbolSearchTerm,
                                                           onSearch: onSearchSymbols)
            return RawTextStyle.editMenu(from: suggestedActions, adding: extra)
        }
    }
}
