import SwiftUI
import UIKit

/// The Code level's line-number peek: swipe in from the left edge and hold, and the whole list
/// slides right with the line numbers beside the code, as on a page (`CodePieceLayout` draws
/// them). The slide is one offset on the list (`PeekShift`), and the blocks on screen only
/// show or hide their numbers when the peek starts and ends.
@MainActor @Observable
final class CodePeek {
    /// How far the code has slid right (0 to `width`).
    var offset: CGFloat = 0
    /// Peeking: the blocks draw with their numbers (each line numbered from its file).
    private(set) var isActive = false
    /// Room for the numbers.
    static let width: CGFloat = 56

    /// Touches starting this close to the screen's left edge can peek.
    static let edgeWidth: CGFloat = 28

    func follow(_ translation: CGFloat) {
        isActive = true
        offset = min(max(translation, 0), Self.width)
    }

    /// Let go: the code slides back, and the numbers go once it's there (unless a new peek
    /// has started meanwhile).
    func end() {
        withAnimation(.smooth(duration: 0.2)) {
            offset = 0
        } completion: { [weak self] in
            guard let self, self.offset == 0 else { return }
            self.isActive = false
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

    /// A step happens at 0.8 or 1.25 (see `SymbolsView.pinch`): the list is at 0.9 or 1.12 then.
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

/// Pinching out on code at the last level: the card grows out of the code under the fingers and
/// follows them, like a photo from Photos' grid, in a view over the window. Let go far enough
/// and it fills the screen and the real card takes its place (opened without its own animation,
/// at the same lines); otherwise it shrinks back into the code. Not observed: it moves views.
@MainActor
final class CardPinch {
    private var root: UIView?
    private var backdrop = UIView()
    private var card = UIView()
    private var snapshot: UIView?
    /// The code's frame in the window (clipped to the screen), and the pinch's place.
    private var startFrame: CGRect = .zero
    private var codeFrame: CGRect = .zero
    private var point: CGPoint = .zero
    private var open: (@MainActor () -> Void)?
    private var magnification: CGFloat = 1
    private var updates = 0

    var isActive: Bool { root != nil }

    /// Pulled this far (the fingers this much apart), the card fills the screen.
    static let fullMagnification: CGFloat = 2
    /// Let go past this and it opens.
    static let openingMagnification: CGFloat = 1.2

    /// Starts from the piece of code under the fingers. `open` opens the real card.
    func begin(from piece: UIView, at point: CGPoint, in window: UIWindow, open: @escaping @MainActor () -> Void) {
        cancelNow()
        // New views each time: the last pinch's may still be finishing.
        backdrop = UIView()
        card = UIView()
        snapshot = nil
        let root = UIView(frame: window.bounds)
        root.isUserInteractionEnabled = false
        backdrop.frame = root.bounds
        backdrop.backgroundColor = RawTextStyle.backgroundColor
        backdrop.alpha = 0
        root.addSubview(backdrop)
        codeFrame = piece.convert(piece.bounds, to: nil)
        startFrame = codeFrame.intersection(window.bounds)
        card.frame = startFrame
        card.backgroundColor = RawTextStyle.backgroundColor
        card.clipsToBounds = true
        card.layer.cornerCurve = .continuous
        if let snapshot = piece.snapshotView(afterScreenUpdates: false) {
            card.addSubview(snapshot)
            self.snapshot = snapshot
        }
        root.addSubview(card)
        window.addSubview(root)
        self.root = root
        self.point = point
        self.open = open
        update(1)
    }

    func update(_ magnification: CGFloat) {
        guard let root else { return }
        self.magnification = magnification
        let progress = min(max((magnification - 1) / (Self.fullMagnification - 1), 0), 1)
        let target = root.bounds
        card.frame = Self.mix(startFrame, target, progress)
        // Rounded while it's in between, like a card being lifted out.
        card.layer.cornerRadius = 48 * progress * (1 - progress)
        backdrop.alpha = progress
        // The code grows a little about the fingers, so the line under them stays there.
        let scale = 1 + (max(magnification, 1) - 1) * 0.35
        let grown = CGRect(x: point.x + (codeFrame.minX - point.x) * scale,
                           y: point.y + (codeFrame.minY - point.y) * scale,
                           width: codeFrame.width * scale, height: codeFrame.height * scale)
        snapshot?.frame = grown.offsetBy(dx: -card.frame.minX, dy: -card.frame.minY)
        // If the pinch is cancelled (no end comes), the card goes back on its own.
        updates += 1
        let count = updates
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.updates == count, self.isActive else { return }
            self.end()
        }
    }

    /// The fingers lift: open (far enough) or back into the code.
    func end() {
        guard let root else { return }
        let opens = magnification >= Self.openingMagnification
        let target = root.bounds
        let card = card, backdrop = backdrop, snapshot = snapshot, open = open, startFrame = startFrame
        let codeInCard = { [codeFrame] (card: CGRect) in codeFrame.offsetBy(dx: -card.minX, dy: -card.minY) }
        if opens {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                card.frame = target
                card.layer.cornerRadius = 0
                backdrop.alpha = 1
                snapshot?.frame = codeInCard(target)  // where the card shows those lines
            } completion: { _ in
                // The real card, under this one, without its zoom; then this one fades away.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { open?() }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    UIView.animate(withDuration: 0.15) {
                        root.alpha = 0
                    } completion: { _ in root.removeFromSuperview() }
                }
            }
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                           options: []) {
                card.frame = startFrame
                card.layer.cornerRadius = 0
                backdrop.alpha = 0
                snapshot?.frame = codeInCard(startFrame)
            } completion: { _ in root.removeFromSuperview() }
        }
        self.root = nil  // a new pinch can start while this one finishes
        self.open = nil
    }

    private func cancelNow() {
        root?.removeFromSuperview()
        root = nil
        open = nil
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}
