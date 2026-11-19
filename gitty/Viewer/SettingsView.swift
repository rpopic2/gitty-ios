import SwiftUI
import UIKit

/// Settings, from the bottom of the sidebar: the GitHub account, the space saved files take,
/// and About.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var account: Account = .loading
    @State private var usage: (count: Int, bytes: Int64)?
    @State private var isSigningIn = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeleteAll = false
    @AppStorage("reviewFormat") private var reviewFormat: ReviewFormat = .compact

    private enum Account {
        case loading
        case signedOut
        /// The account name, when GitHub told us.
        case signedIn(String?)
    }

    var body: some View {
        NavigationStack {
            Form {
                gitHubSection
                reviewSection
                storageSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $isSigningIn) {
            GitHubSignInView {
                isSigningIn = false
                Task { await reload() }
            }
        }
    }

    // MARK: GitHub

    @ViewBuilder
    private var gitHubSection: some View {
        Section {
            switch account {
            case .loading:
                ProgressView()
            case .signedOut:
                Button("Sign In to GitHub") { isSigningIn = true }
            case .signedIn(let login):
                LabeledContent("Account", value: login ?? "Signed In")
                Button("Choose Repositories") { openURL(GitHubAppConfig.installURL) }
                Button("Sign Out", role: .destructive) { isConfirmingSignOut = true }
                    .confirmationDialog("Sign out of GitHub?", isPresented: $isConfirmingSignOut,
                                        titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) { signOut() }
                        Button("Manage Access on GitHub") { openURL(GitHubAppConfig.authorizationsURL) }
                    } message: {
                        Text("Saved files stay on this device. To revoke gitty’s access, use GitHub’s settings.")
                    }
            }
        } header: {
            Text("GitHub")
        } footer: {
            Text("Signing in opens private repositories. gitty can only read the repositories you choose for its GitHub app.")
        }
    }

    private func signOut() {
        account = .signedOut
        Task { await GitHubAuth.shared.signOut() }
    }

    // MARK: Review

    private var reviewSection: some View {
        Section {
            Picker("Comment Format", selection: $reviewFormat) {
                Text("Compact").tag(ReviewFormat.compact)
                Text("Markdown").tag(ReviewFormat.markdown)
            }
        } header: {
            Text("Review")
        } footer: {
            switch reviewFormat {
            case .compact:
                Text("Each comment starts with the file and lines, like `alc/main.c:12-14:`.")
            case .markdown:
                Text("Each comment starts with a heading for the file and lines, and the selected code.")
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            LabeledContent("Saved Files") {
                if let usage {
                    Text("^[\(usage.count) file](inflect: true), \(Text(usage.bytes, format: .byteCount(style: .file)))")
                } else {
                    ProgressView()
                }
            }
            Button("Delete All Saved Files", role: .destructive) { isConfirmingDeleteAll = true }
                .disabled((usage?.count ?? 0) == 0)
                .confirmationDialog("Delete all saved files?", isPresented: $isConfirmingDeleteAll,
                                    titleVisibility: .visible) {
                    Button("Delete All Saved Files", role: .destructive) { deleteAll() }
                } message: {
                    Text("Files download again when you open them. Your projects and recent files stay.")
                }
        } header: {
            Text("Storage")
        } footer: {
            Text("Saved files open offline and never expire. They download again only when you pull to refresh.")
        }
    }

    private func deleteAll() {
        usage = (0, 0)
        Task {
            await DocumentStore.shared.deleteAll()
            usage = await DocumentStore.shared.storageUsage()
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            NavigationLink("Open-Source Licenses") { LicensesView() }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: Loading

    private func reload() async {
        let auth = GitHubAuth.shared
        if await auth.isSignedIn {
            account = .signedIn(await auth.login)
        } else {
            account = .signedOut
        }
        usage = await DocumentStore.shared.storageUsage()
    }
}

/// The open-source code gitty is built with, and each one's license.
private struct LicensesView: View {
    private struct Package: Identifiable {
        let name: String
        let license: String
        let url: URL
        var id: String { name }
    }

    private let packages = [
        Package(name: "SwiftTreeSitter", license: "BSD 3-Clause License",
                url: URL(string: "https://github.com/tree-sitter/swift-tree-sitter")!),
        Package(name: "tree-sitter", license: "MIT License",
                url: URL(string: "https://github.com/tree-sitter/tree-sitter")!),
        Package(name: "tree-sitter-c", license: "MIT License",
                url: URL(string: "https://github.com/tree-sitter/tree-sitter-c")!),
        Package(name: "tree-sitter-c-sharp", license: "MIT License",
                url: URL(string: "https://github.com/tree-sitter/tree-sitter-c-sharp")!),
        Package(name: "tree-sitter-swift", license: "MIT License",
                url: URL(string: "https://github.com/alex-pinkus/tree-sitter-swift")!),
        Package(name: "libgit2", license: "GPL v2 with Linking Exception",
                url: URL(string: "https://github.com/libgit2/libgit2")!),
        Package(name: "JetBrains Mono", license: "SIL Open Font License 1.1",
                url: URL(string: "https://github.com/JetBrains/JetBrainsMono")!),
    ]

    var body: some View {
        List(packages) { package in
            Link(destination: package.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .foregroundStyle(.primary)
                    Text(package.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Open-Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
