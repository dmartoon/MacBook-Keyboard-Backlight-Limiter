import AppKit
import UserNotifications

/// Delivers the update notice as a system notification, so it can reach the
/// user when there is no panel to put it in.
///
/// The panel's version label was the only place an update ever appeared, and it
/// is unreachable in two situations that matter: the menu bar icon is hidden,
/// or the app has simply been running for weeks without anyone opening it. This
/// is the other half of that fix — the first half is that the app now *checks*
/// on a timer rather than only at launch and on panel open.
///
/// Everything here fails silently and is guarded, in keeping with the rest of
/// the update path: a missed notice is never worth a dialog, and nothing in
/// here may take the app down with it.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()

    /// Called when the user clicks the notification.
    var onOpen: (() -> Void)?

    /// The last version we posted about. Without this the 6-hourly check would
    /// post a fresh banner every 6 hours for the same release — the panel label
    /// is idempotent because it just rewrites a string, a notification is not.
    private static let notifiedKey = "lastNotifiedVersion"

    /// `UNUserNotificationCenter.current()` requires a real bundle and is not
    /// usable from a process that has none — which is exactly the bare
    /// `KBL_SELFTEST` binary. Everything below routes through this, so the test
    /// harness gets a no-op rather than a crash.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Must run during `applicationDidFinishLaunching`: a delegate set after
    /// the app finishes launching does not receive clicks on notifications.
    func start() {
        center?.delegate = self
    }

    /// Posts a banner for `version`, at most once for any given version.
    ///
    /// Authorization is requested here rather than at first launch, so the
    /// system prompt appears at the one moment it has an obvious reason —
    /// there is genuinely an update. After the first answer this returns the
    /// stored one without prompting again.
    func notifyIfNew(version: String) {
        guard let center else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedKey) != version else { return }

        center.requestAuthorization(options: [.alert]) { granted, _ in
            // Only record it once it has actually been delivered. A denial
            // must not burn the version: if notifications are switched on
            // later, the next check should still be able to say something.
            guard granted else { return }
            defaults.set(version, forKey: Self.notifiedKey)

            let content = UNMutableNotificationContent()
            content.title = "Dim Keys \(version)"
            content.body = "A new version is available. Click to open the releases page."
            // No sound: this is never urgent, and the app's whole character is
            // being quiet when nothing is wrong.
            center.add(UNNotificationRequest(identifier: "update-\(version)",
                                             content: content,
                                             trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        completionHandler()
    }
}
