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

    static let titleFont = Font.system(size: 17)
    static let collapsedTitleFont = Font.system(size: 12)
    static let progressHeight: CGFloat = 3

    /// Height of the expanded bar above the bottom safe area. The text view keeps this much free
    /// at the end of the file, and never changes it, so the text doesn't jump when the bar collapses.
    static var expandedHeight: CGFloat {
        if #available(iOS 26.0, *) {
            return glassGapAboveCapsule + glassHeight + glassBottomPadding
        } else {
            return fieldHeight + 2 * barVerticalPadding
        }
    }
}

/// Safari-style bottom bar that shows only the file name, with Safari's loading line.
/// It looks like the Safari of the iOS version it runs on.
struct FileBar: View {
    let title: String
    let isCollapsed: Bool
    let progressFraction: Double
    let isProgressVisible: Bool
    let onExpand: () -> Void

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

/// iOS 18: Safari 18's rounded field in a material toolbar.
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
            .background(.bar, ignoresSafeAreaEdges: .bottom)
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
