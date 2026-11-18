import SwiftUI
import UIKit

/// Project mode, and the start page: your projects (GitHub repositories, opened by entering a repo
/// link), then every file you've opened or saved. Recent files come first, then every other saved
/// file, newest download first; saved files that belong to a project are listed in the project
/// instead. Tap a project to browse it, a file to open it; swipe to delete either.
struct ProjectView: View {
    /// The file on screen, marked in the list.
    let currentURL: URL?
    let onOpen: @MainActor (URL) -> Void

    @State private var projects: [ProjectInfo] = []
    @State private var recents: [URL] = []
    @State private var saved: [URL] = []
    /// The signed-in GitHub account (`""` when its name isn't known), or `nil` when signed out.
    @State private var gitHubAccount: String?
    @State private var isConfirmingSignOut = false
    @Environment(\.openURL) private var openURL

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(currentURL: URL? = nil, onOpen: @escaping @MainActor (URL) -> Void) {
        self.currentURL = currentURL
        self.onOpen = onOpen
    }

    private var files: [FileEntry] {
        let savedSet = Set(saved)
        // Project files (say, after Download All) show in their project, not here, unless recent.
        let projectPrefixes = projects.compactMap { $0.rawURL(for: "")?.absoluteString }
        let otherSaved = saved.filter { url in
            !projectPrefixes.contains { url.absoluteString.hasPrefix($0) }
        }
        var seen = Set<URL>()
        return (recents + otherSaved)
            .filter { seen.insert($0).inserted }
            .map { FileEntry(url: $0, isSaved: savedSet.contains($0)) }
    }

    var body: some View {
        List {
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { project in
                        NavigationLink(value: ProjectRoute(projectID: project.id, folder: nil)) {
                            ProjectRow(project: project)
                        }
                        .swipeActions {
                            Button(role: .destructive) { deleteProject(project) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { projectMenu }
                    }
                }
            }
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files) { file in
                        let isCurrent = file.url == currentURL
                        FileRow(file: file, isCurrent: isCurrent)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(file.url) }
                            // The open file looks selected: a gray highlight, like a row that stays
                            // selected in a list. Text keeps its normal colors.
                            .listRowBackground(isCurrent
                                ? Color(uiColor: .systemGray4)
                                : Color(uiColor: .secondarySystemGroupedBackground))
                            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                            .swipeActions {
                                Button(role: .destructive) { delete(file.url) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        .task { await reload() }  // every time the list appears
        .confirmationDialog(signOutTitle, isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { signOut() }
            Button("Manage Access on GitHub") { openURL(GitHubAppConfig.authorizationsURL) }
        } message: {
            Text("Saved files stay on this device. To revoke gitty’s access, use GitHub’s settings.")
        }
    }

    /// For now, signing out lives here (until there's a Settings screen with the account).
    @ViewBuilder
    private var projectMenu: some View {
        if gitHubAccount != nil {
            Button { isConfirmingSignOut = true } label: {
                Label("Sign Out of GitHub", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private var signOutTitle: String {
        guard let gitHubAccount, !gitHubAccount.isEmpty else { return "Sign out of GitHub?" }
        return "Sign out of GitHub as \(gitHubAccount)?"
    }

    private func signOut() {
        gitHubAccount = nil
        Task { await GitHubAuth.shared.signOut() }
    }

    private func reload() async {
        recents = RecentFilesStore.standard.urls()
        projects = await ProjectStore.shared.projects()
        saved = await DocumentStore.shared.savedDocuments().map(\.url)
        let auth = GitHubAuth.shared
        if await auth.isSignedIn {
            gitHubAccount = await auth.login ?? ""
        } else {
            gitHubAccount = nil
        }
    }

    /// Removes the project from the list. Its saved files stay (they show under Files again).
    private func deleteProject(_ project: ProjectInfo) {
        projects.removeAll { $0.id == project.id }
        Task { await ProjectStore.shared.remove(id: project.id) }
    }

    /// Removes the file from the list and deletes its saved copy and reading position.
    /// A file that's open stays on screen; opening it again downloads it.
    private func delete(_ url: URL) {
        RecentFilesStore.standard.remove(url)
        ReadingPositionStore.standard.remove(for: url)
        recents.removeAll { $0 == url }
        saved.removeAll { $0 == url }
        Task { await DocumentStore.shared.delete(url) }
    }
}

/// A project: its name, then owner · branch (and folder).
private struct ProjectRow: View {
    let project: ProjectInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .lineLimit(1)
                Text([project.link.owner, project.ref].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "shippingbox")
                .foregroundStyle(.tint)
        }
    }
}

private struct FileEntry: Identifiable {
    let url: URL
    /// Has a saved copy, so it opens offline.
    let isSaved: Bool
    var id: URL { url }
}

/// Name and location, and an icon on files that open offline. The open file's row is drawn
/// selected by the list (a gray row background).
private struct FileRow: View {
    let file: FileEntry
    let isCurrent: Bool

    private var primary: Color { .primary }
    private var secondary: Color { .secondary }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.displayFileName)
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Text(file.url.displayLocation)
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if file.isSaved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(secondary)
                    .accessibilityLabel("Saved on this device")
            }
        }
    }
}
