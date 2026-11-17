import SwiftUI
import UIKit

/// Sizes for the bottom bar. Tune them against Safari screenshots on a device.
enum FileBarMetrics {
    // iOS 26+: floating Liquid Glass capsule.
    static let glassHeight: CGFloat = 48
    static let glassCollapsedHeight: CGFloat = 30
    static let glassHorizontalMargin: CGFloat = 20
    static let glassBottomPadding: CGFloat = 4
    static let glassGapAboveCapsule: CGFloat = 8

    // iOS 18: rounded field in a full-width material bar.
    static let fieldHeight: CGFloat = 44
    static let fieldCollapsedHeight: CGFloat = 24
    static let fieldCornerRadius: CGFloat = 12
    static let fieldHorizontalMargin: CGFloat = 12
    static let barVerticalPadding: CGFloat = 8

    // Mode selector (Project / File / Symbols) under the bar.
    static let selectorHeight: CGFloat = 32
    static let selectorMaxWidth: CGFloat = 320
    static var selectorPadding: CGFloat {
        if #available(iOS 26.0, *) { return 4 } else { return 0 }  // glass padding around it
    }
    static let selectorBottomPadding: CGFloat = 8

    static let titleFont = Font.system(size: 17)
    static let collapsedTitleFont = Font.system(size: 12)
    static let progressHeight: CGFloat = 3

    /// Height of the expanded bar alone, above the bottom safe area.
    static var barHeight: CGFloat {
        if #available(iOS 26.0, *) {
            return glassGapAboveCapsule + glassHeight + glassBottomPadding
        } else {
            return fieldHeight + 2 * barVerticalPadding
        }
    }

    /// Height of the expanded bar plus the mode selector, above the bottom safe area. Content keeps
    /// this much free at its end, and never changes it, so nothing jumps when the bar collapses.
    static var expandedHeight: CGFloat {
        barHeight + selectorHeight + 2 * selectorPadding + selectorBottomPadding
    }
}

/// Safari-style bottom bar that shows only the file name, with Safari's loading line.
/// It looks like the Safari of the iOS version it runs on.
struct FileBar: View {
    let title: String
    let isCollapsed: Bool
    let progressFraction: Double
    let isProgressVisible: Bool
    let onExpand: @MainActor () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassFileBar(title: title, isCollapsed: isCollapsed,
                             progress: ProgressLine(fraction: progressFraction, isVisible: isProgressVisible))
            } else {
                ClassicFileBar(title: title, isCollapsed: isCollapsed,
                               progress: ProgressLine(fraction: progressFraction, isVisible: isProgressVisible))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isCollapsed { onExpand() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isProgressVisible ? Text("Loading") : Text(""))
        .accessibilityAddTraits(isCollapsed ? .isButton : [])
        .accessibilityAction { if isCollapsed { onExpand() } }
    }
}

private struct BarTitle: View {
    let title: String
    let isCollapsed: Bool

    var body: some View {
        Text(title)
            .font(isCollapsed ? FileBarMetrics.collapsedTitleFont : FileBarMetrics.titleFont)
            .contentTransition(.interpolate)  // smooth size change between states
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// iOS 26+: Safari 26's floating glass capsule.
@available(iOS 26.0, *)
private struct GlassFileBar: View {
    let title: String
    let isCollapsed: Bool
    let progress: ProgressLine

    var body: some View {
        BarTitle(title: title, isCollapsed: isCollapsed)
            .padding(.horizontal, isCollapsed ? 14 : 20)
            .frame(maxWidth: isCollapsed ? nil : .infinity)
            .frame(height: isCollapsed ? FileBarMetrics.glassCollapsedHeight : FileBarMetrics.glassHeight)
            .overlay(alignment: .bottom) { progress }
            .clipShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, FileBarMetrics.glassHorizontalMargin)
            .padding(.bottom, FileBarMetrics.glassBottomPadding)
    }
}

/// iOS 18: Safari 18's rounded field. The toolbar material behind it is drawn by `BottomBarStack`.
private struct ClassicFileBar: View {
    let title: String
    let isCollapsed: Bool
    let progress: ProgressLine

    private var field: RoundedRectangle {
        RoundedRectangle(cornerRadius: FileBarMetrics.fieldCornerRadius, style: .continuous)
    }

    var body: some View {
        BarTitle(title: title, isCollapsed: isCollapsed)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: isCollapsed ? FileBarMetrics.fieldCollapsedHeight : FileBarMetrics.fieldHeight)
            .background {
                field
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .opacity(isCollapsed ? 0 : 1)
            }
            .overlay(alignment: .bottom) { progress }
            .clipShape(field)
            .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
            .padding(.vertical, isCollapsed ? 0 : FileBarMetrics.barVerticalPadding)
            .frame(maxWidth: .infinity)
    }
}

/// Safari's thin loading line. Hidden whenever nothing is loading.
private struct ProgressLine: View {
    let fraction: Double
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(.tint)
            .frame(height: FileBarMetrics.progressHeight)
            // scaleEffect is drawn on the GPU and doesn't trigger layout while animating.
            .scaleEffect(x: min(max(fraction, 0), 1), y: 1, anchor: .leading)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// The bottom of the screen: the file bar with the mode selector under it.
/// When the bar collapses on scroll, the selector hides with it.
struct BottomBarStack: View {
    let title: String
    let isCollapsed: Bool
    let progressFraction: Double
    let isProgressVisible: Bool
    @Binding var mode: ViewMode
    let onExpand: @MainActor () -> Void

    var body: some View {
        let stack = VStack(spacing: 0) {
            FileBar(title: title, isCollapsed: isCollapsed, progressFraction: progressFraction,
                    isProgressVisible: isProgressVisible, onExpand: onExpand)
            if !isCollapsed {
                ModeSelector(mode: $mode)
                    .padding(.bottom, FileBarMetrics.selectorBottomPadding)
                    .padding(.horizontal, FileBarMetrics.fieldHorizontalMargin)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }

        if #available(iOS 26.0, *) {
            stack
        } else {
            stack.background(.bar, ignoresSafeAreaEdges: .bottom)
        }
    }
}
