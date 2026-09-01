import BackgroundTasks
import WidgetKit
import MetriaMobileKit

/// One opportunistic background refresh, registered at launch. iOS decides if and when
/// it actually runs; treat every success as a bonus; the widget's own timeline plus the
/// relay transport are what keep it honest when this never fires (Plan 004 Phase 3).
enum BackgroundRefresh {
    static let taskIdentifier = "com.metria.ios.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        guard let configuration = PairingStore.load() else {
            task.setTaskCompleted(success: true)
            return
        }

        let fetcher = SnapshotFetcher()
        let work = Task {
            await fetcher.fetchAndCache(configuration: configuration)
            WidgetCenter.shared.reloadAllTimelines()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
