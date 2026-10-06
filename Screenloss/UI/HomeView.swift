import SwiftUI

struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OverviewCard()
                if pending.count > 0 {
                    PendingRemovalCard()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(MediaCategory.tiles) { category in
                        NavigationLink(value: category) {
                            CategoryTile(category: category, summary: library.summaries[category])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .animation(Motion.smooth, value: pending.count > 0)
        }
        .scrollIndicators(.hidden)
        .background(Color.screenBackground.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationDestination(for: MediaCategory.self) { category in
            BrowserView(category: category)
        }
        .refreshable { library.scan() }
    }
}

/// How much the whole library could give back at the current settings.
private struct OverviewCard: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let all = library.summaries[.everything] ?? .init()
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Could be freed")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(library.hasScanned ? "≈ \(ByteFormat.string(all.estimatedSaving))" : "—")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(subtitle(all))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                if library.hasScanned {
                    SavingsBar(total: all.size, saving: all.estimatedSaving)
                    HStack {
                        legend("Now", ByteFormat.string(all.size), dot: .primary.opacity(0.55))
                        Spacer()
                        legend("After", "≈ \(ByteFormat.string(all.size - all.estimatedSaving))", dot: .accentColor)
                    }
                } else {
                    let progress = library.scanProgress
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text(progress.total > 0
                         ? "Reading your library… \(progress.done.formatted()) of \(progress.total.formatted())"
                         : "Reading your library…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .animation(Motion.smooth, value: all)
        .animation(Motion.smooth, value: library.hasScanned)
    }

    private func subtitle(_ all: LibraryStore.Summary) -> String {
        guard library.hasScanned else { return "Looking at your photos and videos" }
        return "\(all.count.formatted()) items, \(ByteFormat.string(all.size)) in all"
    }

    private func legend(_ title: String, _ value: String, dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.footnote)
    }
}

struct CategoryTile: View {
    let category: MediaCategory
    let summary: LibraryStore.Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: category.symbol)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.14)), in: .circle)
                Spacer()
                if let saving = summary?.estimatedSaving, saving > 0 {
                    Text("−\(ByteFormat.string(saving))")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 16)
            Text(category.title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .contentShape(.rect(cornerRadius: 28))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
        .accessibilityHint(summary.map { "About \(ByteFormat.string($0.estimatedSaving)) can be freed" } ?? "")
    }

    private var detail: String {
        guard let summary, summary.count > 0 else { return summary == nil ? "…" : "None" }
        return "\(summary.count.formatted()) · \(ByteFormat.string(summary.size))"
    }
}

/// Copies are saved; their originals are still taking the space.
private struct PendingRemovalCard: View {
    @Environment(PendingRemovals.self) private var pending
    @State private var showsEmptyTip = false
    @State private var message: String?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Originals to remove", systemImage: "trash")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("\(pending.count.formatted()) smaller \(pending.count == 1 ? "copy is" : "copies are") already in your library. Remove the originals to get \(ByteFormat.string(pending.saving)) back.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await remove() }
                } label: {
                    Label("Remove Originals", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(pending.isRemoving)
            }
        }
        .sheet(isPresented: $showsEmptyTip) {
            RecentlyDeletedTip()
        }
    }

    private func remove() async {
        switch await pending.removeAll() {
        case .removed(let freed):
            message = nil
            if freed > 0 { showsEmptyTip = true }
        case .declined:
            message = "Nothing was removed. Your originals and their copies are both still in the library."
        case .failed(let reason):
            message = reason
        }
    }
}

/// Removed originals sit in Recently Deleted, still taking space, until
/// they're emptied there or 30 days pass. Apps can't empty it.
struct RecentlyDeletedTip: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "trash.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .circle)
                .padding(.top, 28)
            VStack(spacing: 8) {
                Text("One last step").font(.title2.bold())
                Text("The originals are in Recently Deleted, where iOS keeps them for 30 days. Empty it in Photos to get the space back now.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Photos, then Collections")
                step(2, "Scroll to Utilities › Recently Deleted")
                step(3, "Select, then Delete All")
            }
            .font(.subheadline)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    if let url = URL(string: "photos-redirect://") { openURL(url) }
                    dismiss()
                } label: {
                    Text("Open Photos").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Later") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .presentationDetents([.large])
        .presentationBackground(Color.screenBackground)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.25), in: .circle)
            Text(text)
        }
    }
}
