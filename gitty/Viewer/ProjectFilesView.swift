import SwiftUI
import UIKit

/// The open project in the Project tab: every file, grouped under a header per directory, code
/// files first in each. Tap a file to open its code (the Code level). Pull to refresh the list;
/// Clone downloads the whole project with Git (its latest commit) for offline reading and
/// history. The filter under the header (`*.cs *.md`, see `FileFilter`) narrows the list and the
/// project's symbols, and the branch row under it switches branch or tag. In recently opened
/// order (the sort button beside the mode selector) the files are one flat list instead.
struct ProjectFilesView: View {
    let projectID: String
    /// The file on screen, marked in the list.
    let currentURL: URL?
    /// False while File or Symbols covers it (see `ProjectView`).
    let isActive: Bool
    /// Name (directory headers) or recently opened (one flat list), and reversed or not.
    let sorting: ListSorting
    let onOpen: @MainActor (URL) -> Void

    @State private var state: LoadState = .loading
    /// Files with a saved copy (they open offline).
    @State private var saved: Set<URL> = []
    /// The project's clone, if it's cloned.
    @State private var clone: CloneRecord?
    /// While cloning: the fraction received.
    @State private var cloneProgress: Double?
    @State private var cloneError: (any Error)?
    @State private var isConfirmingDeleteClone = false
    /// The whole repository's files' size, roughly what Clone downloads (compressed, less).
    @State private var repositoryBytes: Int64 = 0
    /// Branches and tags, for the branch row.
    @State private var refs: ProjectRefs?
    @State private var isSwitchingRef = false
    @State private var isSignedIn = false
    @State private var isSigningIn = false
    /// The filter as typed. It's applied (and saved) when editing ends.
    @State private var filterText = ""
    @State private var filter = FileFilter.none
    @FocusState private var isEditingFilter: Bool
    @State private var hasLoadedFilter = false
    /// The project's files before filtering.
    @State private var fileCount = 0
    @Environment(\.openURL) private var openURL

    private enum LoadState {
        case loading
        case loaded(ProjectInfo, ProjectTree, Layout)
        case failed(any Error)
    }

    /// The files as listed: under directory headers (name order), or flat (recently opened).
    private nonisolated enum Layout: Sendable {
        case directories([ProjectTree.Directory])
        case flat([ProjectTree.Entry])

        var fileCount: Int {
            switch self {
            case .directories(let directories): directories.reduce(0) { $0 + $1.files.count }
            case .flat(let files): files.count
            }
        }
    }

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(projectID: String, currentURL: URL?, isActive: Bool, sorting: ListSorting,
         onOpen: @escaping @MainActor (URL) -> Void) {
        self.projectID = projectID
        self.currentURL = currentURL
        self.isActive = isActive
        self.sorting = sorting
        self.onOpen = onOpen
    }

    var body: some View {
        content
            .task { await load(refresh: false) }  // once: switching modes keeps this view
            .onChange(of: isActive) { _, isActive in
                if isActive { Task { await catchUp() } }
            }
            .onChange(of: sorting) { Task { await rearrange() } }
            .sheet(isPresented: $isSigningIn) {
                GitHubSignInView {
                    isSigningIn = false
                    Task { await load(refresh: true) }
                }
            }
            .alert("Couldn’t Clone", isPresented: cloneErrorIsPresented, presenting: cloneError) { _ in
                if cloneNeedsSignIn {
                    Button("Sign In to GitHub") { isSigningIn = true }
                }
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.localizedDescription)
            }
            .confirmationDialog("Delete the clone?", isPresented: $isConfirmingDeleteClone, titleVisibility: .visible) {
                Button("Delete Clone", role: .destructive) { deleteClone() }
            } message: {
                Text("Its files are removed from this device. They download one by one again when you open them.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn’t Load Project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failureMessage(for: error))
            } actions: {
                failureActions(for: error)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        case .loaded(let project, let tree, let layout):
            list(project: project, tree: tree, layout: layout)
        }
    }

    private func list(project: ProjectInfo, tree: ProjectTree, layout: Layout) -> some View {
        List {
            Section {
                header(project: project, tree: tree)
                filterRow
                branchRow(project: project)
            } footer: {
                headerFooter(tree: tree, layout: layout)
            }
            if layout.fileCount == 0 && !filter.isEmpty {
                Section {
                    Text("No files match this filter.")
                        .foregroundStyle(.secondary)
                }
            }
            switch layout {
            case .directories(let directories):
                ForEach(directories) { directory in
                    Section {
                        ForEach(directory.files, id: \.path) { entry in
                            row(for: entry, in: project)
                        }
                    } header: {
                        Text(directory.path.isEmpty ? project.title : directory.path)
                            .textCase(nil)  // paths keep their case
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            case .flat(let files):
                Section {
                    ForEach(files, id: \.path) { entry in
                        row(for: entry, in: project, showsFolder: true)
                    }
                } header: {
                    Text(sorting.isReversed ? "Opened Longest Ago" : "Recently Opened")
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        .overlay {
            if layout.fileCount == 0 && filter.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await load(refresh: true) }
        .scrollDisabled(!isActive)  // hidden: leaves status-bar taps to the mode on screen
    }

    /// The project's name, its owner, and Clone.
    private func header(project: ProjectInfo, tree: ProjectTree) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(clone == nil ? project.link.owner : project.link.owner + " · " + String(localized: "Cloned"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            cloneButton(project: project)
        }
    }

    /// Tap to edit; applied when you press Done or leave the field.
    private var filterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter.isEmpty ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            TextField("Filter, like *.cs *.md", text: $filterText)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditingFilter)
                .onSubmit { applyFilter() }
                .accessibilityLabel("Filter")
                .accessibilityHint("Space-separated patterns such as *.cs. Start one with ! to leave files out.")
            if !filterText.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") {
                    filterText = ""
                    applyFilter()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)  // only the button, not the whole row
            }
        }
        .onChange(of: isEditingFilter) { _, isEditing in
            if !isEditing { applyFilter() }
        }
    }

    @ViewBuilder
    private func headerFooter(tree: ProjectTree, layout: Layout) -> some View {
        let lines = [
            filter.isEmpty ? nil
                : "Showing \(layout.fileCount) of \(fileCount) files.",
            tree.truncated ? "This repository is very large, so GitHub listed only some of its files." : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            Text(lines.joined(separator: " "))
        }
    }

    /// Saves the filter and lists again with it, if it changed.
    private func applyFilter() {
        ProjectFilterStore.standard.save(filterText, for: projectID)
        let new = FileFilter(filterText.trimmingCharacters(in: .whitespaces))
        guard new != filter else { return }
        filter = new
        guard case .loaded = state else { return }
        Task { await rearrange() }
    }

    /// Lists the files again for the filter and the sorting, away from the main thread.
    private func rearrange() async {
        guard case .loaded(let project, let tree, _) = state else { return }
        let layout = await arrange(project: project, tree: tree)
        guard let layout else { return }  // changed meanwhile: a newer arrangement follows
        state = .loaded(project, tree, layout)
    }

    /// The files for the current filter and sorting, `nil` if either changed meanwhile.
    private func arrange(project: ProjectInfo, tree: ProjectTree) async -> Layout? {
        let filter = filter, sorting = sorting, folder = project.folder ?? ""
        let history = sorting.order == .recentlyOpened ? await OpenHistory.shared.snapshot() : [:]
        let layout = await Task.detached(priority: .userInitiated) {
            Self.layout(of: tree, project: project, folder: folder, filter: filter,
                        sorting: sorting, history: history)
        }.value
        guard filter == self.filter, sorting == self.sorting else { return nil }
        return layout
    }

    /// Grouping and sorting a big repository's paths takes long enough to stutter, so this runs
    /// in the background.
    nonisolated private static func layout(of tree: ProjectTree, project: ProjectInfo, folder: String,
                                           filter: FileFilter, sorting: ListSorting,
                                           history: [String: Date]) -> Layout {
        switch sorting.order {
        case .name:
            let directories = tree.directories(under: folder, matching: filter)
            guard sorting.isReversed else { return .directories(directories) }
            return .directories(directories.reversed().map {
                ProjectTree.Directory(path: $0.path, files: $0.files.reversed())
            })
        case .recentlyOpened:
            let files = tree.files(under: folder, matching: filter)
            return .flat(sorting.arrange(files, key: { project.rawURL(for: $0.path)?.absoluteString },
                                         name: { $0.path }, history: history))
        }
    }

    /// Groups the files by directory away from the main thread: sorting a big repository's
    /// paths takes long enough to stutter.

    /// Shown again after File or Symbols: only the saved marks can have changed (opening a
    /// file saves it). The list itself is kept; pull to refresh fetches it again.
    private func catchUp() async {
        guard case .loaded = state else { return }
        // Opening files changes recently opened order.
        if sorting.order == .recentlyOpened { await rearrange() }
        let now = Set(await DocumentStore.shared.savedDocuments().map(\.url))
        guard now != saved else { return }
        saved = now
    }

    /// Swiping a saved file: deletes its saved copy. It stays in the list and downloads again
    /// when opened; its reading position is kept. A file that's open stays on screen.
    private func deleteDownload(_ url: URL) {
        saved.remove(url)
        Task { await DocumentStore.shared.delete(url) }
    }

    @ViewBuilder
    private func row(for entry: ProjectTree.Entry, in project: ProjectInfo, showsFolder: Bool = false) -> some View {
        if let url = project.rawURL(for: entry.path) {
            let isCurrent = url == currentURL
            let isSaved = saved.contains(url)
            Button { onOpen(url) } label: {
                FileEntryRow(entry: entry, isSaved: isSaved,
                             folder: showsFolder ? folder(of: entry, in: project) : nil)
            }
            .swipeActions {
                if isSaved && clone == nil {  // a cloned file goes with the clone
                    // Not `.destructive`: the row stays, only its saved copy goes.
                    Button { deleteDownload(url) } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            // The open file looks selected, as in Files.
            .listRowBackground(isCurrent
                ? Color(uiColor: .systemGray4)
                : Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }

    /// The folder a file is in, inside the project (the project's name at its top).
    private func folder(of entry: ProjectTree.Entry, in project: ProjectInfo) -> String {
        let prefix = (project.folder ?? "").isEmpty ? "" : (project.folder ?? "") + "/"
        let relative = entry.path.dropFirst(prefix.count)
        guard let slash = relative.lastIndex(of: "/") else { return project.title }
        return String(relative[..<slash])
    }

    // MARK: Failure

    /// A repository GitHub can't find may be private: say how to get in.
    private func failureMessage(for error: any Error) -> String {
        let message = error.localizedDescription
        guard error as? ProjectError == .notFound else { return message }
        return message + (isSignedIn
            ? " If it’s private, check that gitty’s GitHub app can read it."
            : " If it’s a private repository, sign in to GitHub.")
    }

    @ViewBuilder
    private func failureActions(for error: any Error) -> some View {
        if error as? ProjectError == .notFound {
            if isSignedIn {
                Button("Choose Repositories") { openURL(GitHubAppConfig.installURL) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Sign In to GitHub") { isSigningIn = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        Button("Try Again") { Task { await load(refresh: true) } }
    }

    // MARK: Loading

    private func load(refresh: Bool) async {
        do {
            let (project, tree) = try await ProjectStore.shared.tree(for: projectID, refresh: refresh)
            clone = await CloneStore.shared.record(forProject: projectID)
            saved = Set(await DocumentStore.shared.savedDocuments().map(\.url))
            repositoryBytes = Self.bytes(of: tree)
            if refs == nil || refresh { Task { await loadRefs() } }
            if !hasLoadedFilter {  // the saved filter, once
                filterText = ProjectFilterStore.standard.text(for: projectID)
                filter = FileFilter(filterText)
                hasLoadedFilter = true
            }
            // Grouping a big repository takes a moment: once here, not on every redraw.
            var layout = await arrange(project: project, tree: tree)
            if layout == nil { layout = await arrange(project: project, tree: tree) }  // sorting changed meanwhile
            fileCount = tree.files(under: project.folder ?? "").count
            state = .loaded(project, tree, layout ?? .directories([]))
        } catch {
            if case .loaded = state, refresh { return }  // keep the list; the pull just ends
            isSignedIn = await GitHubAuth.shared.isSignedIn
            state = .failed(error)
        }
    }

    // MARK: Clone

    @ViewBuilder
    private func cloneButton(project: ProjectInfo) -> some View {
        if let cloneProgress {
            HStack(spacing: 6) {
                ProgressView()
                Text(cloneProgress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cloning")
            .accessibilityValue(Text(cloneProgress, format: .percent.precision(.fractionLength(0))))
        } else if clone != nil {
            Menu {
                Button("Delete Clone", systemImage: "trash", role: .destructive) { isConfirmingDeleteClone = true }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)  // only the button, not the whole row
            .accessibilityLabel("Cloned")
        } else {
            Button { startClone(project) } label: {
                HStack(spacing: 6) {
                    if repositoryBytes > 0 {
                        Text(repositoryBytes, format: .byteCount(style: .file))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Clone")
            .accessibilityHint("Downloads the whole project with Git, its latest commit only, for offline reading and history.")
        }
    }

    /// Clones the project (the latest commit). Its files then come from the clone, and the ones
    /// downloaded one by one are deleted.
    private func startClone(_ project: ProjectInfo) {
        cloneProgress = 0
        let (fractions, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            // Not after it's finished (a last fraction can arrive late).
            for await fraction in fractions where cloneProgress != nil { cloneProgress = fraction }
        }
        Task {
            do {
                try await CloneStore.shared.clone(project) { continuation.yield($0) }
                continuation.finish()
                clone = await CloneStore.shared.record(forProject: projectID)
                saved = Set(await DocumentStore.shared.savedDocuments().map(\.url))
            } catch {
                continuation.finish()
                isSignedIn = await GitHubAuth.shared.isSignedIn
                cloneError = error
            }
            cloneProgress = nil
        }
    }

    private func deleteClone() {
        Task {
            await CloneStore.shared.delete(projectID: projectID)
            clone = nil
            saved = Set(await DocumentStore.shared.savedDocuments().map(\.url))
        }
    }

    /// Clone failed: why, and signing in when GitHub turned it away.
    private var cloneErrorIsPresented: Binding<Bool> {
        Binding(get: { cloneError != nil }, set: { if !$0 { cloneError = nil } })
    }

    private var cloneNeedsSignIn: Bool {
        (cloneError as? GitError)?.isAuthentication == true && !isSignedIn
    }

    // MARK: Branch

    /// The branch or tag the project shows. Choosing another lists its files (and switches the
    /// clone, if there is one).
    private func branchRow(project: ProjectInfo) -> some View {
        Menu {
            if let refs {
                if !refs.branches.isEmpty {
                    Section("Branches") {
                        ForEach(refs.branches, id: \.self) { name in
                            refButton(name, isTag: false, current: project.ref)
                        }
                    }
                }
                if !refs.tags.isEmpty {
                    Section("Tags") {
                        ForEach(refs.tags, id: \.self) { name in
                            refButton(name, isTag: true, current: project.ref)
                        }
                    }
                }
            } else {
                Button("Load Branches and Tags") { Task { await loadRefs() } }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(project.ref ?? "")
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isSwitchingRef {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(isSwitchingRef || cloneProgress != nil)
        .accessibilityLabel("Branch")
        .accessibilityValue(project.ref ?? "")
    }

    private func refButton(_ name: String, isTag: Bool, current: String?) -> some View {
        Button {
            switchRef(to: name, isTag: isTag)
        } label: {
            if name == current {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private func loadRefs() async {
        refs = try? await ProjectStore.shared.refs(for: projectID)
    }

    /// Lists the files at another branch or tag. A cloned project fetches its latest commit
    /// and checks it out first, so its files come from the clone there too.
    private func switchRef(to name: String, isTag: Bool) {
        guard case .loaded(let project, _, _) = state, name != project.ref else { return }
        isSwitchingRef = true
        Task {
            defer { isSwitchingRef = false }
            do {
                if clone != nil {
                    var moved = project
                    moved.ref = name
                    if let prefix = moved.rawURL(for: "")?.absoluteString {
                        try await CloneStore.shared.switchTo(isTag ? .tag(name) : .branch(name),
                                                             projectID: projectID, rawPrefix: prefix)
                        clone = await CloneStore.shared.record(forProject: projectID)
                    }
                }
                let (moved, tree) = try await ProjectStore.shared.setRef(name, for: projectID)
                saved = Set(await DocumentStore.shared.savedDocuments().map(\.url))
                fileCount = tree.files(under: moved.folder ?? "").count
                repositoryBytes = Self.bytes(of: tree)
                state = .loaded(moved, tree, await arrange(project: moved, tree: tree) ?? .directories([]))
            } catch {
                cloneError = error
            }
        }
    }

    nonisolated private static func bytes(of tree: ProjectTree) -> Int64 {
        tree.entries.reduce(0) { $0 + Int64($1.size ?? 0) }
    }
}

/// A file in a project: a code icon for files with symbols, the name, its size, and the
/// offline icon once it's saved.
private struct FileEntryRow: View {
    let entry: ProjectTree.Entry
    let isSaved: Bool
    /// In the flat (recently opened) list: the folder it's in, under its name.
    var folder: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ProjectTree.isCode(entry) ? "chevron.left.forwardslash.chevron.right" : "doc")
                .foregroundStyle(ProjectTree.isCode(entry) ? Color.accentColor : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let folder {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if let size = entry.size {
                Text(Int64(size), format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isSaved {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Saved on this device")
            }
        }
    }
}
