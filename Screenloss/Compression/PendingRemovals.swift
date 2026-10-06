import Foundation
import Observation
import Photos

/// Originals whose smaller copy is already in the library, waiting for the
/// user to let iOS delete them. Kept on disk: if the app is closed before
/// that, nothing is forgotten and nothing is duplicated for good.
@MainActor
@Observable
final class PendingRemovals {
    nonisolated struct Entry: Codable, Hashable, Sendable {
        let originalID: String
        let copyID: String
        let originalSize: Int64
        let copySize: Int64
        var saving: Int64 { max(0, originalSize - copySize) }
    }

    private(set) var entries: [Entry] = []
    /// Every copy this app made, with the level it was made at. Encoding it
    /// again at that level or a gentler one would give nothing back.
    private(set) var copyLevels: [String: QualityLevel] = [:]
    private(set) var isRemoving = false
    /// Bytes given back by originals this app removed, over its lifetime.
    private(set) var lifetimeFreed: Int64 = UserDefaults.standard.object(forKey: "lifetimeFreed") as? Int64 ?? 0

    var count: Int { entries.count }
    var saving: Int64 { entries.reduce(0) { $0 + $1.saving } }
    var originalIDs: Set<String> { Set(entries.map(\.originalID)) }

    private let url = URL.applicationSupportDirectory.appending(path: "pending-removals.json")
    private let copiesURL = URL.applicationSupportDirectory.appending(path: "copy-levels.json")

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        if let data = try? Data(contentsOf: copiesURL), let saved = try? JSONDecoder().decode([String: QualityLevel].self, from: data) {
            copyLevels = saved
        }
    }

    func add(_ new: [Entry], levels: [String: QualityLevel]) {
        guard !new.isEmpty else { return }
        copyLevels.merge(levels) { $1 }
        let known = originalIDs
        entries += new.filter { !known.contains($0.originalID) }
        persist()
    }

    /// Forgets originals the user already deleted, and pairs whose copy is
    /// gone (deleting the original then would lose the photo).
    func prune() {
        let ids = entries.flatMap { [$0.originalID, $0.copyID] }
        let existing = LibraryWriter.existing(ids)
        let kept = entries.filter { existing.contains($0.originalID) && existing.contains($0.copyID) }
        if kept.count != entries.count {
            entries = kept
            persist()
        }
    }

    enum Outcome { case removed(Int64), declined, failed(String) }

    /// Shows iOS's confirmation and removes the originals it allows.
    func removeAll() async -> Outcome {
        guard !isRemoving else { return .declined }
        prune()
        let batch = entries
        guard !batch.isEmpty else { return .removed(0) }
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await LibraryWriter.deleteAssets(batch.map(\.originalID))
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return .declined
        } catch {
            if (error as NSError).code == PHPhotosError.userCancelled.rawValue { return .declined }
            return .failed(error.localizedDescription)
        }
        let remaining = LibraryWriter.existing(batch.map(\.originalID))
        let removed = batch.filter { !remaining.contains($0.originalID) }
        let freed = removed.reduce(0) { $0 + $1.saving }
        let removedIDs = Set(removed.map(\.originalID))
        entries.removeAll { removedIDs.contains($0.originalID) }
        lifetimeFreed += freed
        UserDefaults.standard.set(lifetimeFreed, forKey: "lifetimeFreed")
        persist()
        return .removed(freed)
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(copyLevels) {
            try? data.write(to: copiesURL, options: .atomic)
        }
    }
}
