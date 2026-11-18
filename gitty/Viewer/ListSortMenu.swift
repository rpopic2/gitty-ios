import SwiftUI

/// The sort button beside the mode selector, like Photos': Name or Recently Opened, and
/// Reverse Order.
struct ListSortMenu: View {
    @Binding var sorting: ListSorting

    static var size: CGFloat {
        FileBarMetrics.selectorHeight + 2 * FileBarMetrics.selectorPadding
    }

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sorting.order) {
                Label("Name", systemImage: "textformat").tag(ListOrder.name)
                Label("Recently Opened", systemImage: "clock").tag(ListOrder.recentlyOpened)
            }
            Toggle("Reverse Order", systemImage: "arrow.up.arrow.down", isOn: $sorting.isReversed)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.medium))
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
                .modifier(SortButtonBackground())
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        let order = sorting.order == .name ? Text("Name") : Text("Recently Opened")
        return sorting.isReversed ? order + Text(", reversed") : order
    }
}

/// Glass on iOS 26, like the selector beside it; a filled circle on iOS 18.
private struct SortButtonBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
    }
}
