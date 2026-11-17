import UIKit
import UniformTypeIdentifiers

/// Safari ▸ Share ▸ gitty: takes the shared page's URL, opens gitty with it, and closes.
///
/// gitty gets it as `gitty://open?url=<address>` and treats it exactly like an address typed into
/// its bar (GitHub file links become raw, other URLs load as typed).
final class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear  // no UI of its own: it hands off and closes
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { @MainActor in
            if let address = await sharedAddress(), let link = Self.appLink(for: address) {
                openContainingApp(link)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The shared URL, or shared text as a fallback (some apps share links as text).
    private func sharedAddress() async -> String? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                return url.absoluteString
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                return text
            }
        }
        return nil
    }

    /// `gitty://open?url=<address>`. Must match `AddressParser.sharedAddress(in:)` in the app.
    /// Everything but unreserved characters is percent-encoded, so a shared URL's own `&` and `=`
    /// stay inside the `url` value.
    static func appLink(for address: String) -> URL? {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var components = URLComponents()
        components.scheme = "gitty"
        components.host = "open"
        components.percentEncodedQuery = "url=" + encoded
        return components.url
    }

    /// iOS has no API for a share extension to open its own app (`extensionContext.open` works only
    /// for widgets). The common workaround: walk the responder chain to the `UIApplication` and call
    /// `open(_:options:completionHandler:)` through the Objective-C runtime, since calling it
    /// directly doesn't compile in an extension.
    private func openContainingApp(_ link: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, link as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
