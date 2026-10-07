import SwiftUI

/// A category's items as a grid, biggest first, to pick what to compress.
/// Tap to toggle; drag sideways across cells to select a run of them, like
/// in Photos (see `AssetGrid`).
struct BrowserView: View {
    let category: MediaCategory

    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending
    @State private var items: [MediaItem] = []
    @State private var selection = Set<String>()
    @State private var sort: BrowserSort
    @State private var onlyCompressible = false
    @State private var hasLoaded = false
    @State private var showsReview = false
    @State private var hint: String?
    @State private var hintTask: Task<Void, Never>?
    @AppStorage(AppTint.storageKey) private var tint = AppTint.mint.rawValue

    init(category: MediaCategory) {
        self.category = category
        _sort = State(initialValue: category.defaultSort)
    }

    private var visibleItems: [MediaItem] {
        onlyCompressible ? items.filter(\.isEligible) : items
    }

    private var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    var body: some View {
        let visible = visibleItems
        content(visible)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(.hidden, for: .tabBar)
            .safeAreaBar(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showsReview) {
                ReviewSheet(items: selectedItems)
            }
            .task(id: library.version) { load() }
    }

    @ViewBuilder
    private func content(_ visible: [MediaItem]) -> some View {
        if hasLoaded && visible.isEmpty {
            ScrollView {
                VStack(spacing: 14) {
                    summary.padding(.horizontal, 16)
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: category.symbol,
                        description: Text(items.isEmpty ? "No \(category.title.lowercased()) in your library." : "No item here can be compressed.")
                    )
                    .padding(.top, 40)
                }
            }
            .scrollIndicators(.hidden)
        } else {
            GeometryReader { proxy in
                AssetGrid(
                    items: visible,
                    insets: proxy.safeAreaInsets,
                    selection: selection,
                    pendingIDs: pending.originalIDs,
                    tint: UIColor(AppTint.stored(tint).color),
                    isSelectable: isSelectable,
                    onTap: tap,
                    onSelectionChange: { selection = $0 }
                ) {
                    summary
                }
                .ignoresSafeArea()
            }
        }
    }

    private var summary: some View {
        SelectionSummary(
            selected: selectedItems,
            total: items.count,
            saving: library.estimatedSaving(of: selectedItems)
        )
    }

    private func tap(_ item: MediaItem) {
        if library.isCompressedOriginal(item) {
            showHint("Already compressed. Remove the originals from the Library tab.")
            return
        }
        guard item.isEligible else {
            showHint(item.blocker.map { "\($0.label) — \($0.explanation)" } ?? "")
            return
        }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    private func isSelectable(_ item: MediaItem) -> Bool {
        item.isEligible && !library.isCompressedOriginal(item)
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(BrowserSort.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                Toggle("Only Compressible", systemImage: "line.3.horizontal.decrease", isOn: $onlyCompressible)
            } label: {
                Label("Sort and Filter", systemImage: "arrow.up.arrow.down")
            }
            .onChange(of: sort) { _, _ in withAnimation(Motion.smooth) { items = sort.sorted(items) } }
        }
        // Each in its own capsule: sharing one, they sat at opposite ends
        // of it with a wide gap between.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            let eligible = items.filter(isSelectable)
            let allSelected = !eligible.isEmpty && eligible.allSatisfy { selection.contains($0.id) }
            Button(allSelected ? "Deselect All" : "Select All") {
                withAnimation(Motion.snappy) {
                    selection = allSelected ? [] : Set(eligible.map(\.id))
                }
            }
            .disabled(eligible.isEmpty)
        }
    }

    private var bottomBar: some View {
        let selected = selectedItems
        return VStack(spacing: 10) {
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                showsReview = true
            } label: {
                VStack(spacing: 2) {
                    Text(selected.isEmpty ? "Select Items" : "Review \(selected.count.formatted()) \(selected.count == 1 ? "Item" : "Items")")
                        .font(.headline)
                    if !selected.isEmpty {
                        Text("≈ \(ByteFormat.string(library.estimatedSaving(of: selected))) to free")
                            .font(.caption.weight(.medium))
                            .opacity(0.85)
                    }
                }
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(Motion.snappy, value: hint)
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        withAnimation(Motion.snappy) { hint = text }
        hintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.snappy) { hint = nil }
        }
    }

    private func load() {
        let fresh = sort.sorted(library.items(in: category))
        let ids = Set(fresh.map(\.id))
        let pendingIDs = pending.originalIDs
        if !hasLoaded {
            // A category is opened to compress it: start with all of it,
            // minus originals that already have a copy.
            if category != .everything {
                selection = Set(fresh.lazy.filter(isSelectable).map(\.id))
            }
            hasLoaded = true
        } else {
            selection.formIntersection(ids)
        }
        selection.subtract(pendingIDs)
        items = fresh
    }
}

/// What's selected, and what it would come to.
private struct SelectionSummary: View {
    let selected: [MediaItem]
    let total: Int
    let saving: Int64

    var body: some View {
        let size = selected.reduce(Int64(0)) { $0 + $1.size }
        GlassCard(padding: 16) {
            HStack(spacing: 12) {
                Figure(value: "\(selected.count.formatted())", label: "of \(total.formatted()) selected")
                Figure(value: ByteFormat.string(size), label: "Selected size")
                Figure(value: "≈ \(ByteFormat.string(saving))", label: "To free", tinted: true)
            }
        }
        .animation(Motion.smooth, value: selected.count)
    }
}
