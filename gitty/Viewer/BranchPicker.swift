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
/// after the last `/` counting most), the ones used lately first. On a cloned project, the ones
/// the clone hasn't downloaded say so (choosing one asks to pull it).
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
                    if !isDownloaded {
                        Text("Not downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if name == current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Current")
                }
            }
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
