import SwiftUI

/// A category's items as a grid, biggest first, to pick what to compress.
/// Tap to toggle; drag sideways across cells to select a run of them, like
/// in Photos (see `AssetGrid`).
struct BrowserView: View {
    let category: MediaCategory

    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending
    @Environment(CompressionSettings.self) private var settings
    @State private var items: [MediaItem] = []
    /// `items`, or only the compressible ones, kept rather than filtered on
    /// every update: a category can hold tens of thousands.
    @State private var visible: [MediaItem] = []
    /// Bumped whenever `visible` changes, so the grid can skip comparing it.
    @State private var visibleVersion = 0
    /// Each item's size and estimated saving, so the totals of a selection
    /// are a sum, not a pass of the estimator over every item.
    @State private var figures: [String: Figures] = [:]
    @State private var selectableCount = 0
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

    private struct Figures {
        let size: Int64
        let saving: Int64
    }

    private struct Totals {
        var count = 0
        var size: Int64 = 0
        var saving: Int64 = 0
    }

    private var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    private var totals: Totals {
        var totals = Totals(count: selection.count)
        for id in selection {
            guard let figure = figures[id] else { continue }
            totals.size += figure.size
            totals.saving += figure.saving
        }
        return totals
    }

    var body: some View {
        let totals = totals
        content(totals)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(.hidden, for: .tabBar)
            .safeAreaBar(edge: .bottom) { bottomBar(totals) }
            .sheet(isPresented: $showsReview) {
                ReviewSheet(items: selectedItems)
            }
            .task(id: library.version) { load() }
            // The estimates follow the settings and what's already compressed.
            .onChange(of: library.summaries) { _, _ in measure() }
            .onChange(of: onlyCompressible) { _, _ in filter() }
    }

    @ViewBuilder
    private func content(_ totals: Totals) -> some View {
        if hasLoaded && visible.isEmpty {
            ScrollView {
                VStack(spacing: 14) {
                    summary(totals).padding(.horizontal, 16)
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: category.symbol,
                        description: Text(items.isEmpty ? "Nothing in this category in your library." : "No item here can be compressed.")
                    )
                    .padding(.top, 40)
                }
            }
            .scrollIndicators(.hidden)
        } else {
            GeometryReader { proxy in
                AssetGrid(
                    items: visible,
                    itemsVersion: visibleVersion,
                    insets: proxy.safeAreaInsets,
                    selection: selection,
                    pendingIDs: pending.originalIDs,
                    tint: UIColor(AppTint.stored(tint).color),
                    isSelectable: isSelectable,
                    onTap: tap,
                    onSelectionChange: { selection = $0 }
                ) {
                    summary(totals)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func summary(_ totals: Totals) -> some View {
        SelectionSummary(count: totals.count, total: items.count, size: totals.size, saving: totals.saving)
    }

    private func tap(_ item: MediaItem) {
        if library.isCompressedOriginal(item) {
            showHint(String(localized: "Already compressed. Remove the originals from the Library tab."))
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
            .onChange(of: sort) { _, _ in
                items = sort.sorted(items)
                filter()
            }
        }
        // Each in its own capsule: sharing one, they sat at opposite ends
        // of it with a wide gap between.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            // The selection only ever holds selectable items.
            let allSelected = selectableCount > 0 && selection.count >= selectableCount
            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(items.lazy.filter(isSelectable).map(\.id))
            }
            .disabled(selectableCount == 0)
        }
    }

    private func bottomBar(_ totals: Totals) -> some View {
        VStack(spacing: 10) {
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
                    Text(totals.count == 0 ? "Select Items" : "Review \(totals.count) Items")
                        .font(.headline)
                    if totals.count > 0 {
                        Text("≈ \(ByteFormat.string(totals.saving)) to free")
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
            .disabled(totals.count == 0)
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
        let selectable = Set(fresh.lazy.filter(isSelectable).map(\.id))
        if !hasLoaded {
            // A category is opened to compress it: start with all of it,
            // minus originals that already have a copy and, unless asked
            // otherwise, the copies themselves.
            if category != .everything {
                selection = settings.skipsCompressed
                    ? Set(fresh.lazy.filter { isSelectable($0) && !library.isCompressedCopy($0) }.map(\.id))
                    : selectable
            }
            hasLoaded = true
        } else {
            selection.formIntersection(selectable)
        }
        selection.subtract(pending.originalIDs)
        selectableCount = selectable.count
        items = fresh
        measure()
        filter()
    }

    private func measure() {
        var figures: [String: Figures] = [:]
        figures.reserveCapacity(items.count)
        for item in items {
            figures[item.id] = Figures(size: item.size, saving: library.estimatedSaving(of: CollectionOfOne(item)))
        }
        self.figures = figures
    }

    private func filter() {
        visible = onlyCompressible ? items.filter(\.isEligible) : items
        visibleVersion += 1
    }
}

/// What's selected, and what it would come to.
private struct SelectionSummary: View {
    let count: Int
    let total: Int
    let size: Int64
    let saving: Int64

    var body: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 12) {
                Figure(value: "\(count.formatted())", label: "of \(total) selected")
                Figure(value: ByteFormat.string(size), label: "Selected size")
                Figure(value: "≈ \(ByteFormat.string(saving))", label: "To free", tinted: true)
            }
        }
        .animation(Motion.smooth, value: count)
    }
}
