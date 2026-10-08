import SwiftUI

/// The last stop before a run: how hard to compress, what that looks like
/// on a real item, and what happens to the originals.
struct ReviewSheet: View {
    let plan: Plan

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending
    @Environment(JobCenter.self) private var jobs
    @Environment(CompressionSettings.self) private var settings

    /// The estimate for the current settings, worked out off the main actor
    /// so the bar and figures can animate without a stall.
    @State private var saving: Int64?

    /// What a run would cover, sorted once when the sheet is opened.
    struct Plan: Identifiable {
        let id = UUID()
        let run: [MediaItem]
        let skipped: Int
        let size: Int64
        let photos: [MediaItem]
        let videos: [MediaItem]
        let livePhotos: [MediaItem]
        let largestPhoto: MediaItem?

        /// Originals that already have a copy are left out: a second copy
        /// would only duplicate it.
        init(selected: [MediaItem], excluding done: Set<String>) {
            run = selected.filter { $0.isEligible && !done.contains($0.id) }
            skipped = selected.count - run.count
            size = run.reduce(0) { $0 + $1.size }
            photos = run.filter { $0.kind == .photo }
            videos = run.filter { $0.kind == .video }
            livePhotos = run.filter(\.isLivePhoto)
            largestPhoto = photos.max { $0.size < $1.size }
        }
    }

    private var photos: [MediaItem] { plan.photos }
    private var videos: [MediaItem] { plan.videos }
    private var livePhotos: [MediaItem] { plan.livePhotos }
    private var largestPhoto: MediaItem? { plan.largestPhoto }

    var body: some View {
        @Bindable var settings = settings
        let run = plan.run
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    totals

                    if !livePhotos.isEmpty {
                        liveSettings
                    }
                    if let sample = photos.first {
                        photoSettings(sample: sample)
                    }
                    if !videos.isEmpty {
                        videoSettings
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $settings.removeOriginals) {
                                Label("Remove originals when done", systemImage: "trash")
                            }
                            Text(settings.removeOriginals
                                 ? "iOS will ask you first. Originals then go to Recently Deleted for 30 days."
                                 : "Originals stay in the library next to their copies. You can remove them later from the Library tab.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    KeptNote()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            // The Compress button floats on the content: no frosted band
            // behind it, which showed as a gray zone when it was pressed.
            .scrollEdgeEffectHidden(true, for: .bottom)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    let items = run
                    dismiss()
                    jobs.start(items, library: library, pending: pending)
                } label: {
                    Text("Compress \(run.count) Items")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(run.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .task(id: settings.recipe) {
            let savings = library.savings(with: settings.recipe)
            let run = plan.run
            let result = await Self.estimate(run, savings: savings)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.smooth) { saving = result }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.screenBackground)
    }

    @concurrent
    private static func estimate(_ run: [MediaItem], savings: LibraryStore.Savings) async -> Int64 {
        savings.saving(of: run)
    }

    private var totals: some View {
        let size = plan.size
        let saving = saving ?? library.estimatedSaving(of: plan.run)
        let skipped = plan.skipped
        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Figure(value: plan.run.count.formatted(), label: plan.run.count == 1 ? "Item" : "Items")
                    Figure(value: ByteFormat.string(size), label: "Now")
                    Figure(value: "≈ \(ByteFormat.string(size - saving))", label: "After", tinted: true)
                }
                SavingsBar(total: size, saving: saving)
                if skipped > 0 {
                    Text("\(skipped) items already compressed and waiting for their originals to be removed are left out.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func photoSettings(sample: MediaItem) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("\(photos.count) Photos", symbol: "photo")
            GlassSegmentedPicker("Photo quality", options: QualityLevel.allCases, selection: $settings.photoQuality, title: \.title, symbol: \.symbol, commitsWhenSettled: true)
                .disabled(settings.photoFormat.isLossless)
                .opacity(settings.photoFormat.isLossless ? 0.4 : 1)
            Text(settings.photoFormat.isLossless ? String(localized: "Lossless in JPEG XL: the level doesn't apply.") : settings.photoQuality.photoDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)

            GlassCard(padding: 16) {
                VStack(spacing: 14) {
                    HStack {
                        Text("Format")
                        Spacer()
                        Picker("Format", selection: $settings.photoFormat) {
                            ForEach(PhotoFormat.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    Text(settings.photoFormat.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(Motion.smooth, value: settings.photoFormat)
                    Divider()
                    HStack {
                        Text("Maximum Size")
                        Spacer()
                        Picker("Maximum Size", selection: $settings.photoLimit) {
                            ForEach(PhotoSizeLimit.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .font(.subheadline)
            }
            ComparisonCard(item: largestPhoto ?? sample, recipe: settings.recipe)
        }
    }

    private var liveSettings: some View {
        @Bindable var settings = settings
        let count = livePhotos.count
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("\(count) Live Photos", symbol: "livephoto")
            GlassSegmentedPicker("Live Photos", options: LivePhotoMode.allCases, selection: $settings.livePhotoMode, title: \.title, symbol: \.symbol, commitsWhenSettled: true)
            Text(settings.livePhotoMode.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)
                .animation(Motion.smooth, value: settings.livePhotoMode)
        }
    }

    private var videoSettings: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("\(videos.count) Videos", symbol: "video")
            GlassSegmentedPicker("Video quality", options: QualityLevel.allCases, selection: $settings.videoQuality, title: \.title, symbol: \.symbol, commitsWhenSettled: true)
            Text(settings.videoQuality.videoDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            GlassCard(padding: 16) {
                HStack {
                    Text("Resolution")
                    Spacer()
                    Picker("Resolution", selection: $settings.videoLimit) {
                        ForEach(VideoSizeLimit.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .font(.subheadline)
            }
            Text("Videos are encoded in HEVC. HDR stays HDR, audio is kept as is. Long videos can take a while: the run keeps going if you leave the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func sectionTitle(_ title: LocalizedStringResource, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}

/// What a copy keeps, and the one thing iOS doesn't let apps keep.
struct KeptNote: View {
    var framed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Kept on every copy", systemImage: "checkmark.seal")
                .font(.subheadline.weight(.semibold))
            Text("Capture date and time zone, location, camera details, favorites, hidden state, album placement, Live Photo motion (unless you make them still), HDR, color profile, orientation, and the screenshot tag.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Label("Not kept", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            Text("iOS doesn't let apps set the date a photo was added, or read captions. Copies appear where they belong when Photos is sorted by Date Captured, and at the top when sorted by Recently Added.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(framed ? 20 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(framed ? .regular : .identity, in: .rect(cornerRadius: 28))
    }
}
