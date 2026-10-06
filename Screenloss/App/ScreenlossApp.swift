import SwiftUI

@main
struct ScreenlossApp: App {
    @State private var library = LibraryStore()
    @State private var pending = PendingRemovals()
    @State private var jobs = JobCenter()
    @AppStorage(AppTint.storageKey) private var tint = AppTint.mint.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.dark.rawValue

    init() {
        // Leftovers of a run the system ended: their copies were never saved.
        try? FileManager.default.removeItem(at: URL.temporaryDirectory.appending(path: "Compressing"))
        AppAppearance.startApplying()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(pending)
                .environment(jobs)
                .environment(CompressionSettings.shared)
                .tint(AppTint.stored(tint).color)
                .onChange(of: appearance, initial: true) { old, new in AppAppearance.apply(animated: old != new) }
                .task {
                    // A tint removed in an update falls back to mint, and
                    // its icon, which is gone too, to the primary one.
                    if AppTint(rawValue: tint) == nil { tint = AppTint.mint.rawValue }
                    AppTint.stored(tint).applyIcon()
                }
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
