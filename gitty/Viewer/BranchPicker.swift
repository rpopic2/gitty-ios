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
/// whether the clone has it (an iPhone) or not (a cloud: choosing one asks to pull it); swipe a
/// downloaded one to delete it from the clone, and hold it to see what that would free.
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
    /// Touch and hold a branch or tag: Compare with Checked Out (`nil`: not offered).
    var onCompare: (@MainActor (_ name: String, _ isTag: Bool) -> Void)? = nil
    /// Swipe a downloaded one (not the current): delete it from the clone (`nil`: not offered).
    var onDelete: (@MainActor (_ name: String, _ isTag: Bool) -> Void)? = nil
    /// Holding a downloaded one: roughly what deleting it frees.
    var bytesFreed: (@MainActor (_ name: String, _ isTag: Bool) async -> Int64?)? = nil
    /// Being deleted now.
    var deleting: Set<String> = []

    @State private var query = ""
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
            .navigationTitle(onChooseSide == nil ? "Branches and Tags" : "Compare")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: onChooseSide == nil ? Text("Search Branches and Tags")
                                                    : Text("Branch, Tag or Commit Hash"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                    if query.isEmpty {
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
        let dismiss = dismiss
        var compare: (@MainActor () -> Void)?
        if let onCompare {
            compare = {
                dismiss()
                onCompare(name, isTag)
            }
        }
        return Button {
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
                if deleting.contains(name) {
                    ProgressView()
                } else if downloaded != nil {
                    // Like Files' iCloud items: on this iPhone, or only on GitHub.
                    Image(systemName: isDownloaded ? "iphone" : "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isDownloaded ? "Downloaded" : "Not downloaded")
                }
            }
            .opacity(isDownloaded ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .disabled(deleting.contains(name))
        .swipeActions {
            if let onDelete, downloaded != nil, isDownloaded, name != current, !deleting.contains(name) {
                Button(role: .destructive) { onDelete(name, isTag) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .modifier(RefMenu(name: name, isTag: isTag, isDownloaded: downloaded != nil && isDownloaded,
                          isCurrent: name == current, onCompare: compare, bytesFreed: bytesFreed))
    }
}

/// A branch or tag's long-press menu: Compare with Checked Out; on a downloaded one, a preview
/// with roughly what deleting it from the clone would free.
private struct RefMenu: ViewModifier {
    let name: String
    let isTag: Bool
    let isDownloaded: Bool
    let isCurrent: Bool
    let onCompare: (@MainActor () -> Void)?
    let bytesFreed: (@MainActor (_ name: String, _ isTag: Bool) async -> Int64?)?

    func body(content: Content) -> some View {
        if isDownloaded, let bytesFreed {
            content.contextMenu {
                items
            } preview: {
                RefStoragePreview(name: name, isTag: isTag, isCurrent: isCurrent, bytesFreed: bytesFreed)
            }
        } else {
            content.contextMenu { items }
        }
    }

    @ViewBuilder private var items: some View {
        if let onCompare, !isCurrent {
            Button("Compare with Checked Out", systemImage: "arrow.left.arrow.right", action: onCompare)
        }
    }
}

/// A downloaded branch or tag held: its name, and what deleting it would free, worked out as
/// it shows (it goes through the clone's objects, a moment on a big one).
private struct RefStoragePreview: View {
    let name: String
    let isTag: Bool
    let isCurrent: Bool
    let bytesFreed: @MainActor (_ name: String, _ isTag: Bool) async -> Int64?

    @State private var bytes: Int64?
    @State private var isDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: isTag ? "tag" : "arrow.triangle.branch")
                .font(.headline.monospaced())
                .lineLimit(2)
            Group {
                if isCurrent {
                    Text("Checked out: switch to another to delete it.")
                } else if !isDone {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Working out its size…")
                    }
                } else if let bytes {
                    Text("Deleting it frees up to \(bytes.formatted(.byteCount(style: .file))).")
                } else {
                    Text("Its size couldn’t be worked out.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .task {
            guard !isCurrent else { return }
            bytes = await bytesFreed(name, isTag)
            isDone = true
        }
    }
}
