import SwiftUI

/// A category's items as a grid, biggest first, to pick what to compress.
/// Tap to toggle; drag sideways across cells to select a run of them, like
/// in Photos.
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
    @State private var gridWidth: CGFloat = 0
    @State private var drag: DragSelection?

    private static let columns = 4
    private static let spacing: CGFloat = 2

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

    private var cellSide: CGFloat {
        let columns = CGFloat(Self.columns)
        return max(1, (gridWidth - Self.spacing * (columns - 1)) / columns)
    }

    var body: some View {
        let visible = visibleItems
        ScrollView {
            VStack(spacing: 14) {
                SelectionSummary(
                    selected: selectedItems,
                    total: items.count,
                    saving: library.estimatedSaving(of: selectedItems)
                )
                .padding(.horizontal, 16)

                if hasLoaded && visible.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: category.symbol,
                        description: Text(items.isEmpty ? "No \(category.title.lowercased()) in your library." : "No item here can be compressed.")
                    )
                    .padding(.top, 40)
                } else {
                    grid(visible)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDisabled(drag != nil)
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
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
        .sensoryFeedback(.selection, trigger: selection.count) { _, _ in drag != nil }
    }

    // MARK: Grid

    private func grid(_ visible: [MediaItem]) -> some View {
        let pendingIDs = pending.originalIDs
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cellSide), spacing: Self.spacing), count: Self.columns),
            spacing: Self.spacing
        ) {
            ForEach(visible) { item in
                AssetCell(
                    item: item,
                    side: cellSide,
                    isSelected: selection.contains(item.id),
                    isPending: pendingIDs.contains(item.id)
                )
                .accessibilityAction { tap(item) }
                .contextMenu {
                    if let blocker = item.blocker {
                        Text("\(blocker.label): \(blocker.explanation)")
                    } else {
                        Button(selection.contains(item.id) ? "Deselect" : "Select",
                               systemImage: selection.contains(item.id) ? "circle" : "checkmark.circle") { tap(item) }
                    }
                    Text("\(item.format.label) · \(ByteFormat.string(item.size)) · \(item.pixelWidth)×\(item.pixelHeight)")
                } preview: {
                    AssetThumbnail(id: item.id, contentMode: .fit)
                        .frame(width: 320, height: 320 * aspect(of: item))
                }
            }
        }
        // One recognizer for the whole grid: a tap gesture on every cell
        // makes UIKit weigh them all against each other on each touch.
        .onTapGesture { location in
            if let index = index(at: location, count: visible.count) { tap(visible[index]) }
        }
        .gesture(dragSelect(visible))
    }

    private func aspect(of item: MediaItem) -> CGFloat {
        guard item.pixelWidth > 0 else { return 1 }
        return min(1.8, max(0.5, CGFloat(item.pixelHeight) / CGFloat(item.pixelWidth)))
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
        withAnimation(Motion.snappy) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        }
    }

    private func isSelectable(_ item: MediaItem) -> Bool {
        item.isEligible && !library.isCompressedOriginal(item)
    }

    // MARK: Drag to select

    private struct DragSelection {
        let anchor: Int
        let selecting: Bool
        let base: Set<String>
    }

    /// A UIKit pan that only begins on a sideways swipe: vertical swipes
    /// never reach it and scroll the grid as usual.
    private func dragSelect(_ visible: [MediaItem]) -> some UIGestureRecognizerRepresentable {
        SidewaysPan { phase, start, location in
            switch phase {
            case .began:
                guard let anchor = index(at: start, count: visible.count) else { return }
                drag = DragSelection(anchor: anchor, selecting: !selection.contains(visible[anchor].id), base: selection)
                extend(to: location, in: visible)
            case .changed:
                extend(to: location, in: visible)
            case .ended:
                drag = nil
            }
        }
    }

    private func extend(to location: CGPoint, in visible: [MediaItem]) {
        guard let drag, let current = index(at: location, count: visible.count) else { return }
        var next = drag.base
        for item in visible[min(drag.anchor, current)...max(drag.anchor, current)] where isSelectable(item) {
            if drag.selecting { next.insert(item.id) } else { next.remove(item.id) }
        }
        if next != selection { selection = next }
    }

    private func index(at point: CGPoint, count: Int) -> Int? {
        let stride = cellSide + Self.spacing
        guard stride > 0, point.y >= 0 else { return nil }
        let column = min(Self.columns - 1, max(0, Int(point.x / stride)))
        let row = Int(point.y / stride)
        let index = row * Self.columns + column
        return index < count ? index : nil
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

struct AssetCell: View {
    let item: MediaItem
    let side: CGFloat
    let isSelected: Bool
    let isPending: Bool

    var body: some View {
        AssetThumbnail(id: item.id)
            .frame(width: side, height: side)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if item.isLivePhoto { Image(systemName: "livephoto") }
                    if item.kind == .video { Image(systemName: "video.fill") }
                    Text(ByteFormat.string(item.size))
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(5)
            }
            .overlay(alignment: .topLeading) {
                Text(item.format.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: .rect(cornerRadius: 4))
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) { badge.padding(5) }
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(.tint, lineWidth: 2.5)
                }
            }
            .opacity(item.isEligible ? 1 : 0.45)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo"), \(item.format.label), \(ByteFormat.string(item.size))")
            .accessibilityValue(isSelected ? "Selected" : "")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Symbols rather than stacked shapes, and no shadows: each shadow is
    /// an offscreen pass, on every cell, every frame it moves.
    @ViewBuilder
    private var badge: some View {
        if !item.isEligible {
            Image(systemName: "nosign")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        } else if isPending {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .tint)
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .tint)
                .background(Circle().fill(.white).padding(-1.5))
        } else {
            Image(systemName: "circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .background(Circle().fill(.black.opacity(0.25)))
        }
    }
}

/// A pan recognizer that refuses to start unless the finger first moves
/// mostly sideways, and never blocks the scroll view it sits in.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    enum Phase { case began, changed, ended }

    let onChange: (Phase, _ start: CGPoint, _ location: CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            let translation = recognizer.translation(in: recognizer.view)
            context.coordinator.start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            onChange(.began, context.coordinator.start, location)
        case .changed:
            onChange(.changed, context.coordinator.start, location)
        default:
            onChange(.ended, context.coordinator.start, location)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start = CGPoint.zero

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            // The screen edge stays the way back.
            if let window = pan.view?.window, pan.location(in: window).x < 24 { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        /// iOS 26 goes back on a sideways swipe from anywhere; on the grid,
        /// that swipe selects instead, as in Photos. The edge swipe isn't
        /// affected, and neither is scrolling.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            var responder: UIResponder? = recognizer.view
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    return other === navigation.interactiveContentPopGestureRecognizer
                }
                responder = current.next
            }
            return false
        }

        // Taps on cells and the scroll view keep working alongside it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
