import SwiftUI

/// A run, from the first item to removing the originals.
struct JobView: View {
    let job: CompressionJob

    @Environment(LibraryStore.self) private var library
    @Environment(PendingRemovals.self) private var pending
    @Environment(JobCenter.self) private var jobs
    @Environment(CompressionSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var removal: RemovalState = .idle
    @State private var autoRemoveAttempted = false
    @State private var showsEmptyTip = false
    @State private var showsIssues = false
    @State private var confirmsStop = false

    private enum RemovalState: Equatable {
        case idle, removing, removed(Int64), declined, failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ProgressRing(job: job)
                        .padding(.top, 12)

                    status

                    HStack(spacing: 12) {
                        Figure(value: job.replacedCount.formatted(), label: "Compressed")
                        Figure(value: job.skippedCount.formatted(), label: "Kept as is")
                        Figure(value: job.failures.count.formatted(), label: "Issues")
                    }
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))

                    if job.phase == .needsSpace {
                        NeedsSpaceCard(job: job)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    if job.isFinished {
                        finishedCard
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if !job.failures.isEmpty {
                        Button {
                            showsIssues = true
                        } label: {
                            Label("See \(job.failures.count) issues", systemImage: "exclamationmark.triangle")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .animation(Motion.smooth, value: job.phase)
                .animation(Motion.smooth, value: removal)
            }
            .scrollIndicators(.hidden)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if job.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { jobs.close(library: library) }
                            .disabled(removal == .removing)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop", systemImage: "stop.fill") { confirmsStop = true }
                    }
                }
            }
            .confirmationDialog("Stop compressing?", isPresented: $confirmsStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive) { job.cancel() }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("Copies saved so far stay in your library, and their originals can still be removed.")
            }
        }
        .interactiveDismissDisabled()
        .sensoryFeedback(.success, trigger: job.isFinished) { _, finished in finished && !job.wasCancelled }
        .sheet(isPresented: $showsIssues) { IssuesSheet(issues: job.failures) }
        .sheet(isPresented: $showsEmptyTip) { RecentlyDeletedTip() }
        .onChange(of: job.isFinished) { _, _ in autoRemove() }
        .onChange(of: scenePhase) { _, _ in autoRemove() }
    }

    private var title: String {
        if job.isFinished { return job.wasCancelled ? String(localized: "Stopped") : String(localized: "Done") }
        return job.phase == .needsSpace ? String(localized: "Paused") : String(localized: "Compressing")
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 6) {
            Text("\(min(job.processedCount, job.total).formatted()) of \(job.total.formatted())")
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
            if let item = job.currentItem, !job.isFinished {
                Text(item.kind == .video ? "Encoding \(item.filename)…" : "Working through photos…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if job.isFinished {
                Text(job.replacedCount == 0 ? "Nothing needed compressing." : "Copies are saved in your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(Motion.smooth, value: job.processedCount)
    }

    @ViewBuilder
    private var finishedCard: some View {
        if pending.count > 0 || removal != .idle {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    switch removal {
                    case .removed(let freed):
                        Label("Originals removed", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.tint)
                        Text("\(ByteFormat.string(freed)) will be back once Recently Deleted is emptied.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("How to Empty It") { showsEmptyTip = true }
                            .buttonStyle(.glass)
                    default:
                        Label("Remove the originals", systemImage: "trash")
                            .font(.headline)
                        Text(removalMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await remove() }
                        } label: {
                            Label("Remove \(pending.count) Originals", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(removal == .removing || pending.count == 0)
                    }
                }
            }
        }
    }

    private var removalMessage: String {
        switch removal {
        case .declined: String(localized: "Nothing was removed. You can do it any time from the Library tab.")
        case .failed(let reason): reason
        default: String(localized: "Their copies are in your library. Removing them gives back \(ByteFormat.string(pending.saving)).")
        }
    }

    /// Once per run, with the app in front (iOS's confirmation needs it).
    private func autoRemove() {
        guard job.isFinished, settings.removeOriginals, !autoRemoveAttempted,
              scenePhase == .active, job.replacedCount > 0, pending.count > 0
        else { return }
        autoRemoveAttempted = true
        Task { await remove() }
    }

    private func remove() async {
        removal = .removing
        switch await pending.removeAll() {
        case .removed(let freed):
            removal = .removed(freed)
            if freed > 0 { showsEmptyTip = true }
        case .declined: removal = .declined
        case .failed(let reason): removal = .failed(reason)
        }
    }
}

private struct ProgressRing: View {
    let job: CompressionJob

    var body: some View {
        let fraction = job.isFinished && !job.wasCancelled ? 1 : job.fractionCompleted
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.smooth, value: fraction)
            VStack(spacing: 4) {
                if job.isFinished && !job.wasCancelled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                Text("\(ByteFormat.string(job.saving)) saved")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .animation(Motion.smooth, value: job.saving)
        }
        .frame(width: 220, height: 220)
        .padding(18)
        .glassEffect(.regular, in: .circle)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(fraction, format: .percent))
    }
}

/// The run waits here when the iPhone is too full for the next copies.
private struct NeedsSpaceCard: View {
    let job: CompressionJob
    @Environment(PendingRemovals.self) private var pending
    @Environment(\.openURL) private var openURL

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Your iPhone is almost full", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                Text("Each copy is saved before its original goes, so the next ones need room. Remove the originals done so far, empty Recently Deleted in Photos, then continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if pending.count > 0 {
                    Button {
                        Task { _ = await pending.removeAll() }
                    } label: {
                        Label("Remove \(pending.count) Originals", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(pending.isRemoving)
                }
                HStack(spacing: 10) {
                    Button("Open Photos") {
                        if let url = URL(string: "photos-redirect://") { openURL(url) }
                    }
                    .buttonStyle(.glass)
                    Button("Continue") { job.resumeAfterSpace(true) }
                        .buttonStyle(.glass)
                }
            }
        }
    }
}

private struct IssuesSheet: View {
    let issues: [CompressionJob.Issue]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(issues) { issue in
                HStack(spacing: 12) {
                    AssetThumbnail(id: issue.item.id)
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.item.filename.isEmpty ? issue.item.format.label : issue.item.filename)
                            .font(.subheadline.weight(.semibold))
                        Text(issue.reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(Color.screenBackground.ignoresSafeArea())
            .navigationTitle("Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
