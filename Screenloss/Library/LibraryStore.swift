import Foundation
import Observation
import Photos

/// The library as the app sees it: access, every item, and per-category
/// totals. Rescans itself when the library changes.
@MainActor
@Observable
final class LibraryStore {
    nonisolated struct Summary: Equatable, Sendable {
        var count = 0
        var size: Int64 = 0
        var eligibleCount = 0
        var estimatedSaving: Int64 = 0
    }

    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var items: [MediaItem] = []
    private(set) var summaries: [MediaCategory: Summary] = [:]
    private(set) var hasScanned = false
    /// Bumped after every scan, for views that derive lists from `items`.
    private(set) var version = 0
    private(set) var isScanning = false
    private(set) var scanProgress: (done: Int, total: Int) = (0, 0)

    /// While a run is saving copies, changes are expected: scan once it ends.
    var isPaused = false {
        didSet { if !isPaused, needsRescan { scheduleRescan() } }
    }

    private var observer: ChangeObserver?
    private var needsRescan = false
    private var rescanTask: Task<Void, Never>?
    private var summarizeTask: Task<Void, Never>?
    private var recipe = CompressionSettings.shared.recipe
    /// Originals that already have a copy: counting them again would
    /// promise space twice.
    private var compressedOriginals = Set<String>()
    private var copyLevels: [String: QualityLevel] = [:]

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var totalSize: Int64 { summaries[.everything]?.size ?? 0 }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess { start() }
    }

    func start() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else { return }
        if observer == nil {
            let observer = ChangeObserver { [weak self] in self?.libraryDidChange() }
            PHPhotoLibrary.shared().register(observer)
            self.observer = observer
        }
        if !hasScanned { scan() }
    }

    func items(in category: MediaCategory) -> [MediaItem] {
        items.filter(category.contains)
    }

    /// Totals follow the settings: a stronger level saves more.
    func update(recipe: CompressionRecipe) {
        guard recipe != self.recipe else { return }
        self.recipe = recipe
        summarize()
    }

    func update(compressedOriginals ids: Set<String>, copyLevels levels: [String: QualityLevel]) {
        guard ids != compressedOriginals || levels != copyLevels else { return }
        compressedOriginals = ids
        copyLevels = levels
        summarize()
    }

    func isCompressedOriginal(_ item: MediaItem) -> Bool {
        compressedOriginals.contains(item.id)
    }

    /// A copy this app made, as recorded when it was saved.
    func isCompressedCopy(_ item: MediaItem) -> Bool {
        copyLevels[item.id] != nil
    }

    func estimatedSaving(of items: some Sequence<MediaItem>) -> Int64 {
        savings.saving(of: items)
    }

    /// What the estimates depend on, to work them out off the main actor.
    var savings: Savings { savings(with: recipe) }

    func savings(with recipe: CompressionRecipe) -> Savings {
        Savings(recipe: recipe, compressedOriginals: compressedOriginals, copyLevels: copyLevels)
    }

    nonisolated struct Savings: Sendable {
        let recipe: CompressionRecipe
        let compressedOriginals: Set<String>
        let copyLevels: [String: QualityLevel]

        func saving(of item: MediaItem) -> Int64 {
            compressedOriginals.contains(item.id) ? 0 : SavingsEstimator.estimatedSaving(of: item, recipe: recipe, madeAt: copyLevels[item.id])
        }

        func saving(of items: some Sequence<MediaItem>) -> Int64 {
            items.reduce(0) { $0 + saving(of: $1) }
        }
    }

    // MARK: Scanning

    func scan() {
        guard hasAccess, !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        needsRescan = false
        Task {
            let result = await Self.performScan { done, total in
                Task { @MainActor in self.scanProgress = (done, total) }
            }
            items = result.items
            version += 1
            hasScanned = true
            isScanning = false
            summarize()
            if needsRescan, !isPaused { scheduleRescan() }
        }
    }

    @concurrent
    private static func performScan(progress: @escaping @Sendable (Int, Int) -> Void) async -> LibraryScanner.Result {
        let result = LibraryScanner.scan(cache: ScanCacheStore.load(), progress: progress)
        ScanCacheStore.save(result.cache)
        return result
    }

    private func libraryDidChange() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        needsRescan = true
        guard !isPaused else { return }
        scheduleRescan()
    }

    /// Changes come in bursts: wait for them to settle.
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            scan()
        }
    }

    /// Done off the main actor once there are totals to show: a library of
    /// tens of thousands would otherwise stall whatever is animating.
    private func summarize() {
        let items = items
        let savings = savings
        guard !summaries.isEmpty else {
            summaries = Self.summaries(of: items, savings: savings)
            return
        }
        summarizeTask?.cancel()
        summarizeTask = Task {
            let result = await Self.summarizeInBackground(items, savings: savings)
            guard !Task.isCancelled else { return }
            summaries = result
        }
    }

    @concurrent
    private static func summarizeInBackground(_ items: [MediaItem], savings: Savings) async -> [MediaCategory: Summary] {
        summaries(of: items, savings: savings)
    }

    nonisolated private static func summaries(of items: [MediaItem], savings: Savings) -> [MediaCategory: Summary] {
        var result = Dictionary(uniqueKeysWithValues: MediaCategory.allCases.map { ($0, Summary()) })
        for item in items {
            let saving = savings.saving(of: item)
            for category in MediaCategory.allCases where category.contains(item) {
                var summary = result[category] ?? Summary()
                summary.count += 1
                summary.size += item.size
                if item.isEligible, !savings.compressedOriginals.contains(item.id) {
                    summary.eligibleCount += 1
                    summary.estimatedSaving += saving
                }
                result[category] = summary
            }
        }
        return result
    }
}

/// PhotoKit reports changes on its own queue; this hops them to the main actor.
nonisolated private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in onChange() }
    }
}
