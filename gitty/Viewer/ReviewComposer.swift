import SwiftUI
import UIKit

/// A project's review: the one being written, and the last one shared.
nonisolated struct ProjectReview: Codable, Equatable, Sendable {
    var text = ""
    /// How many comments were added, for the docked bar.
    var commentCount = 0
    /// Closed with the composer's X: not docked above the bar, but still in the project view.
    var isPutAway = false
    var shared: SharedReview?

    var hasDraft: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A review as it was shared, kept in its project's view to read or share again.
nonisolated struct SharedReview: Codable, Equatable, Sendable, Identifiable {
    var id: Date { date }
    let text: String
    let commentCount: Int
    let date: Date
}

/// The reviews being written, one per project ("" for files outside projects), like email
/// drafts: Comment adds to the end of its project's. The composer and the dock show one
/// (`projectID`: the last commented on, or opened from its project). Kept across launches.
@MainActor @Observable
final class ReviewDraft {
    /// The review in the composer and the dock.
    private(set) var projectID: String {
        didSet { defaults.set(projectID, forKey: Self.projectKey) }
    }
    private var reviews: [String: ProjectReview] {
        didSet { save() }
    }

    var text: String {
        get { reviews[projectID]?.text ?? "" }
        set { reviews[projectID, default: ProjectReview()].text = newValue }
    }
    var commentCount: Int { reviews[projectID]?.commentCount ?? 0 }

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
    private static let reviewsKey = "projectReviews"
    private static let projectKey = "reviewProject"
    /// Before reviews were per project: one draft.
    private static let oldTextKey = "reviewDraft"
    private static let oldCountKey = "reviewCommentCount"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var reviews = defaults.data(forKey: Self.reviewsKey)
            .flatMap { try? JSONDecoder().decode([String: ProjectReview].self, from: $0) } ?? [:]
        if let old = defaults.string(forKey: Self.oldTextKey) {
            if !old.isEmpty {
                reviews["", default: ProjectReview()].text = old
                reviews["", default: ProjectReview()].commentCount = defaults.integer(forKey: Self.oldCountKey)
            }
            defaults.removeObject(forKey: Self.oldTextKey)
            defaults.removeObject(forKey: Self.oldCountKey)
        }
        self.reviews = reviews
        projectID = defaults.string(forKey: Self.projectKey) ?? ""
    }

    var hasDraft: Bool { reviews[projectID]?.hasDraft ?? false }

    /// A project's review, for its view.
    func review(for projectID: String) -> ProjectReview {
        reviews[projectID] ?? ProjectReview()
    }

    /// Adds a comment on `selection` at the end of its project's review and opens the
    /// composer, cursor ready.
    /// - Parameter repository: its first comment on the repository adds its heading.
    func add(_ selection: ReviewSelection, format: ReviewFormat, repository: ReviewRepository? = nil,
             projectID: String) {
        add(block: ReviewText.block(for: selection, format: format), format: format, repository: repository,
            projectID: projectID, overSheet: false)
    }

    /// A comment on a whole file or folder: just its path.
    func add(path: String, format: ReviewFormat, repository: ReviewRepository?, projectID: String) {
        add(block: ReviewText.block(forPath: path, format: format), format: format, repository: repository,
            projectID: projectID, overSheet: false)
    }

    /// A comment on lines of a diff: from the file info sheet (`overSheet`), or a diff album's
    /// card or page (on the screen itself).
    func add(_ selection: ReviewDiffSelection, format: ReviewFormat, repository: ReviewRepository?,
             projectID: String, overSheet: Bool = true) {
        add(block: ReviewText.block(for: selection, format: format), format: format, repository: repository,
            projectID: projectID, overSheet: overSheet)
    }

    private func add(block: String, format: ReviewFormat, repository: ReviewRepository?, projectID: String,
                     overSheet: Bool) {
        self.projectID = projectID
        var review = reviews[projectID] ?? ProjectReview()
        if !review.hasDraft { review.commentCount = 0 }
        review.text = ReviewText.appending(block, to: review.text, format: format, repository: repository)
        review.commentCount += 1
        review.isPutAway = false
        reviews[projectID] = review
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

    /// A project's review, from its view: it's the one in the composer and the dock now.
    func open(projectID: String) {
        self.projectID = projectID
        reviews[projectID, default: ProjectReview()].isPutAway = false
        resume()
    }

    /// The draft is set aside: its dock shows (unless it was closed with the X).
    var isDocked: Bool { hasDraft && !isComposing && !(reviews[projectID]?.isPutAway ?? false) }

    /// The composer's X: it closes, and the dock goes; the review stays in its project's view.
    func putAway() {
        reviews[projectID, default: ProjectReview()].isPutAway = true
        isComposing = false
        composesOverSheet = false
    }

    /// Shared: it becomes the project's last shared review, and the next comment starts a new one.
    func didShare() {
        var review = reviews[projectID] ?? ProjectReview()
        review.shared = SharedReview(text: review.text, commentCount: review.commentCount, date: .now)
        review.text = ""
        review.commentCount = 0
        review.isPutAway = false
        reviews[projectID] = review
        isComposing = false
        composesOverSheet = false
    }

    /// Deletes a project's review in progress (from its view).
    func delete(projectID: String) {
        reviews[projectID]?.text = ""
        reviews[projectID]?.commentCount = 0
        if projectID == self.projectID {
            isComposing = false
            composesOverSheet = false
        }
        clean(projectID)
    }

    /// Deletes a project's last shared review.
    func deleteShared(projectID: String) {
        reviews[projectID]?.shared = nil
        clean(projectID)
    }

    /// A project with nothing left goes from the saved reviews.
    private func clean(_ projectID: String) {
        if let review = reviews[projectID], !review.hasDraft, review.shared == nil { reviews[projectID] = nil }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reviews) { defaults.set(data, forKey: Self.reviewsKey) }
    }
}

/// The review, as a sheet like Mail's compose window: write freely, Share when done (it's kept
/// in its project's view as the last shared review, and the next comment starts a new one),
/// swipe down to set it aside and pick it up again from the bar, or X to put it away in its
/// project's view.
struct ReviewComposer: View {
    let draft: ReviewDraft


    var body: some View {
        @Bindable var draft = draft
        NavigationStack {
            ReviewTextView(text: $draft.text, cursorRequest: draft.cursorRequest)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Closes it, and the dock goes: the review stays in its project's view, where
                    // it can be opened again or deleted.
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { draft.putAway() }
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
            if completed { draft.didShare() }
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
    /// How far above the top of what it floats over (the bar, a caption) it sits: its height,
    /// its space below, and a little more.
    static let floatingRise: CGFloat = reservedHeight + 6

    /// A small capsule floating at the end, above the bar (or a page's caption): the review's
    /// icon and how many comments it has. Tap it to open the review.
    var body: some View {
        Button { draft.resume(overSheet: overSheet) } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.tint)
                Text(draft.commentCount, format: .number)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(DockBackground())
        .padding(.trailing, FileBarMetrics.fieldHorizontalMargin + 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Review, ^[\(draft.commentCount) comment](inflect: true)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the review")
        .accessibilityAction { draft.resume(overSheet: overSheet) }
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

/// A project's last shared review: read it, copy it or share it again.
struct SharedReviewView: View {
    let review: SharedReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(review.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("Last Shared Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        TextSharer.share(review.text) { _ in }
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = review.text }
                }
            }
        }
    }
}
