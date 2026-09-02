import AppKit
import Sparkle

/// Owns Sparkle's standard updater and remains disabled for local builds without
/// a release feed configured in the application bundle.
@MainActor
final class AppUpdater: NSObject {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        if let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feedURL.isEmpty {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var isConfigured: Bool {
        controller != nil
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// Silent, no-UI-unless-found check meant to run on every launch, in addition
    /// to Sparkle's own hourly `SUScheduledCheckInterval` background checks.
    func checkForUpdatesInBackground() {
        controller?.updater.checkForUpdatesInBackground()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Runs right before Sparkle shows its "update available" alert. Metria is a menu-bar
    /// accessory app with no Dock icon, so an update found by the silent background check
    /// (on launch or hourly) could otherwise pop up behind other windows and go unnoticed,
    /// leaving "Check for Updates" as the only reliable way to learn about a new release.
    /// Activating the app here brings that alert to the front instead.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
