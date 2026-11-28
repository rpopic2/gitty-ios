import UIKit

/// A two-finger swipe on a trackpad (a Mac's, or an iPad's), never a touch: for what a finger
/// does from the screen's edge, where a window has no edge to swipe from (the line-number peek).
/// It goes alongside the view's scrolling.
@MainActor
final class TrackpadPan: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIPanGestureRecognizer()
    /// Whether to start, from where the pointer is in the view and which way it's going.
    var shouldBegin: @MainActor (_ location: CGPoint, _ velocity: CGPoint, _ view: UIView) -> Bool = { _, _, _ in true }
    /// How far the fingers have moved (right and down: above 0).
    var onChange: @MainActor (CGSize) -> Void = { _ in }
    /// Let go (or cancelled).
    var onEnd: @MainActor () -> Void = {}

    override init() {
        super.init()
        recognizer.allowedScrollTypesMask = .continuous
        recognizer.allowedTouchTypes = []
        recognizer.addTarget(self, action: #selector(panned(_:)))
        recognizer.delegate = self
    }

    /// The fingers going mostly right.
    static func isRightward(_ velocity: CGPoint) -> Bool {
        velocity.x > 0 && velocity.x > abs(velocity.y)
    }

    /// The pointer in the view's left part, as near as a window gets to its left edge.
    static func isNearLeftSide(_ location: CGPoint, of view: UIView) -> Bool {
        location.x < max(120, view.bounds.width * 0.25)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        switch recognizer.state {
        case .began, .changed:
            let t = recognizer.translation(in: view)
            onChange(CGSize(width: t.x, height: t.y))
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = recognizer.view else { return false }
        return shouldBegin(recognizer.location(in: view), recognizer.velocity(in: view), view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
