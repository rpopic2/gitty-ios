import SwiftUI
import UIKit

/// The open project in the Project tab: its header (Clone downloads the whole project with Git,
/// its latest commit, for offline reading and history), the filter (`*.cs *.md`, see
/// `FileFilter`) that narrows the project's files at the Code level, the branch row (switch
/// branch or tag, and its history), and the project's albums. The files themselves are at the
/// Code level. Pull to refresh the project's file list.
struct ProjectFilesView: View {
    let projectID: String
    /// False while the Code level covers it (see `ProjectView`).
    let isActive: Bool
    let onOpen: @MainActor (URL) -> Void
    /// The album shown, marked in the list.
    let currentAlbumID: UUID?
    let onOpenAlbum: @MainActor (UUID) -> Void
    /// The project's row: the whole project (out of an album), at the Code level.
    let onShowProject: @MainActor () -> Void
    @Environment(AlbumNaming.self) private var albumNaming: AlbumNaming?
    /// The project's review, in progress and last shared.
    @Environment(ReviewDraft.self) private var review: ReviewDraft?
    @State private var shownSharedReview: SharedReview?

    @State private var state: LoadState = .loading
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
    /// The branch's history (the branch row's History button).
    @State private var isShowingHistory = false
    /// A cloned project's branches and tags the clone has downloaded (the others need a pull).
    @State private var fetchedRefs: Set<String> = []
    /// A branch or tag chosen that the clone hasn't downloaded: asks to pull it.
    @State private var refToPull: RefToPull?
    /// Pull down (a fetch) or Pull is going on.
    @State private var isFetching = false
    @State private var isPulling = false

    private struct RefToPull: Identifiable {
        let name: String
        let isTag: Bool
        var id: String { name }
    }

    @State private var isSignedIn = false
    @State private var isSigningIn = false
    /// The filter as typed. It's applied (and saved) when editing ends.
    @State private var filterText = ""
    @State private var filter = FileFilter.none
    @FocusState private var isEditingFilter: Bool
    @State private var hasLoadedFilter = false
    /// The project's files before filtering, and those the filter keeps.
    @State private var fileCount = 0
    @State private var matchingCount = 0
    @Environment(\.openURL) private var openURL

    private enum LoadState {
        case loading
        case loaded(ProjectInfo, ProjectTree)
        case failed(any Error)
    }

    // An explicit init (not the memberwise one) so passing in an existing `@MainActor` closure
    // doesn't warn about converting it to `@Sendable`.
    init(projectID: String, isActive: Bool,
         currentAlbumID: UUID? = nil, onOpenAlbum: @escaping @MainActor (UUID) -> Void = { _ in },
         onShowProject: @escaping @MainActor () -> Void = {},
         onOpen: @escaping @MainActor (URL) -> Void) {
        self.projectID = projectID
        self.isActive = isActive
        self.currentAlbumID = currentAlbumID
        self.onOpenAlbum = onOpenAlbum
        self.onShowProject = onShowProject
        self.onOpen = onOpen
    }

    var body: some View {
        content
            .task { await load(refresh: false) }  // once: switching modes keeps this view
            .sheet(isPresented: $isSigningIn) {
                GitHubSignInView {
                    isSigningIn = false
                    Task { await load(refresh: true) }
                }
            }
            .sheet(isPresented: $isShowingHistory, onDismiss: {
                // It may have cloned the project.
                Task { clone = await CloneStore.shared.record(forProject: projectID) }
            }) {
                BranchHistoryView(projectID: projectID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $shownSharedReview) { shared in
                SharedReviewView(review: shared)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Couldn’t Clone", isPresented: cloneErrorIsPresented, presenting: cloneError) { _ in
                if cloneNeedsSignIn {
                    Button("Sign In to GitHub") { isSigningIn = true }
                }
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.localizedDescription)
            }
            .confirmationDialog(
                refToPull.map { String(localized: "“\($0.name)” isn’t downloaded") } ?? "",
                isPresented: Binding(get: { refToPull != nil }, set: { if !$0 { refToPull = nil } }),
                titleVisibility: .visible, presenting: refToPull
            ) { ref in
                Button("Pull \(ref.name)") { pullRef(ref) }
            } message: { ref in
                Text("Pull downloads its latest commit into the clone and shows its files. Until then the project stays on \(clone?.ref.name ?? "its branch").")
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
        case .loaded(let project, let tree):
            list(project: project, tree: tree)
        }
    }

    private func list(project: ProjectInfo, tree: ProjectTree) -> some View {
        List {
            Section {
                // Like "all of it" above the albums: a tap shows the whole project at the Code
                // level, out of an album. Clone and Pull are in their own row under it.
                header(project: project, tree: tree)
                    .contentShape(Rectangle())
                    .onTapGesture { onShowProject() }
                    .listRowBackground(currentAlbumID == nil
                        ? Color(uiColor: .systemGray4)
                        : Color(uiColor: .secondarySystemGroupedBackground))
                    .accessibilityAddTraits(currentAlbumID == nil ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onShowProject() }
                cloneRow(project: project)
                filterRow
                branchRow(project: project)
            } footer: {
                headerFooter(tree: tree)
            }
            if matchingCount == 0 && !filter.isEmpty {
                Section {
                    Text("No files match this filter.")
                        .foregroundStyle(.secondary)
                }
            }
            // The files are at the Code level (by folder, every file folded); here, the albums.
            reviewSection(project: project)
            albumsSection(project: project)
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        // Pull down: a cloned project fetches with Git (Pull then checks the new commits out);
        // otherwise GitHub's file list is fetched again.
        .refreshable {
            if clone != nil { await fetchClone() } else { await load(refresh: true) }
        }
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
    private func headerFooter(tree: ProjectTree) -> some View {
        let lines = [
            filter.isEmpty ? nil
                : "Showing \(matchingCount) of \(fileCount) files.",
            tree.truncated ? "This repository is very large, so GitHub listed only some of its files." : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            Text(lines.joined(separator: " "))
        }
    }

    /// Saves the filter and lists again with it, if it changed.
    private func applyFilter() {
        ProjectFilterStore.standard.save(filterText, for: projectID)
        if clone?.scope != nil {
            // A clone of the filtered files only follows the filter.
            let saved = ProjectFilterStore.standard.text(for: projectID)
            Task {
                guard (try? await CloneStore.shared.applyFilter(saved, projectID: projectID)) == true else { return }
                clone = await CloneStore.shared.record(forProject: projectID)
            }
        }
        let new = FileFilter(filterText.trimmingCharacters(in: .whitespaces))
        guard new != filter else { return }
        filter = new
        guard case .loaded = state else { return }
        Task { await recount() }
    }

    /// Counts the files the filter keeps again, for the footer.
    private func recount() async {
        guard case .loaded(let project, let tree) = state else { return }
        guard let count = await count(project: project, tree: tree) else { return }  // a newer count follows
        matchingCount = count
    }

    /// How many files the current filter keeps, away from the main thread (a big repository has
    /// many paths); `nil` if the filter changed meanwhile.
    private func count(project: ProjectInfo, tree: ProjectTree) async -> Int? {
        let filter = filter, folder = project.folder ?? ""
        let count = await Task.detached(priority: .userInitiated) {
            tree.files(under: folder, matching: filter).count
        }.value
        guard filter == self.filter else { return nil }
        return count
    }

    // MARK: Review

    /// The project's review: the one in progress (tap to write, swipe to delete) and the last
    /// one shared (tap to read, copy or share again). Closing the composer with its X keeps it
    /// here.
    @ViewBuilder
    private func reviewSection(project: ProjectInfo) -> some View {
        if let review {
            let state = review.review(for: project.id)
            if state.hasDraft || state.shared != nil {
                Section("Review") {
                    if state.hasDraft {
                        Button { review.open(projectID: project.id) } label: {
                            reviewRow(title: String(localized: "In Progress"), systemImage: "text.bubble",
                                      detail: Self.comments(state.commentCount))
                        }
                        .swipeActions {
                            Button(role: .destructive) { review.delete(projectID: project.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    if let shared = state.shared {
                        Button { shownSharedReview = shared } label: {
                            reviewRow(title: String(localized: "Last Shared"), systemImage: "checkmark.bubble",
                                      detail: Self.comments(shared.commentCount)
                                          + " · " + shared.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        .swipeActions {
                            Button(role: .destructive) { review.deleteShared(projectID: project.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private static func comments(_ count: Int) -> String {
        count == 1 ? String(localized: "1 comment") : String(localized: "\(count) comments")
    }

    private func reviewRow(title: String, systemImage: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }

    // MARK: Albums

    /// The project's albums, like Photos': tap one to show only what's in it at the Code level;
    /// swipe one to rename or delete it.
    @ViewBuilder
    private func albumsSection(project: ProjectInfo) -> some View {
        let albums = AlbumStore.shared.albums(inProject: project.id)
        Section {
            ForEach(albums) { album in
                Button { onOpenAlbum(album.id) } label: {
                    AlbumRow(album: album)
                }
                .listRowBackground(album.id == currentAlbumID
                    ? Color(uiColor: .systemGray4)
                    : Color(uiColor: .secondarySystemGroupedBackground))
                .accessibilityAddTraits(album.id == currentAlbumID ? .isSelected : [])
                .swipeActions {
                    Button(role: .destructive) { AlbumStore.shared.delete(album.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { albumNaming?.beginRenaming(album) } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
            }
            Button {
                albumNaming?.begin(projectID: project.id, opensAlbum: true)
            } label: {
                Label("New Album", systemImage: "plus")
            }
        } header: {
            Text("Albums")
        } footer: {
            if albums.isEmpty {
                Text("An album keeps the symbols, files and lines of this project you want to see together. To add something to one, touch and hold it at the Code level, then choose Add to Album.")
            }
        }
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
            repositoryBytes = Self.bytes(of: tree)
            if refs == nil || refresh { Task { await loadRefs() } }
            if !hasLoadedFilter {  // the saved filter, once
                filterText = ProjectFilterStore.standard.text(for: projectID)
                filter = FileFilter(filterText)
                hasLoadedFilter = true
            }
            fileCount = tree.files(under: project.folder ?? "").count
            matchingCount = await count(project: project, tree: tree) ?? fileCount
            state = .loaded(project, tree)
        } catch {
            if case .loaded = state, refresh { return }  // keep the list; the pull just ends
            isSignedIn = await GitHubAuth.shared.isSignedIn
            state = .failed(error)
        }
    }

    // MARK: Clone

    /// Its own row under the project's (which only chooses the project): Clone before it's
    /// cloned; once it is, where the clone is, Pull (with how many new commits a pull down
    /// found) and Delete Clone.
    @ViewBuilder
    private func cloneRow(project: ProjectInfo) -> some View {
        if let cloneProgress {
            HStack(spacing: 10) {
                ProgressView()
                Text("Cloning…")
                Spacer(minLength: 8)
                Text(cloneProgress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cloning")
        } else if let clone {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloned")
                    Text(clone.ref.name + " · " + String(clone.commit.prefix(7))
                         + (clone.scope != nil ? " · " + String(localized: "filtered files") : ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isPulling || isFetching {
                    ProgressView()
                } else if let new = clone.newCommits, new > 0 {
                    Button("Pull \(new)") { pull() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint("Checks out the new commits")
                } else {
                    Button("Pull") { pull() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Downloads the branch’s latest commit and checks it out")
                }
                Menu {
                    if clone.scope != nil {
                        Text("Only the filtered files are kept, following the filter.")
                    }
                    Button("Delete Clone", systemImage: "trash", role: .destructive) { isConfirmingDeleteClone = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)  // only the button, not the whole row
                .accessibilityLabel("Clone Options")
            }
        } else if !filter.isEmpty || !(project.folder ?? "").isEmpty {
            // A filter (or a folder of the repository): clone all of it, or keep just those files.
            Menu {
                Button { startClone(project, filtered: true) } label: {
                    Text("Clone Filtered Files")
                    Text("Only the files the filter shows are kept on this device. Git still downloads them all.")
                }
                Button { startClone(project, filtered: false) } label: {
                    Text("Clone All Files")
                }
            } label: {
                cloneLabel
            }
            .accessibilityHint("Downloads the project with Git, its latest commit only, for offline reading and history.")
        } else {
            Button { startClone(project, filtered: false) } label: {
                cloneLabel
            }
            .accessibilityHint("Downloads the whole project with Git, its latest commit only, for offline reading and history.")
        }
    }

    private var cloneLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .accessibilityHidden(true)
            Text("Clone")
            Spacer(minLength: 8)
            if repositoryBytes > 0 {
                Text(repositoryBytes, format: .byteCount(style: .file))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Pull down on a cloned project: Git fetches the branch's latest commits (nothing changes
    /// on screen) and the remote's branches; Pull then shows how many are new.
    private func fetchClone() async {
        isFetching = true
        defer { isFetching = false }
        do {
            try await CloneStore.shared.fetch(projectID: projectID)
            clone = await CloneStore.shared.record(forProject: projectID)
            await loadRefs()
        } catch {
            isSignedIn = await GitHubAuth.shared.isSignedIn
            cloneError = error
        }
    }

    /// Pull: the branch's latest commit, checked out; the file list from the clone.
    private func pull() {
        guard case .loaded(let project, _) = state, let ref = clone?.ref else { return }
        isPulling = true
        Task {
            defer { isPulling = false }
            do {
                try await CloneStore.shared.pull(projectID: projectID)
                clone = await CloneStore.shared.record(forProject: projectID)
                if let tree = try? await CloneStore.shared.tree(projectID: projectID) {
                    let (moved, tree) = try await ProjectStore.shared.setRef(ref.name, for: project.id, tree: tree)
                    show(moved, tree)
                }
            } catch {
                isSignedIn = await GitHubAuth.shared.isSignedIn
                cloneError = error
            }
        }
    }

    /// The project at its (new) branch, with its file list.
    private func show(_ project: ProjectInfo, _ tree: ProjectTree) {
        fileCount = tree.files(under: project.folder ?? "").count
        repositoryBytes = Self.bytes(of: tree)
        state = .loaded(project, tree)
        Task { matchingCount = await count(project: project, tree: tree) ?? fileCount }
    }

    /// Clones the project (the latest commit). Its files then come from the clone, and the ones
    /// downloaded one by one are deleted.
    /// - Parameter filtered: keep only the files the project's filter lets through.
    private func startClone(_ project: ProjectInfo, filtered: Bool) {
        cloneProgress = 0
        let (fractions, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            // Not after it's finished (a last fraction can arrive late).
            for await fraction in fractions where cloneProgress != nil { cloneProgress = fraction }
        }
        Task {
            do {
                try await CloneStore.shared.clone(project, filtered: filtered) { continuation.yield($0) }
                continuation.finish()
                clone = await CloneStore.shared.record(forProject: projectID)
                await loadRefs()  // the clone's, from now on
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
            await loadRefs()  // GitHub's again
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
    /// clone, if there is one). The button at its end shows the branch's history.
    private func branchRow(project: ProjectInfo) -> some View {
        HStack(spacing: 12) {
            branchMenu(project: project)
            Button {
                isShowingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
            }
            .buttonStyle(.borderless)  // only the button, not the whole row
            .disabled(cloneProgress != nil)
            .accessibilityLabel("History")
            .accessibilityHint("Shows the branch’s commits")
        }
    }

    private func branchMenu(project: ProjectInfo) -> some View {
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
            } else if clone != nil, !fetchedRefs.contains(name) {
                Text(name)
                Text("Not downloaded")
            } else {
                Text(name)
            }
        }
    }

    /// The branches and tags: a cloned project's from the clone (listed from the remote when
    /// cloning and on each pull down), with which ones it has downloaded; otherwise GitHub's.
    private func loadRefs() async {
        if let clone, let remote = clone.remoteRefs {
            refs = remote
            fetchedRefs = await CloneStore.shared.fetchedRefs(projectID: projectID)
        } else {
            refs = try? await ProjectStore.shared.refs(for: projectID)
        }
    }

    /// Shows another branch or tag. A cloned project checks out one it has downloaded (offline,
    /// as it was fetched then: pull down for newer) and lists its files from the clone, with no
    /// network at all; one it hasn't downloaded asks to pull it (`refToPull`). A project that
    /// isn't cloned lists its files from GitHub.
    private func switchRef(to name: String, isTag: Bool) {
        guard case .loaded(let project, _) = state, name != project.ref else { return }
        if clone != nil, !fetchedRefs.contains(name) {
            refToPull = RefToPull(name: name, isTag: isTag)
            return
        }
        isSwitchingRef = true
        Task {
            defer { isSwitchingRef = false }
            do {
                if clone != nil {
                    try await switchClone(to: name, isTag: isTag, from: project, pulling: false)
                } else {
                    let (moved, tree) = try await ProjectStore.shared.setRef(name, for: projectID)
                    show(moved, tree)
                }
            } catch {
                cloneError = error
            }
        }
    }

    /// Pull on a branch or tag the clone hasn't downloaded: its latest commit, checked out.
    private func pullRef(_ ref: RefToPull) {
        guard case .loaded(let project, _) = state else { return }
        isSwitchingRef = true
        Task {
            defer { isSwitchingRef = false }
            do {
                try await switchClone(to: ref.name, isTag: ref.isTag, from: project, pulling: true)
                fetchedRefs.insert(ref.name)
            } catch {
                isSignedIn = await GitHubAuth.shared.isSignedIn
                cloneError = error
            }
        }
    }

    private func switchClone(to name: String, isTag: Bool, from project: ProjectInfo, pulling: Bool) async throws {
        var moved = project
        moved.ref = name
        guard let prefix = moved.rawURL(for: "")?.absoluteString else { return }
        let tree = try await CloneStore.shared.switchTo(isTag ? .tag(name) : .branch(name), projectID: projectID,
                                                        rawPrefix: prefix, pulling: pulling)
        clone = await CloneStore.shared.record(forProject: projectID)
        let (shown, shownTree) = try await ProjectStore.shared.setRef(name, for: projectID, tree: tree)
        show(shown, shownTree)
    }

    nonisolated private static func bytes(of tree: ProjectTree) -> Int64 {
        tree.entries.reduce(0) { $0 + Int64($1.size ?? 0) }
    }
}

/// An album: its name and how many items it has.
private struct AlbumRow: View {
    let album: Album

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(album.items.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.tint)
        }
    }
}
