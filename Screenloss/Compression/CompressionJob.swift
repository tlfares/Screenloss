import Foundation
import Observation
import UIKit

/// One run over a selection: encodes, saves the copies next to their
/// originals and hands the originals to `PendingRemovals`.
@MainActor
@Observable
final class CompressionJob: Identifiable {
    enum Phase: Equatable {
        case running
        /// The device is too full to keep going until originals are removed.
        case needsSpace
        case done
    }

    struct Issue: Identifiable {
        let id = UUID()
        let item: MediaItem
        let reason: String
    }

    let id = UUID()
    let items: [MediaItem]
    let recipe: CompressionRecipe

    private(set) var phase = Phase.running
    private(set) var processedCount = 0
    private(set) var replacedCount = 0
    private(set) var skippedCount = 0
    private(set) var failures: [Issue] = []
    private(set) var originalBytes: Int64 = 0
    private(set) var copyBytes: Int64 = 0
    private(set) var currentItem: MediaItem?
    private(set) var wasCancelled = false

    private var processedWeight: Double = 0
    private var currentFraction: Double = 0
    private let totalWeight: Double
    private var task: Task<Void, Never>?
    private var spaceContinuation: CheckedContinuation<Bool, Never>?
    private let background = BackgroundRun()
    private let pending: PendingRemovals
    private let workDirectory: URL

    var saving: Int64 { max(0, originalBytes - copyBytes) }
    var total: Int { items.count }
    var isFinished: Bool { phase == .done }

    /// Weighted by size, so a long video moves the bar as much as it takes.
    var fractionCompleted: Double {
        guard totalWeight > 0 else { return isFinished ? 1 : 0 }
        let current = Double(currentItem.map(Self.weight) ?? 0) * currentFraction
        return min(1, (processedWeight + current) / totalWeight)
    }

    init(items: [MediaItem], recipe: CompressionRecipe, pending: PendingRemovals) {
        // Photos first: quick wins, and the bar moves right away.
        self.items = items.filter { $0.kind == .photo } + items.filter { $0.kind == .video }
        self.recipe = recipe
        self.pending = pending
        totalWeight = items.reduce(0) { $0 + Self.weight($1) }
        workDirectory = URL.temporaryDirectory.appending(path: "Compressing/\(UUID().uuidString)")
    }

    private static func weight(_ item: MediaItem) -> Double { Double(max(item.size, 100_000)) }

    func start() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        UIApplication.shared.isIdleTimerDisabled = true
        background.begin(
            title: String(localized: "Compressing \(items.count) items"),
            subtitle: String(localized: "Starting…")
        ) { [weak self] in self?.cancel() }
        task = Task { await run() }
    }

    func cancel() {
        wasCancelled = true
        task?.cancel()
        resumeAfterSpace(false)
    }

    /// After the user removed originals to make room.
    func resumeAfterSpace(_ proceed: Bool) {
        spaceContinuation?.resume(returning: proceed)
        spaceContinuation = nil
    }

    // MARK: Run

    private func run() async {
        let photos = items.filter { $0.kind == .photo }
        let videos = items.filter { $0.kind == .video }

        // Photos go in small batches: a few encoding at once, saved together.
        var index = 0
        while index < photos.count, !Task.isCancelled {
            let batch = Array(photos[index..<min(index + 6, photos.count)])
            index += batch.count
            guard await ensureSpace(for: batch) else { break }
            let outcomes = await encode(batch)
            await commit(outcomes)
        }

        for video in videos where !Task.isCancelled {
            guard await ensureSpace(for: [video]) else { break }
            currentItem = video
            currentFraction = 0
            let outcome = await ItemProcessor.process(video, recipe: recipe, workDirectory: workDirectory) { fraction in
                Task { @MainActor in
                    guard self.currentItem?.id == video.id else { return }
                    self.currentFraction = fraction
                    self.background.update(progress: self.fractionCompleted, subtitle: nil)
                }
            }
            await commit([(video, outcome)])
        }

        currentItem = nil
        try? FileManager.default.removeItem(at: workDirectory)
        UIApplication.shared.isIdleTimerDisabled = false
        background.end(success: !wasCancelled)
        phase = .done
    }

    private func encode(_ batch: [MediaItem]) async -> [(MediaItem, ItemProcessor.Outcome)] {
        currentItem = batch.first
        currentFraction = 0
        let recipe = recipe
        let directory = workDirectory
        return await withTaskGroup(of: (Int, ItemProcessor.Outcome).self) { group in
            var results: [(Int, ItemProcessor.Outcome)] = []
            var next = 0
            // Three at a time keeps the encoder busy without piling up memory.
            func add() {
                let position = next
                let item = batch[position]
                next += 1
                group.addTask {
                    (position, await ItemProcessor.process(item, recipe: recipe, workDirectory: directory) { _ in })
                }
            }
            while next < min(3, batch.count) { add() }
            while let result = await group.next() {
                results.append(result)
                if next < batch.count, !Task.isCancelled { add() }
            }
            return results.sorted { $0.0 < $1.0 }.map { (batch[$0.0], $0.1) }
        }
    }

    private func commit(_ outcomes: [(MediaItem, ItemProcessor.Outcome)]) async {
        var ready: [(MediaItem, LibraryWriter.Replacement, Int64)] = []
        for (item, outcome) in outcomes {
            switch outcome {
            case .ready(let replacement, let size): ready.append((item, replacement, size))
            case .skipped: skippedCount += 1
            case .failed(let reason): failures.append(Issue(item: item, reason: reason))
            case .cancelled: break
            }
        }

        if !ready.isEmpty {
            var saved = await save(ready.map(\.1))
            // One bad file fails a whole change: retry the rest one by one.
            if saved.isEmpty, ready.count > 1 {
                for entry in ready {
                    saved.merge(await save([entry.1])) { $1 }
                }
            }
            var entries: [PendingRemovals.Entry] = []
            var levels: [String: QualityLevel] = [:]
            for (item, replacement, size) in ready {
                if let copyID = saved[item.id] {
                    entries.append(.init(originalID: item.id, copyID: copyID, originalSize: item.size, copySize: size))
                    levels[copyID] = item.kind == .photo ? recipe.photoQuality : recipe.videoQuality
                    replacedCount += 1
                    originalBytes += item.size
                    copyBytes += size
                } else {
                    failures.append(Issue(item: item, reason: String(localized: "Photos didn't accept the new file.")))
                    try? FileManager.default.removeItem(at: replacement.fileURL)
                    if let paired = replacement.pairedVideoURL { try? FileManager.default.removeItem(at: paired) }
                }
            }
            pending.add(entries, levels: levels)
        }

        for (item, outcome) in outcomes {
            if case .cancelled = outcome { continue }
            processedCount += 1
            processedWeight += Self.weight(item)
        }
        currentFraction = 0
        background.update(
            progress: fractionCompleted,
            subtitle: String(localized: "\(processedCount.formatted()) of \(total.formatted()) · \(ByteFormat.string(saving)) saved")
        )
    }

    private func save(_ replacements: [LibraryWriter.Replacement]) async -> [String: String] {
        (try? await LibraryWriter.save(replacements)) ?? [:]
    }

    /// Copies are added before originals go, so each needs room. When it
    /// runs out, the run waits for the user to remove what's done so far
    /// and empty Recently Deleted, which is when iOS gets the space back.
    private func ensureSpace(for batch: [MediaItem]) async -> Bool {
        let needed = batch.reduce(Int64(0)) { $0 + $1.size } + 150_000_000
        while Self.availableSpace() < needed {
            phase = .needsSpace
            background.update(progress: fractionCompleted, subtitle: String(localized: "Waiting for free space"))
            let proceed = await withCheckedContinuation { spaceContinuation = $0 }
            phase = .running
            guard proceed, !Task.isCancelled else { return false }
        }
        return true
    }

    private static func availableSpace() -> Int64 {
        let values = try? URL.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}
