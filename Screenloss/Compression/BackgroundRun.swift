import BackgroundTasks
import Foundation

/// Lets a run keep going when the user leaves the app, with iOS showing its
/// progress (iOS 26 continued processing). If the system declines, the run
/// simply continues while the app is open.
@MainActor
final class BackgroundRun {
    private var task: BGContinuedProcessingTask?
    private var identifier: String?
    private var lastProgress = 0.0
    private var lastSubtitle = ""
    private var title = ""
    private var isEnded = false

    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor @Sendable () -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.fares.screenloss"
        // Each identifier can be registered once per launch: a fresh one per run.
        let identifier = "\(bundleID).compress.\(UUID().uuidString)"
        self.identifier = identifier
        self.title = title
        lastSubtitle = subtitle

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let self, !self.isEnded else {
                    task.setTaskCompleted(success: true)
                    return
                }
                task.expirationHandler = {
                    Task { @MainActor in onExpire() }
                }
                task.progress.totalUnitCount = 1000
                self.task = task
                self.apply()
            }
        }
        guard registered else { return }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not available here (Simulator, or turned off): foreground only.
        }
    }

    func update(progress: Double, subtitle: String?) {
        lastProgress = progress
        if let subtitle { lastSubtitle = subtitle }
        apply()
    }

    func end(success: Bool) {
        isEnded = true
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        } else if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        task = nil
    }

    private func apply() {
        guard let task else { return }
        task.progress.completedUnitCount = Int64(lastProgress * Double(task.progress.totalUnitCount))
        task.updateTitle(title, subtitle: lastSubtitle)
    }
}
