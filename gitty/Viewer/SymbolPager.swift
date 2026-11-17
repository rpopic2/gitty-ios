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
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(symbols) { symbol in
                        ReadOnlyTextView(
                            text: text(symbol) ?? NSAttributedString(),
                            textID: symbol.id,
                            bottomInset: SymbolCaption.reservedHeight,
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
    let bottomInset: CGFloat
    /// Only the page on screen answers a tap on the status bar.
    let isCurrent: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        RawTextStyle.configure(textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.scrollsToTop = isCurrent
        if textView.contentInset.bottom != bottomInset {
            textView.contentInset.bottom = bottomInset
            textView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
        guard context.coordinator.textID != textID else { return }
        context.coordinator.textID = textID
        textView.attributedText = text
        textView.contentOffset.y = -textView.adjustedContentInset.top
    }

    final class Coordinator {
        var textID: Int?
    }
}
