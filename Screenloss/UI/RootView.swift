import SwiftUI

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending
    @Environment(JobCenter.self) private var jobs
    @Environment(CompressionSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = RootTab.library

    var body: some View {
        @Bindable var jobs = jobs
        Group {
            if library.hasAccess {
                TabView(selection: $tab) {
                    Tab("Library", systemImage: "photo.stack", value: RootTab.library) {
                        NavigationStack { HomeView() }
                    }
                    Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                        NavigationStack { SettingsView() }
                    }
                }
            } else {
                AccessView()
            }
        }
        .background(Color.screenBackground.ignoresSafeArea())
        .fullScreenCover(item: $jobs.current) { job in
            JobView(job: job)
        }
        .task {
            library.start()
            pending.prune()
        }
        .onChange(of: scenePhase) { _, phase in
            // Access can change in Settings while the app is away.
            if phase == .active { library.start() }
        }
        .onChange(of: settings.recipe) { _, recipe in
            library.update(recipe: recipe)
        }
        .onChange(of: pending.originalIDs, initial: true) { _, ids in
            library.update(compressedOriginals: ids, copyLevels: pending.copyLevels)
        }
        .onChange(of: pending.copyLevels) { _, levels in
            library.update(compressedOriginals: pending.originalIDs, copyLevels: levels)
        }
    }
}

enum RootTab: Hashable { case library, settings }
