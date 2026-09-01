import AppKit
import Sparkle

/// Owns Sparkle's standard updater and remains disabled for local builds without
/// a release feed configured in the application bundle.
@MainActor
final class AppUpdater: NSObject {
    private let controller: SPUStandardUpdaterController?

    override init() {
        if let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feedURL.isEmpty {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
        super.init()
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
