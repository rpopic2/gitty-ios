import SwiftUI
import UIKit

/// "This is a web page." with Open in Browser, at the top of a page that's raw HTML.
struct WebPageBanner: View {
    let onOpenInBrowser: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        let banner = HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text("This is a web page.")
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Open in Browser") { onOpenInBrowser() }
                .font(.subheadline.weight(.semibold))
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)

        Group {
            if #available(iOS 26.0, *) {
                banner.glassEffect(.regular, in: Capsule())
            } else {
                banner.background(.bar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}
