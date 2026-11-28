import SwiftUI
import UIKit

/// The Code level's line-number peek: swipe in from the left edge and hold, and the whole list
/// slides right with the line numbers beside the code, as on a page (`CodePieceLayout` draws
/// them). The slide is one offset on the list (`PeekShift`), and the blocks on screen only
/// show or hide their numbers when the peek starts and ends.
@MainActor @Observable
final class CodePeek {
    /// How far the code has slid right (0 to `fullWidth`).
    var offset: CGFloat = 0
    /// Peeking: the blocks draw with their numbers (each line numbered from its file).
    private(set) var isActive = false
    /// Pulled past the numbers (`blameThreshold`): who last changed each line shows left of
    /// them (`CodeBlameView`).
    private(set) var isBlameShown = false
    /// Let go with the blame showing: it stays until a tap on the code, or a swipe left.
    private(set) var isLocked = false
    /// Whether there's a blame to pull out to (`BlameStore.isAvailable`). Without one, the peek
    /// stops at the line numbers.
    var isBlameAvailable = true
    /// Room for the numbers.
    static let width: CGFloat = 56
    /// Between a number and its line.
    static let numberGap: CGFloat = 14
    /// Room for the blame, left of the numbers.
    static let blameWidth: CGFloat = 132
    static var fullWidth: CGFloat { width + blameWidth }
    /// Pulled this far, the blame shows (with a tap of feedback).
    static let blameThreshold: CGFloat = width + 40

    /// Touches starting this close to the screen's left edge can peek.
    static let edgeWidth: CGFloat = 28

    /// A drag's first move decides whether it slides the code (sideways) or scrolls.
    private var isSliding: Bool?

    /// Follows a drag: from the left edge, or anywhere while the blame stays open.
    func follow(_ translation: CGSize) {
        if isSliding == nil { isSliding = abs(translation.width) > abs(translation.height) }
        guard isSliding == true else { return }
        isActive = true
        let start = isLocked ? Self.fullWidth : 0
        // No blame: no further than the numbers.
        offset = min(max(start + translation.width, 0), isBlameAvailable ? Self.fullWidth : Self.width)
        let shows = isBlameAvailable && offset >= Self.blameThreshold
        guard shows != isBlameShown else { return }
        isBlameShown = shows
        if shows { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    /// Let go: with the blame showing, it opens all the way and stays; otherwise the code slides
    /// back, and the numbers go once it's there (unless a new peek has started meanwhile).
    func end() {
        defer { isSliding = nil }
        guard isSliding == true else { return }
        if isBlameShown {
            isLocked = true
            withAnimation(.smooth(duration: 0.2)) { offset = Self.fullWidth }
        } else {
            close()
        }
    }

    /// Back to the code alone.
    func close() {
        isLocked = false
        withAnimation(.smooth(duration: 0.2)) {
            offset = 0
        } completion: { [weak self] in
            guard let self, self.offset == 0 else { return }
            self.isActive = false
            self.isBlameShown = false
        }
    }
}

/// Who last changed the lines of the files at the Code level, from the project's clone, loaded
/// when the blame first shows for a file and kept.
@MainActor @Observable
final class BlameStore {
    /// A file's blame, and the project (for the commits).
    struct FileBlame: Equatable {
        let projectID: String
        let hunks: [GitBlameHunk]
        /// The file's path in the repository.
        var path: String = ""
    }

    enum State: Equatable {
        case loading
        case loaded(FileBlame)
        /// In a project that isn't cloned (blame needs the clone).
        case notCloned
        /// Not in a project, or it failed.
        case unavailable
    }

    private(set) var states: [URL: State] = [:]
    /// Some file on screen is in a project that isn't cloned: the blame offers Clone.
    private(set) var needsClone = false

    func blame(for file: URL) -> FileBlame? {
        if case .loaded(let blame) = states[file] { blame } else { nil }
    }

    /// Whether a file's blame can show: it's in a GitHub project (cloned, or Clone for Blame
    /// clones it) or in a local folder that's a Git repository. Not for a file outside projects,
    /// or a plain folder.
    static func isAvailable(for file: URL) async -> Bool {
        let projects = await ProjectStore.shared.projects()
        guard let location = ProjectFileLocation.locate(file, in: projects) else { return false }
        if let record = await CloneStore.shared.record(forProject: location.project.id) {
            return CloneIndex.shared.isRepository(record)
        }
        return location.project.link != nil
    }

    func load(_ file: URL) async {
        // Not cloned last time: it may be now.
        if let state = states[file], state != .notCloned { return }
        states[file] = .loading
        let projects = await ProjectStore.shared.projects()
        guard let location = ProjectFileLocation.locate(file, in: projects) else {
            states[file] = .unavailable
            return
        }
        let projectID = location.project.id
        guard await CloneStore.shared.record(forProject: projectID) != nil else {
            states[file] = .notCloned
            needsClone = true
            return
        }
        needsClone = false
        do {
            let hunks = try await CloneStore.shared.blame(projectID: projectID, path: location.path)
            states[file] = .loaded(FileBlame(projectID: projectID, hunks: hunks, path: location.path))
        } catch {
            states[file] = .unavailable
        }
    }

}

/// Slides the Code level's list while peeking. Only this redraws as the finger moves.
struct PeekShift: ViewModifier {
    let peek: CodePeek

    func body(content: Content) -> some View {
        content.offset(x: peek.offset)
    }
}

/// The Code level's pinch, as the fingers move: the list shrinks or grows a little toward the
/// pinch (less than the fingers, so it feels held back), then springs back as the step it was
/// heading for happens (or as you let go). Only `PinchScale` reads it, so the list itself
/// doesn't redraw while the fingers move.
@MainActor @Observable
final class PinchZoom {
    private(set) var scale: CGFloat = 1
    private(set) var anchor: UnitPoint = .center
    /// The fingers are past the step's threshold (its haptic tap has played).
    @ObservationIgnored var isPastThreshold = false

    /// A step happens when the fingers lift under 0.8 (see `SymbolsView.pinch`): the list is at
    /// 0.9 then.
    func follow(_ magnification: CGFloat, anchor: UnitPoint) {
        self.anchor = anchor
        scale = min(max(1 + (magnification - 1) * 0.5, 0.85), 1.15)
    }

    func settle() {
        guard scale != 1 else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { scale = 1 }
    }
}

/// Scales the Code level's list while pinching. Only this redraws as the fingers move.
struct PinchScale: ViewModifier {
    let zoom: PinchZoom

    func body(content: Content) -> some View {
        content.scaleEffect(zoom.scale, anchor: zoom.anchor)
    }
}
