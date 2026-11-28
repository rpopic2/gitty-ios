import SwiftUI
import UIKit

/// The open project in the Project tab: its row (with the space it takes on this device), the
/// filter (`Scripts`, `*.cs *.md`, see `FileFilter`) that narrows the project's files at the Code level,
/// Git (the branch or tag, Clone or Pull, History) and its review (its albums are on their own
/// page, `AlbumsOverview`). The files
/// themselves are at the Code level. Pull down to refresh the file list, or fetch a clone.
struct ProjectFilesView: View {
    let projectID: String
    /// False while the Code level covers it (see `ProjectView`).
    let isActive: Bool
    let onOpen: @MainActor (URL) -> Void
    /// The album shown, marked in the list.
    let currentAlbumID: UUID?
    let onOpenAlbum: @MainActor (UUID) -> Void
    /// The whole project's album row: the whole project (out of an album), at the Code level.
    let onShowProject: @MainActor () -> Void
    @Environment(AlbumNaming.self) private var albumNaming: AlbumNaming?
    /// The project's review, in progress and last shared.
    @Environment(ReviewDraft.self) private var review: ReviewDraft?
    @State private var shownSharedReview: SharedReview?

    @State private var state: LoadState = .loading
    /// The project's clone, if it's cloned.
    @State private var clone: CloneRecord?
    /// A Git download going on (Clone, Pull, pull down, a branch), in the Pull row with Cancel.
    /// Kept for the whole app: it goes on while another project shows.
    private var download: GitDownloads.Download? { GitDownloads.shared.download(for: projectID) }
    /// Asks before a big download on a mobile network.
    @State private var downloads = DownloadGuard()
    /// The space the project takes on this device: its clone, or the files downloaded one by one.
    @State private var storedBytes: Int64?
    @State private var cloneError: (any Error)?
    /// What the error alert is about (cloning, or a local folder's checkout or refresh).
    @State private var errorTitle = String(localized: "Couldn’t Clone")
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
    /// The branch picker is up.
    @State private var isPickingRef = false
    /// A branch or tag held in the picker, compared with the checkout once the picker's gone.
    @State private var pendingComparison: Comparing?
    /// Compare Against… (the branch row's long-press menu): the picker, to choose what to
    /// compare the checkout with.
    @State private var isPickingComparison = false
    @State private var comparing: Comparing?

    private struct Comparing: Identifiable {
        let head: GitSide
        var id: GitSide { head }
    }
    /// A branch or tag chosen that the clone hasn't downloaded: asks to pull it.
    @State private var refToPull: GitRef?
    /// Just switched: diff albums comparing with the checkout whose split isn't downloaded. Asks
    /// to load the history back to it.
    @State private var historyNeeded: HistoryNeeded?

    private struct HistoryNeeded: Identifiable {
        /// What they compare the checkout with ("main"), for the question.
        let others: [String]
        /// The comparisons, to tell when the split is in.
        let comparisons: [GitComparison]
        var id: String { others.joined(separator: ",") }
    }

    @State private var isSignedIn = false
    @State private var isSigningIn = false
    /// The filter as typed, saved as it changes; `filter` (the icon's colour) when editing ends.
    @State private var filterText = ""
    @State private var filter = FileFilter.none
    @FocusState private var isEditingFilter: Bool
    @State private var hasLoadedFilter = false
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
            // Make Album in a diff shown over the project: the album shows, so these close.
            .onChange(of: albumNaming?.madeDiffAlbumCount) {
                isShowingHistory = false
                comparing = nil
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
            .alert(errorTitle, isPresented: cloneErrorIsPresented, presenting: cloneError) { _ in
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
            // Just switched: an album comparing with the checkout needs older history.
            .confirmationDialog(
                historyNeeded.map { String(localized: "Comparing with \($0.others.joined(separator: ", ")) needs older history") } ?? "",
                isPresented: Binding(get: { historyNeeded != nil }, set: { if !$0 { historyNeeded = nil } }),
                titleVisibility: .visible, presenting: historyNeeded
            ) { needed in
                Button("Load History") { loadHistory(to: needed) }
                Button("Not Now", role: .cancel) {}
            } message: { _ in
                Text("Where they split isn’t downloaded yet, so its album can’t show the changes. Loading fetches older commits until it’s found.")
            }
            .confirmationDialog("Delete the clone?", isPresented: $isConfirmingDeleteClone, titleVisibility: .visible) {
                Button("Delete Clone", role: .destructive) { deleteClone() }
            } message: {
                Text("Its files are removed from this device. They download one by one again when you open them.")
            }
            .downloadConfirmation(downloads)
            // A download ended, perhaps started by this project's view before it was left: show
            // what it did (the clone, the branch, the space taken).
            .onChange(of: GitDownloads.shared.finished[projectID]) {
                Task {
                    await load(refresh: false)
                    await loadRefs()
                }
            }
            // Back from the Code level: files may have downloaded meanwhile.
            .onChange(of: isActive) { _, isActive in
                if isActive {
                    Task { await refreshStorage() }
                } else {
                    // Left for the Code level while typing: it stays alive underneath, so the
                    // field wouldn't end editing by itself.
                    isEditingFilter = false
                    applyFilter()
                }
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
                // The whole project is the first album, on the albums page (`AlbumsOverview`).
                header(project: project, tree: tree)
            }
            Section("Filter") {
                filterRow
            }
            if project.localFolder != nil {
                // A folder on this device: read where it is (Refresh reads it again); a
                // repository's branches check out in it.
                let isRepository = clone.map { CloneIndex.shared.isRepository($0) } ?? false
                Section(isRepository ? "Git" : "Folder") {
                    if isRepository { branchRow(project: project) }
                    refreshRow
                    if isRepository { historyRow }
                }
            } else {
                Section("Git") {
                    branchRow(project: project)
                    pullRow(project: project)
                    historyRow
                }
            }
            // The files are at the Code level (by folder, every file folded); here, the albums.
            reviewSection(project: project)
            // The albums are on their own page: swipe up on the Code level's bar.
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, FileBarMetrics.expandedHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)  // any swipe hides the keyboard
        // Pull down: a cloned project fetches with Git (Pull then checks the new commits out);
        // otherwise GitHub's file list is fetched again.
        .refreshable {
            if clone?.isLocal == true {
                await refreshLocalFolder()
            } else if clone != nil {
                await fetchClone()
            } else {
                await load(refresh: true)
            }
        }
        .scrollDisabled(!isActive)  // hidden: leaves status-bar taps to the mode on screen
    }

    /// The project's name, its owner, and the space it takes on this device.
    private func header(project: ProjectInfo, tree: ProjectTree) -> some View {
        HStack(spacing: 12) {
            Image(systemName: project.localFolder != nil ? "folder" : "shippingbox")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let storedBytes, storedBytes > 0 {
                Text(storedBytes, format: .byteCount(style: .file))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(storedBytes.formatted(.byteCount(style: .file))) on this device")
            }
        }
    }

    /// Tap to edit; saved as you type, and the Code level follows it when it shows.
    private var filterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter.isEmpty ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            TextField("Filter files", text: $filterText)
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
        // Saved as you type: the Code level reads it when it shows (it's indexed again then, not
        // on each key), however you get there, even with the field still editing.
        .onChange(of: filterText) {
            if hasLoadedFilter { ProjectFilterStore.standard.save(filterText, for: projectID) }
        }
    }

    /// Saves the filter (the Code level follows it).
    private func applyFilter() {
        ProjectFilterStore.standard.save(filterText, for: projectID)
        let new = FileFilter(filterText.trimmingCharacters(in: .whitespaces))
        guard new != filter else { return }
        filter = new
    }

    // MARK: Review

    /// The project's review: the one in progress (tap to write, swipe to delete) and the last
    /// one shared (tap to read, copy or share again). Closing the composer with its X keeps it
    /// here. Always shown: with neither, how to start one.
    @ViewBuilder
    private func reviewSection(project: ProjectInfo) -> some View {
        if let review {
            let state = review.review(for: project.id)
            Section("Review") {
                if !state.hasDraft, state.shared == nil {
                    reviewRow(title: String(localized: "No Review Yet"), systemImage: "text.bubble",
                              detail: String(localized: "Hold code, a file or a folder, or select text, and choose Comment."))
                        .accessibilityElement(children: .combine)
                } else {
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
            state = .loaded(project, tree)
            await refreshStorage()
        } catch {
            if case .loaded = state, refresh { return }  // keep the list; the pull just ends
            isSignedIn = await GitHubAuth.shared.isSignedIn
            state = .failed(error)
        }
    }

    // MARK: Git

    /// Clone before it's cloned, then Pull (with how many new commits a pull down found); swipe
    /// it for Delete Clone. While Git downloads, what's come down so far and Cancel.
    @ViewBuilder
    private func pullRow(project: ProjectInfo) -> some View {
        if let download {
            HStack(spacing: 10) {
                ProgressView()
                Text(download.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(DownloadGuard.progressText(download.progress, estimate: download.estimate))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel", systemImage: "xmark.circle.fill") { GitDownloads.shared.cancel(projectID: projectID) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)  // only the button, not the whole row
            }
        } else if let clone {
            Button { pullTapped() } label: {
                gitLabel("Pull", systemImage: "arrow.triangle.2.circlepath", detail: newCommitsText(clone.newCommits))
            }
            .accessibilityHint("Downloads the branch’s latest commit and checks it out")
            .swipeActions {
                Button(role: .destructive) { isConfirmingDeleteClone = true } label: {
                    Label("Delete Clone", systemImage: "trash")
                }
            }
        } else {
            Button { cloneTapped(project) } label: {
                gitLabel("Clone", systemImage: "arrow.down.circle",
                         detail: repositoryBytes > 0
                            ? String(localized: "up to \(repositoryBytes.formatted(.byteCount(style: .file)))")
                            : nil)
            }
            .accessibilityHint("Downloads the whole project with Git, its latest commit only, for offline reading and history.")
        }
    }

    /// A local folder's Refresh: read again, the edits made to it since too.
    private var refreshRow: some View {
        Button { Task { await refreshLocalFolder() } } label: {
            gitLabel("Refresh", systemImage: "arrow.clockwise", detail: nil)
        }
        .accessibilityHint("Reads the folder again, with the changes made to it")
    }

    /// Reads a local folder again: the Code level shows its files as they are now.
    private func refreshLocalFolder() async {
        do {
            if try await CloneStore.shared.refreshLocal(projectID: projectID) {
                CloneChanges.shared.didPull(projectID)
            }
            clone = await CloneStore.shared.record(forProject: projectID)
            await load(refresh: true)
            await loadRefs()
        } catch {
            errorTitle = String(localized: "Couldn’t Read the Folder")
            cloneError = error
        }
    }

    /// The branch's commits (cloning, if it isn't).
    private var historyRow: some View {
        Button { isShowingHistory = true } label: {
            gitLabel("History", systemImage: "clock.arrow.circlepath", detail: nil)
        }
        .disabled(download != nil)
        .accessibilityHint("Shows the branch’s commits")
    }

    /// A Git row: its symbol, its name, and a detail at the end.
    private func gitLabel(_ title: LocalizedStringKey, systemImage: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func newCommitsText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? String(localized: "1 new commit") : String(localized: "\(count) new commits")
    }

    /// Runs a Git download, shown in the Pull row with Cancel (`GitDownloads`: it goes on while
    /// another project shows). Cancelling isn't an error.
    private func startDownload(_ title: String, estimate: Int64? = nil,
                               _ work: @escaping @MainActor (_ progress: @escaping @Sendable (FetchProgress) -> Void) async throws -> Void) {
        GitDownloads.shared.start(projectID: projectID, title: title, estimate: estimate, work: work) { error in
            isSignedIn = await GitHubAuth.shared.isSignedIn
            errorTitle = String(localized: "Couldn’t Clone")
            cloneError = error
        }
    }

    /// The space the project takes on this device, for its row.
    /// The clone or the files downloaded one by one, and the saved symbol index.
    private func refreshStorage() async {
        let projectID = projectID
        let record = await CloneStore.shared.record(forProject: projectID)
        var bytes = await Task.detached(priority: .utility) {
            (record.map { CloneIndex.shared.bytes(of: $0) } ?? 0) + ProjectSymbolIndex.savedBytes(projectID: projectID)
        }.value
        if record == nil, case .loaded(let project, _) = state, let prefix = project.rawURL(for: "")?.absoluteString {
            bytes += await DocumentStore.shared.downloadedBytes(under: prefix)
        }
        storedBytes = bytes
    }

    /// Clone, asking first on a mobile network when it's big.
    private func cloneTapped(_ project: ProjectInfo) {
        let bytes = repositoryBytes
        Task {
            await downloads.run(estimate: { bytes > 0 ? bytes : nil }, isCheap: true) { estimate in
                startClone(project, estimate: estimate)
            }
        }
    }

    /// Clones the project (the latest commit). Its files then come from the clone, and the ones
    /// downloaded one by one are deleted.
    private func startClone(_ project: ProjectInfo, estimate: Int64?) {
        startDownload(String(localized: "Cloning…"), estimate: estimate) { progress in
            try await CloneStore.shared.clone(project, progress: progress)
            clone = await CloneStore.shared.record(forProject: projectID)
            await loadRefs()  // the clone's, from now on
        }
    }

    /// Pull down on a cloned project: Git fetches the branch's latest commits (nothing changes
    /// on screen) and the remote's branches; Pull then shows how many are new.
    private func fetchClone() async {
        guard let ref = clone?.ref else { return }
        await downloads.run(estimate: { await CloneStore.shared.downloadEstimate(of: ref, projectID: projectID) }) { estimate in
            startDownload(String(localized: "Fetching…"), estimate: estimate) { progress in
                do {
                    try await CloneStore.shared.fetch(projectID: projectID, progress: progress)
                } catch {
                    // The branch list may have changed all the same (pruned, or this one deleted).
                    clone = await CloneStore.shared.record(forProject: projectID)
                    await loadRefs()
                    throw error
                }
                CloneChanges.shared.didFetch(projectID)  // a comparison's album follows its branches
                clone = await CloneStore.shared.record(forProject: projectID)
                await loadRefs()
            }
        }
    }

    /// Pull, asking first on a mobile network when it's big (commits a pull down found are
    /// downloaded already).
    private func pullTapped() {
        guard let ref = clone?.ref else { return }
        let isFetched = (clone?.newCommits ?? 0) > 0
        Task {
            await downloads.run(estimate: {
                if isFetched { return 0 }
                return await CloneStore.shared.downloadEstimate(of: ref, projectID: projectID)
            }) { estimate in pull(estimate: estimate) }
        }
    }

    /// Pull: the branch's latest commit, checked out; the file list from the clone.
    private func pull(estimate: Int64?) {
        guard case .loaded(let project, _) = state, let ref = clone?.ref else { return }
        startDownload(String(localized: "Pulling…"), estimate: estimate) { progress in
            try await CloneStore.shared.pull(projectID: projectID, progress: progress)
            CloneChanges.shared.didPull(projectID)  // the Code level shows the new files
            clone = await CloneStore.shared.record(forProject: projectID)
            if let tree = try? await CloneStore.shared.tree(projectID: projectID) {
                let (moved, tree) = try await ProjectStore.shared.setRef(ref.name, for: project.id, tree: tree)
                show(moved, tree)
            }
        }
    }

    /// The project at its (new) branch, with its file list.
    private func show(_ project: ProjectInfo, _ tree: ProjectTree) {
        repositoryBytes = Self.bytes(of: tree)
        state = .loaded(project, tree)
    }

    private func deleteClone() {
        Task {
            await CloneStore.shared.delete(projectID: projectID)
            clone = nil
            await loadRefs()  // GitHub's again
            await refreshStorage()
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

    /// The branch or tag the project shows: tap it for the picker (searchable, recent first).
    /// Choosing another lists its files (and switches the clone, if there is one).
    private func branchRow(project: ProjectInfo) -> some View {
        Button {
            isPickingRef = true
            if refs == nil { Task { await loadRefs() } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(verbatim: project.ref ?? "")
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
        .disabled(isSwitchingRef || download != nil)
        .accessibilityLabel("Branch")
        .accessibilityValue(Text(verbatim: project.ref ?? ""))
        // Touch and hold: compare the checkout with another branch, tag or commit (the clone has
        // what's compared).
        .contextMenu {
            if clone != nil {
                Button("Compare Against…", systemImage: "arrow.left.arrow.right") {
                    isPickingComparison = true
                    if refs == nil { Task { await loadRefs() } }
                }
            }
        }
        .sheet(isPresented: $isPickingRef, onDismiss: {
            comparing = pendingComparison
            pendingComparison = nil
        }) {
            branchPicker(current: project.ref)
        }
        .sheet(isPresented: $isPickingComparison, onDismiss: {
            comparing = pendingComparison
            pendingComparison = nil
        }) {
            comparisonPicker(current: project.ref)
        }
        .sheet(item: $comparing) { item in
            NavigationStack {
                CompareView(projectID: projectID, base: .checkedOut, head: item.head)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { comparing = nil }
                        }
                    }
            }
        }
    }

    /// Compare Against…: the same picker, but what's chosen is compared with the checkout (a
    /// branch, a tag, or a commit by its hash).
    private func comparisonPicker(current: String?) -> some View {
        BranchPicker(refs: refs, current: current, recent: RecentRefsStore.standard.names(for: projectID),
                     downloaded: fetchedRefs,
                     onChooseSide: { side in pendingComparison = Comparing(head: side) },
                     offersCheckedOut: false, title: "Compare Against",
                     onFetch: { await fetchRefs() })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    /// The branch row's picker. Comparing needs the clone.
    private func branchPicker(current: String?) -> some View {
        let downloaded: Set<String>? = clone == nil ? nil : fetchedRefs
        var onCompare: (@MainActor (GitRef) -> Void)?
        if clone != nil {
            onCompare = { ref in pendingComparison = Comparing(head: GitSide(ref)) }
        }
        return BranchPicker(refs: refs, current: current, recent: RecentRefsStore.standard.names(for: projectID),
                            downloaded: downloaded,
                            onChoose: { switchRef(to: $0) },
                            onCompare: onCompare,
                            // Not downloaded: asked in the picker itself, then pulled.
                            onPull: { ref in
                                RecentRefsStore.standard.add(ref.name, for: projectID)
                                pullRef(ref)
                            },
                            onFetch: { await fetchRefs() })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }

    /// Fetch in the branch picker: the branches and tags listed again from GitHub (a clone's
    /// gone ones deleted), nothing downloaded. Returns why it failed, or `nil`.
    private func fetchRefs() async -> String? {
        do {
            if clone != nil {
                try await CloneStore.shared.refreshRefs(projectID: projectID)
                clone = await CloneStore.shared.record(forProject: projectID)
                await loadRefs()
            } else {
                refs = try await ProjectStore.shared.refs(for: projectID, refresh: true)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The branches and tags: a cloned project's from the clone (listed from the remote when
    /// cloning and on each pull down), with which ones it has downloaded; otherwise GitHub's.
    private func loadRefs() async {
        if let clone, let remote = clone.remoteRefs {
            refs = remote
        } else {
            refs = try? await ProjectStore.shared.refs(for: projectID)
        }
        // Whatever the list came from: a clone without the remote's list still knows what it has.
        if clone != nil { fetchedRefs = await CloneStore.shared.fetchedRefs(projectID: projectID) }
    }

    /// Shows another branch or tag. A cloned project checks out one it has downloaded (offline,
    /// as it was fetched then: pull down for newer) and lists its files from the clone, with no
    /// network at all; one it hasn't downloaded asks to pull it (`refToPull`). A project that
    /// isn't cloned lists its files from GitHub.
    private func switchRef(to ref: GitRef) {
        guard case .loaded(let project, _) = state, ref.name != project.ref else { return }
        RecentRefsStore.standard.add(ref.name, for: projectID)
        if clone != nil, !fetchedRefs.contains(ref.name) {
            refToPull = ref
            return
        }
        isSwitchingRef = true
        Task {
            defer { isSwitchingRef = false }
            do {
                if clone != nil {
                    try await switchClone(to: ref, from: project, pulling: false)
                } else {
                    let (moved, tree) = try await ProjectStore.shared.setRef(ref.name, for: projectID)
                    show(moved, tree)
                    announceSwitch(from: project, to: moved)
                }
            } catch {
                errorTitle = clone?.isLocal == true ? String(localized: "Couldn’t Switch Branch")
                    : String(localized: "Couldn’t Clone")
                cloneError = error
            }
        }
    }

    /// Pull on a branch or tag the clone hasn't downloaded: its latest commit, checked out
    /// (asking first on a mobile network when it's big).
    private func pullRef(_ ref: GitRef) {
        guard case .loaded(let project, _) = state else { return }
        Task {
            await downloads.run(estimate: { await CloneStore.shared.downloadEstimate(of: ref, projectID: projectID) }) { estimate in
                startDownload(String(localized: "Pulling \(ref.name)…"), estimate: estimate) { progress in
                    try await switchClone(to: ref, from: project, pulling: true, progress: progress)
                    fetchedRefs.insert(ref.name)
                }
            }
        }
    }

    private func switchClone(to ref: GitRef, from project: ProjectInfo, pulling: Bool,
                             progress: @escaping @Sendable (FetchProgress) -> Void = { _ in }) async throws {
        let name = ref.name
        var moved = project
        moved.ref = name
        guard let prefix = moved.rawURL(for: "")?.absoluteString else { return }
        let tree = try await CloneStore.shared.switchTo(ref, projectID: projectID,
                                                        rawPrefix: prefix, pulling: pulling, progress: progress)
        clone = await CloneStore.shared.record(forProject: projectID)
        // A local folder's checkout: the branch it's on now (`origin/x` checks out as `x`).
        let shownName = clone?.isLocal == true ? (clone?.ref.name).flatMap { $0.isEmpty ? nil : $0 } ?? name : name
        let (shown, shownTree) = try await ProjectStore.shared.setRef(shownName, for: projectID, tree: tree)
        show(shown, shownTree)
        announceSwitch(from: project, to: shown)
        if clone?.isLocal != true { Task { await checkComparisons() } }
    }

    /// The diff albums that compare with the checkout (since they split): those whose split
    /// isn't in the clone now ask to load it.
    private func checkComparisons() async {
        var others: [String] = [], comparisons: [GitComparison] = []
        for album in AlbumStore.shared.albums(inProject: projectID) {
            guard case .comparison(let base, let head, let mode) = album.diff?.source, mode == .sinceSplit,
                  base == .checkedOut || head == .checkedOut
            else { continue }
            let comparison = GitComparison(base: base, head: head, mode: mode)
            do {
                _ = try await CloneStore.shared.compare(comparison, projectID: projectID)
            } catch CloneError.historyTooShort {
                for side in [base, head] where side != .checkedOut && !others.contains(side.label) {
                    others.append(side.label)
                }
                comparisons.append(comparison)
            } catch {
                continue  // a side not downloaded: its album offers to pull it
            }
        }
        guard !comparisons.isEmpty else { return }
        historyNeeded = HistoryNeeded(others: others, comparisons: comparisons)
    }

    /// Fetches older commits, a step at a time, until every comparison's split is in (or the
    /// whole history is). Shown in the Pull row, with Cancel.
    private func loadHistory(to needed: HistoryNeeded) {
        startDownload(String(localized: "Loading history…")) { _ in
            for comparison in needed.comparisons {
                try await CloneStore.shared.download(for: comparison, projectID: projectID)
            }
            CloneChanges.shared.didFetch(projectID)  // the albums show their changes
        }
    }

    /// The open file follows the project to its new branch or tag (`BrowserView`).
    private func announceSwitch(from old: ProjectInfo, to new: ProjectInfo) {
        guard let oldPrefix = old.rawURL(for: "")?.absoluteString, let newPrefix = new.rawURL(for: "")?.absoluteString
        else { return }
        CloneChanges.shared.didSwitch(projectID, from: oldPrefix, to: newPrefix)
    }

    nonisolated private static func bytes(of tree: ProjectTree) -> Int64 {
        tree.entries.reduce(0) { $0 + Int64($1.size ?? 0) }
    }
}
