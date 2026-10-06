import SwiftUI

@main
struct ScreenlossApp: App {
    @State private var library = LibraryStore()
    @State private var pending = PendingRemovals()
    @State private var jobs = JobCenter()
    @AppStorage(AppTint.storageKey) private var tint = AppTint.mint.rawValue

    init() {
        // Leftovers of a run the system ended: their copies were never saved.
        try? FileManager.default.removeItem(at: URL.temporaryDirectory.appending(path: "Compressing"))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(pending)
                .environment(jobs)
                .environment(CompressionSettings.shared)
                .tint((AppTint(rawValue: tint) ?? .mint).color)
                .preferredColorScheme(.dark)
        }
    }
}

/// The run in progress, if any. One at a time: they'd fight over the
/// encoder and over free space.
@MainActor
@Observable
final class JobCenter {
    var current: CompressionJob?

    func start(_ items: [MediaItem], library: LibraryStore, pending: PendingRemovals) {
        guard current == nil, !items.isEmpty else { return }
        library.isPaused = true
        let job = CompressionJob(items: items, recipe: CompressionSettings.shared.recipe, pending: pending)
        current = job
        job.start()
    }

    func close(library: LibraryStore) {
        current?.cancel()
        current = nil
        library.isPaused = false
    }
}
