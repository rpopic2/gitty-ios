import SwiftUI
import UIKit

/// One symbol at a time, full screen, like a photo opened in Photos.
/// Swipe left/right for the previous/next symbol. Swipe down to zoom back to the list
/// (the zoom navigation transition provides that gesture).
struct SymbolPager: View {
    let symbols: [CodeSymbol]
    @Binding var currentID: Int?
    let text: @MainActor (CodeSymbol) -> NSAttributedString?

    private var current: CodeSymbol? {
        symbols.first { $0.id == currentID }
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
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(symbols) { symbol in
                            ReadOnlyTextView(
                                text: text(symbol) ?? NSAttributedString(),
                                textID: symbol.id,
                                insets: pageInsets,
                                isCurrent: symbol.id == currentID
                            )
                            .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                .background(Color(uiColor: RawTextStyle.backgroundColor))
                .ignoresSafeArea()

                if let current {
                    SymbolCaption(symbol: current)
                        .padding(.bottom, 8)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// "name · Line N" in a small capsule at the bottom, in place of the bar and selector.
private struct SymbolCaption: View {
    let symbol: CodeSymbol

    static let height: CGFloat = 36
    /// Space kept free under the text so its end isn't hidden behind the caption.
    static let reservedHeight: CGFloat = height + 16

    var body: some View {
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
        .padding(.horizontal, 24)

        if #available(iOS 26.0, *) {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label.background(.bar, in: Capsule())
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

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            RawTextStyle.editMenu(from: suggestedActions)
        }
    }
}
