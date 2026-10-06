import SwiftUI

struct SettingsView: View {
    @Environment(CompressionSettings.self) private var settings
    @Environment(PendingRemovals.self) private var pending
    @AppStorage(AppTint.storageKey) private var tint = AppTint.mint.rawValue
    @State private var compressionOpen = true
    @State private var appearanceOpen = false
    @State private var keptOpen = false
    @State private var aboutOpen = false

    private static let savingSteps: [Double] = [0.05, 0.1, 0.2, 0.3]

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(spacing: 16) {
                if pending.lifetimeFreed > 0 {
                    GlassCard {
                        HStack {
                            Figure(value: ByteFormat.string(pending.lifetimeFreed), label: "Freed so far", tinted: true)
                            Image(systemName: "leaf")
                                .font(.title2)
                                .foregroundStyle(.tint)
                        }
                    }
                }

                CollapsibleGlassCard(title: "Compression", systemImage: "slider.horizontal.3", isExpanded: $compressionOpen) {
                    VStack(alignment: .leading, spacing: 14) {
                        row("Photos") {
                            Picker("Photos", selection: $settings.photoQuality) {
                                ForEach(QualityLevel.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        row("Photo Format") {
                            Picker("Photo Format", selection: $settings.photoFormat) {
                                ForEach(PhotoFormat.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        row("Live Photos") {
                            Picker("Live Photos", selection: $settings.livePhotoMode) {
                                ForEach(LivePhotoMode.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        row("Videos") {
                            Picker("Videos", selection: $settings.videoQuality) {
                                ForEach(QualityLevel.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        Divider()
                        row("Keep a copy only if") {
                            Picker("Minimum saving", selection: $settings.minimumSaving) {
                                ForEach(Self.savingSteps, id: \.self) { step in
                                    Text("\(Int(step * 100))% smaller").tag(step)
                                }
                            }
                        }
                        Toggle("Remove originals when done", isOn: $settings.removeOriginals)
                        Text("A copy that isn't at least that much smaller is thrown away and the original stays. Originals are only removed after iOS asks you.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                CollapsibleGlassCard(title: "Appearance", systemImage: "paintpalette", isExpanded: $appearanceOpen) {
                    HStack(spacing: 12) {
                        ForEach(AppTint.allCases) { option in
                            swatch(option)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sensoryFeedback(.selection, trigger: tint)
                    .onChange(of: tint) { _, newValue in
                        AppTint(rawValue: newValue)?.applyIcon()
                    }
                }

                CollapsibleGlassCard(title: "What's Kept", systemImage: "checkmark.seal", isExpanded: $keptOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Copies are made from the photo as it appears in Photos, edits and Photographic Styles included, and carry over everything iOS lets an app write. Those edits become part of the copy: they can't be reverted afterwards.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        KeptNote(framed: false)
                        Text("Left alone: RAW, Portrait, bursts, animated images, spatial and Cinematic media, slow motion, and Live Photos with a Loop or Bounce effect. Re-encoding them would lose something Photos can't rebuild.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                CollapsibleGlassCard(title: "About", systemImage: "info.circle", isExpanded: $aboutOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Everything happens on this iPhone. Nothing is uploaded, no account, no subscription.")
                        Text("Questions, feedback or bug reports: [@rmxptfl](https://x.com/rmxptfl) on X · [tlfares](https://github.com/tlfares) on GitHub")
                    }
                    .font(.footnote)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Settings")
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
            Spacer()
            control().pickerStyle(.menu)
        }
    }

    private func swatch(_ option: AppTint) -> some View {
        let isSelected = tint == option.rawValue
        return Button {
            withAnimation(Motion.snappy) { tint = option.rawValue }
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 36, height: 36)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                    }
                }
                .overlay {
                    Circle().stroke(.white.opacity(isSelected ? 0.9 : 0.25), lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
