import SwiftUI
import UIKit

/// The review being written: one plain text, like an email draft. Comment adds to the end of it.
/// It's kept across launches until it's shared or deleted.
@Observable
final class ReviewDraft {
    var text: String {
        didSet { defaults.set(text, forKey: Self.textKey) }
    }
    /// How many comments were added, for the docked bar.
    private(set) var commentCount: Int {
        didSet { defaults.set(commentCount, forKey: Self.countKey) }
    }
    /// The composer sheet is up. Swiping it down sets the draft aside (docked above the bar).
    var isComposing = false
    /// It's up over a sheet (a file's info, commenting on a diff), which presents it itself:
    /// the screen under that sheet can't.
    private(set) var composesOverSheet = false

    /// For the screen's own `sheet(isPresented:)`.
    var isComposingOnScreen: Bool {
        get { isComposing && !composesOverSheet }
        set { if !newValue { isComposing = false } }
    }

    /// For a sheet's `sheet(isPresented:)` (see `composesOverSheet`).
    var isComposingOverSheet: Bool {
        get { isComposing && composesOverSheet }
        set {
            if !newValue {
                isComposing = false
                composesOverSheet = false
            }
        }
    }
    /// Changes whenever the cursor should go to the end of the text (a comment was added).
    private(set) var cursorRequest = UUID()

    @ObservationIgnored private let defaults: UserDefaults
    private static let textKey = "reviewDraft"
    private static let countKey = "reviewCommentCount"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        text = defaults.string(forKey: Self.textKey) ?? ""
        commentCount = defaults.integer(forKey: Self.countKey)
    }

    var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Adds a comment on `selection` at the end and opens the composer, cursor ready.
    /// - Parameter repository: its first comment on the repository adds its heading.
    func add(_ selection: ReviewSelection, format: ReviewFormat, repository: ReviewRepository? = nil) {
        add(block: ReviewText.block(for: selection, format: format), format: format, repository: repository,
            overSheet: false)
    }

    /// A comment on lines of a diff, from the file info sheet.
    func add(_ selection: ReviewDiffSelection, format: ReviewFormat, repository: ReviewRepository?) {
        add(block: ReviewText.block(for: selection, format: format), format: format, repository: repository,
            overSheet: true)
    }

    private func add(block: String, format: ReviewFormat, repository: ReviewRepository?, overSheet: Bool) {
        if !hasDraft { commentCount = 0 }
        text = ReviewText.appending(block, to: text, format: format, repository: repository)
        commentCount += 1
        cursorRequest = UUID()
        composesOverSheet = overSheet
        isComposing = true
    }

    /// Brings a set-aside draft back.
    /// - Parameter overSheet: from a screen presented over the app (a full-screen diff), which
    ///   shows the composer itself (see `composesOverSheet`).
    func resume(overSheet: Bool = false) {
        cursorRequest = UUID()
        composesOverSheet = overSheet
        isComposing = true
    }

    /// The draft is set aside: its dock shows.
    var isDocked: Bool { hasDraft && !isComposing }

    /// After sharing, or Delete Review.
    func clear() {
        text = ""
        commentCount = 0
        isComposing = false
        composesOverSheet = false
    }
}

/// The review, as a sheet like Mail's compose window: write freely, Share when done (which
/// clears it), or swipe down to set it aside and pick it up again from the bar.
struct ReviewComposer: View {
    let draft: ReviewDraft

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingClose = false

    var body: some View {
        @Bindable var draft = draft
        NavigationStack {
            ReviewTextView(text: $draft.text, cursorRequest: draft.cursorRequest)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { isConfirmingClose = true }
                            .confirmationDialog("Close the review?", isPresented: $isConfirmingClose,
                                                titleVisibility: .hidden) {
                                Button("Delete Review", role: .destructive) { draft.clear() }
                                Button("Save Review") { dismiss() }
                            }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Share", systemImage: "square.and.arrow.up") { share() }
                            .disabled(!draft.hasDraft)
                    }
                }
        }
    }

    /// The share sheet with the raw text. Once it's shared (not cancelled), the review is done.
    private func share() {
        let draft = draft
        TextSharer.share(draft.text) { completed in
            if completed { draft.clear() }
        }
    }
}

/// The docked review above the bottom bar (or a full-screen card's caption), like a minimized
/// Mail draft. Tap to bring it back.
struct ReviewDock: View {
    let draft: ReviewDraft
    /// On a screen over the app, which shows the composer itself.
    var overSheet = false

    /// Its height on screen, with the space above it.
    static let height: CGFloat = 44
    static let reservedHeight: CGFloat = height + 8

    var body: some View {
        Button { draft.resume(overSheet: overSheet) } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Review")
                    .font(.subheadline.weight(.semibold))
                Text("^[\(draft.commentCount) comment](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(DockBackground())
        .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
        // Space above it (inside the bar's material on iOS 18); below, the bar's own space
        // above its field keeps the same gap.
        .padding(.top, 8)
        .accessibilityHint("Opens the review")
    }
}

/// Glass on iOS 26, a bar-material capsule before.
private struct DockBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.bar, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

/// An editable text view for the review. Monospaced, since comments sit next to code, with
/// smart quotes and dashes off so code stays code.
private struct ReviewTextView: UIViewRepresentable {
    @Binding var text: String
    let cursorRequest: UUID

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.autocapitalizationType = .sentences
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.delegate = context.coordinator
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        if textView.text != text { textView.text = text }
        guard context.coordinator.cursorRequest != cursorRequest else { return }
        context.coordinator.cursorRequest = cursorRequest
        // After the sheet has appeared: the cursor at the end, scrolled into view, keyboard up.
        DispatchQueue.main.async {
            let end = (textView.text as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
            textView.becomeFirstResponder()
            textView.scrollRangeToVisible(textView.selectedRange)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var cursorRequest: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

/// The system share sheet for plain text, presented over whatever is on screen.
@MainActor
enum TextSharer {
    /// - Parameter completion: `true` once it was shared (or copied), `false` if cancelled.
    static func share(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let top = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in completion(completed) }
        }
        if let popover = controller.popoverPresentationController {
            // iPad: point at the top trailing corner, where the Share button is.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.maxX - 40, y: top.view.safeAreaInsets.top + 22,
                                        width: 1, height: 1)
            popover.permittedArrowDirections = .up
        }
        top.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
