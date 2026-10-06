import SwiftUI

/// The last stop before a run: how hard to compress, what that looks like
/// on a real item, and what happens to the originals.
struct ReviewSheet: View {
    let items: [MediaItem]

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending
    @Environment(JobCenter.self) private var jobs
    @Environment(CompressionSettings.self) private var settings

    /// Originals that already have a copy are left out: a second copy
    /// would only duplicate it.
    private var runItems: [MediaItem] {
        let done = pending.originalIDs
        return items.filter { $0.isEligible && !done.contains($0.id) }
    }

    private var photos: [MediaItem] { runItems.filter { $0.kind == .photo } }
    private var videos: [MediaItem] { runItems.filter { $0.kind == .video } }
    private var livePhotos: [MediaItem] { runItems.filter(\.isLivePhoto) }

    var body: some View {
        @Bindable var settings = settings
        let run = runItems
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    totals(run)

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
                    Text("Compress \(run.count.formatted()) \(run.count == 1 ? "Item" : "Items")")
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
        .presentationDetents([.large])
        .presentationBackground(Color.screenBackground)
    }

    private func totals(_ run: [MediaItem]) -> some View {
        let size = run.reduce(Int64(0)) { $0 + $1.size }
        let saving = library.estimatedSaving(of: run)
        let skipped = items.count - run.count
        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Figure(value: run.count.formatted(), label: run.count == 1 ? "Item" : "Items")
                    Figure(value: ByteFormat.string(size), label: "Now")
                    Figure(value: "≈ \(ByteFormat.string(size - saving))", label: "After", tinted: true)
                }
                SavingsBar(total: size, saving: saving)
                if skipped > 0 {
                    Text("\(skipped.formatted()) already compressed and waiting for their originals to be removed \(skipped == 1 ? "is" : "are") left out.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func photoSettings(sample: MediaItem) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(photos.count == 1 ? "1 Photo" : "\(photos.count.formatted()) Photos", symbol: "photo")
            GlassSegmentedPicker("Photo quality", options: QualityLevel.allCases, selection: $settings.photoQuality, title: \.title, symbol: \.symbol)
            Text(settings.photoQuality.photoDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)

            ComparisonCard(item: largestPhoto ?? sample, recipe: settings.recipe)

            GlassCard(padding: 16) {
                VStack(spacing: 14) {
                    HStack {
                        Text("Format")
                        Spacer()
                        Picker("Format", selection: $settings.photoFormat) {
                            ForEach(PhotoFormat.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
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
        }
    }

    private var largestPhoto: MediaItem? { photos.max { $0.size < $1.size } }

    private var liveSettings: some View {
        @Bindable var settings = settings
        let count = livePhotos.count
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(count == 1 ? "1 Live Photo" : "\(count.formatted()) Live Photos", symbol: "livephoto")
            GlassSegmentedPicker("Live Photos", options: LivePhotoMode.allCases, selection: $settings.livePhotoMode, title: \.title, symbol: \.symbol)
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
            sectionTitle(videos.count == 1 ? "1 Video" : "\(videos.count.formatted()) Videos", symbol: "video")
            GlassSegmentedPicker("Video quality", options: QualityLevel.allCases, selection: $settings.videoQuality, title: \.title, symbol: \.symbol)
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

    private func sectionTitle(_ title: String, symbol: String) -> some View {
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
