import AppKit
import Observation
import QuotaCore
import Sparkle

/// Sparkle auto-update from GitHub Releases.
///
/// `SUFeedURL` points at the `appcast.xml` asset of the latest release; `scripts/publish.sh` publishes it
/// with an EdDSA signature that `SUPublicEDKey` verifies. A menu-bar app almost never quits, so instead of
/// Sparkle's "install on quit" a downloaded update installs as soon as QuotaPulse is in the background
/// (immediately, or once the user switches away from its window), and QuotaPulse relaunches itself.
@MainActor @Observable
final class Updater: NSObject {
    /// Debug builds (Xcode runs) never replace themselves.
    static let isEnabled: Bool = {
        #if DEBUG
        return false
        #else
        return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        #endif
    }()

    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    /// A version a scheduled check found while QuotaPulse was in the background (gentle reminder).
    private(set) var availableVersion: String?
    /// The version that is downloaded and waiting for QuotaPulse to go to the background.
    private(set) var installingVersion: String?

    var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
            QPLog.update.notice("automatic checks \(self.automaticallyChecks ? "on" : "off", privacy: .public)")
        }
    }

    var automaticallyInstalls = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyDownloadsUpdates != automaticallyInstalls else { return }
            updater.automaticallyDownloadsUpdates = automaticallyInstalls
            QPLog.update.notice("automatic install \(self.automaticallyInstalls ? "on" : "off", privacy: .public)")
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    override init() {
        super.init()
        guard Self.isEnabled else {
            QPLog.update.notice("updater off in this build")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        controller.startUpdater()
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
        let feed = updater.feedURL?.absoluteString ?? "none"
        QPLog.update.notice("updater started: feed \(feed, privacy: .public), auto-check \(updater.automaticallyChecksForUpdates, privacy: .public), auto-install \(updater.automaticallyDownloadsUpdates, privacy: .public), every \(Int(updater.updateCheckInterval), privacy: .public)s")
    }

    /// Menu and Settings: check now and show Sparkle's window (also brings a pending reminder forward).
    func checkForUpdates() {
        guard let controller else { return }
        QPLog.update.notice("check requested by the user")
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private func installWhenInBackground(_ install: @escaping () -> Void, version: String) {
        installingVersion = version
        guard NSApp.isActive else {
            QPLog.update.notice("\(version, privacy: .public) downloaded; installing and relaunching now")
            install()
            return
        }
        QPLog.update.notice("\(version, privacy: .public) downloaded; installing once QuotaPulse is in the background")
        pendingInstall = install
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPendingInstall() }
        }
    }

    private func runPendingInstall() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        QPLog.update.notice("QuotaPulse is in the background; installing and relaunching")
        install()
    }

    private func noteCycleEnded(_ updater: SPUUpdater) {
        lastCheck = updater.lastUpdateCheckDate
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        QPLog.update.notice("found \(item.displayVersionString, privacy: .public) (build \(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        QPLog.update.notice("up to date")
        noteCycleEnded(updater)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        QPLog.update.notice("downloaded \(item.displayVersionString, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        QPLog.update.error("download of \(item.displayVersionString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        guard !Self.isNoUpdate(error) else { return } // "up to date" is logged by updaterDidNotFindUpdate
        QPLog.update.error("update cycle aborted: \(error.localizedDescription, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error, !Self.isNoUpdate(error) { QPLog.update.notice("update cycle ended: \(error.localizedDescription, privacy: .public)") }
        noteCycleEnded(updater)
    }

    /// Sparkle reports "you're up to date" as an error (SUNoUpdateError).
    private static func isNoUpdate(_ error: any Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SUSparkleErrorDomain && ns.code == Int(SUError.noUpdateError.rawValue)
    }

    /// Sparkle would wait for a quit that a menu-bar app rarely does; install now instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installWhenInBackground(immediateInstallHandler, version: item.displayVersionString)
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        QPLog.update.notice("relaunching into the new version")
    }
}

/// Gentle reminders: a background app must not throw an update window over whatever the user is doing.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        QPLog.update.notice("\(update.displayVersionString, privacy: .public) available; showing a reminder in the menu panel")
        availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
