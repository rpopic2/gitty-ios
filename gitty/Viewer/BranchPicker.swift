import SwiftUI

/// The branches and tags you switched a project to lately, newest first, on this device.
nonisolated struct RecentRefsStore: @unchecked Sendable {
    static let standard = RecentRefsStore(defaults: .standard)
    static let limit = 5

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func names(for projectID: String) -> [String] {
        defaults.stringArray(forKey: key(projectID)) ?? []
    }

    func add(_ name: String, for projectID: String) {
        let names = [name] + self.names(for: projectID).filter { $0 != name }
        defaults.set(Array(names.prefix(Self.limit)), forKey: key(projectID))
    }

    private func key(_ projectID: String) -> String { "recentRefs:" + projectID }
}

/// Choosing a branch or tag: searched as symbols are (`SymbolSearch.matchingNames`, the part
/// after the last `/` counting most), the ones used lately first. On a cloned project, each says
/// whether the clone has it (an iPhone) or not (a cloud: choosing one asks to pull it).
struct BranchPicker: View {
    let refs: ProjectRefs?
    let current: String?
    let recent: [String]
    /// A cloned project's downloaded branches and tags (`nil`: not cloned, all of them can be
    /// shown).
    let downloaded: Set<String>?
    let onChoose: @MainActor (_ name: String, _ isTag: Bool) -> Void
    /// Choosing a comparison's side instead (`CompareView`): the checkout and commits (typed
    /// as hashes) can be chosen too.
    var onChooseSide: (@MainActor (GitSide) -> Void)? = nil
    /// Choosing a side: the checkout is offered too (not when it's what's compared against).
    var offersCheckedOut = true
    /// Instead of "Branches and Tags" (or "Compare", choosing a side).
    var title: LocalizedStringKey? = nil
    /// Touch and hold a branch or tag: Compare with Checked Out (`nil`: not offered).
    var onCompare: (@MainActor (_ name: String, _ isTag: Bool) -> Void)? = nil
    /// Choosing one the clone hasn't downloaded: asked right here (Pull downloads it and shows
    /// it), instead of once the picker has gone. `nil`: `onChoose` decides.
    var onPull: (@MainActor (_ name: String, _ isTag: Bool) -> Void)? = nil
    /// Fetch, top right: the remote's branches and tags listed again (the ones it doesn't have
    /// any more go). Returns why it failed, or `nil`.
    var onFetch: (@MainActor () async -> String?)? = nil

    @State private var query = ""
    /// A branch or tag that isn't downloaded, chosen: Pull it?
    @State private var toPull: PendingPull?
    @State private var isFetching = false
    @State private var fetchError: String?

    private struct PendingPull: Identifiable {
        let name: String
        let isTag: Bool
        var id: String { name }
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let refs {
                    list(refs)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title ?? (onChooseSide == nil ? "Branches and Tags" : "Compare"))
            .confirmationDialog(toPull.map { String(localized: "“\($0.name)” isn’t downloaded") } ?? "",
                                isPresented: Binding(get: { toPull != nil }, set: { if !$0 { toPull = nil } }),
                                titleVisibility: .visible, presenting: toPull) { ref in
                Button("Pull \(ref.name)") {
                    dismiss()
                    onPull?(ref.name, ref.isTag)
                }
            } message: { _ in
                Text("Pull downloads its latest commit into the clone and shows its files.")
            }
            .alert("Couldn’t Fetch", isPresented: Binding(get: { fetchError != nil }, set: { if !$0 { fetchError = nil } }),
                   presenting: fetchError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: onChooseSide == nil ? Text("Search Branches and Tags")
                                                    : Text("Branch, Tag or Commit Hash"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                // Swipe the sheet down to close it. Fetch lists GitHub's branches and tags again.
                if let onFetch {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isFetching {
                            ProgressView()
                        } else {
                            Button("Fetch") {
                                isFetching = true
                                Task {
                                    fetchError = await onFetch()
                                    isFetching = false
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func list(_ refs: ProjectRefs) -> some View {
        let branches = SymbolSearch.matchingNames(query, in: refs.branches)
        let tags = SymbolSearch.matchingNames(query, in: refs.tags)
        let recentShown = query.isEmpty ? recent.filter { refs.branches.contains($0) || refs.tags.contains($0) } : []
        return List {
            if let onChooseSide {
                // A comparison's side: the checkout, or the commit a typed hash names.
                Section {
                    if query.isEmpty, offersCheckedOut {
                        sideRow(.checkedOut, onChooseSide)
                    }
                    if let hash = GitSide.commitHash(in: query) {
                        sideRow(.commit(hash), onChooseSide)
                    }
                }
            }
            if !recentShown.isEmpty {
                Section("Recent") {
                    ForEach(recentShown, id: \.self) { name in
                        row(name, isTag: !refs.branches.contains(name))
                    }
                }
            }
            if !branches.isEmpty {
                Section("Branches") {
                    ForEach(branches, id: \.self) { row($0, isTag: false) }
                }
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { row($0, isTag: true) }
                }
            }
            if branches.isEmpty && tags.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func sideRow(_ side: GitSide, _ choose: @escaping @MainActor (GitSide) -> Void) -> some View {
        Button {
            dismiss()
            choose(side)
        } label: {
            Label(side == .checkedOut ? side.label : String(localized: "Commit \(side.label)"),
                  systemImage: side.systemImage)
                .foregroundStyle(.primary)
        }
    }

    private func row(_ name: String, isTag: Bool) -> some View {
        let isDownloaded = downloaded?.contains(name) ?? true
        return Button {
            if onChooseSide == nil, !isDownloaded, name != current, onPull != nil {
                toPull = PendingPull(name: name, isTag: isTag)
                return
            }
            dismiss()
            if let onChooseSide {
                onChooseSide(isTag ? .tag(name) : .branch(name))
            } else if name != current {
                onChoose(name, isTag)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isTag ? "tag" : "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if name == current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current")
                }
                if downloaded != nil {
                    // Like Files' iCloud items: on this iPhone, or only on GitHub.
                    Image(systemName: isDownloaded ? "iphone" : "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isDownloaded ? "Downloaded" : "Not downloaded")
                }
            }
            .opacity(isDownloaded ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .contextMenu {
            if let onCompare, name != current {
                Button("Compare with Checked Out", systemImage: "arrow.left.arrow.right") {
                    dismiss()
                    onCompare(name, isTag)
                }
            }
        }
    }
}
