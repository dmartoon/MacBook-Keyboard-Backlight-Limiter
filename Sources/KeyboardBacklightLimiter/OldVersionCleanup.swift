import AppKit

/// Offers to move the pre-rename copy of the app to the Trash.
///
/// The app shipped as `Keyboard Backlight Limiter.app` through 1.1.2 and as
/// `Dim Keys.app` afterwards. Updates are manual drag-installs, so the new
/// bundle lands *beside* the old one rather than replacing it — and both carry
/// the same `CFBundleIdentifier` and drive the same brightness property. Left
/// alone they fight over it, and if the old one is still a login item, the copy
/// that wins on the next boot is the one the user is no longer looking at.
///
/// Renaming only `CFBundleDisplayName` and leaving the bundle filename alone
/// would have avoided this entirely, and **does not work**: measured on macOS
/// 26, a bundle named `Keyboard Backlight Limiter.app` carrying
/// `CFBundleDisplayName = "Dim Keys"` still reports
/// `kMDItemDisplayName = "Keyboard Backlight Limiter"`. For applications the
/// filename *is* the name; the display name is a hint the Finder ignores. So
/// the rename had to move the bundle, and this exists to clean up after it.
enum OldVersionCleanup {

    /// The pre-rename bundle filename. Matching on the name as well as the
    /// bundle identifier is deliberate — see `oldCopies`.
    private static let oldBundleName = "Keyboard Backlight Limiter.app"

    /// Set once the user declines, so this asks exactly once and never nags.
    /// Choosing "Show in Finder" deliberately does *not* set it: that answer is
    /// "let me look", not "no".
    private static let declinedKey = "declinedOldCopyCleanup"

    /// Pre-rename copies worth offering to remove.
    ///
    /// Three filters, and dropping any one of them makes this dangerous:
    ///
    /// - **Same bundle identifier** — what makes the old copy an actual
    ///   conflict rather than an unrelated app that happens to be named alike.
    /// - **The old filename.** `urlsForApplications` returns *every* bundle
    ///   claiming the identifier, which on a development machine includes
    ///   `build/` and `dist/` output. Offering to trash someone's build
    ///   directory is not a migration.
    /// - **Installed under an Applications folder.** A copy still sitting in
    ///   Downloads is a leftover disk image, not an install, and is not ours to
    ///   tidy.
    ///
    /// The running bundle is excluded unconditionally, so this can never target
    /// itself no matter what it is called or where it is running from.
    private static var oldCopies: [URL] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = Bundle.main.bundleURL.standardizedFileURL
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .map(\.standardizedFileURL)
            .filter { url in
                url != me
                    && url.lastPathComponent == oldBundleName
                    && roots.contains { url.path.hasPrefix($0 + "/") }
            }
    }

    /// Asks once, on launch, when a pre-rename copy is present.
    ///
    /// **Never silent.** An app that removes things from `/Applications`
    /// without asking is behaviour to be suspicious of in anyone else's app.
    /// It also matters for a second reason: on macOS 13+ removing another app's
    /// bundle can raise the system's "would like to manage apps on your Mac"
    /// prompt, and that prompt needs a reason already on screen when it
    /// appears, not an explanation afterwards.
    static func run() {
        // The self-test drives the panel headlessly and must never block on a
        // modal. It runs from inside a real bundle when capturing the
        // screenshot, so a `bundleIdentifier` guard would not exclude it — and
        // this machine has a real old copy in /Applications, which the test
        // would otherwise offer to throw away.
        guard ProcessInfo.processInfo.environment["KBL_SELFTEST"] == nil else { return }
        guard !UserDefaults.standard.bool(forKey: declinedKey) else { return }

        let copies = oldCopies
        guard !copies.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "An older copy of this app is still installed"
        alert.informativeText =
            "Keyboard Backlight Limiter is now Dim Keys. The old copy is still in "
          + "Applications, and both drive the same keyboard backlight, so leaving it "
          + "there means the two work against each other.\n\n"
          + "Moving it to the Trash is safe — your settings belong to Dim Keys and "
          + "are not affected."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            trash(copies)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(copies)
        default:
            UserDefaults.standard.set(true, forKey: declinedKey)
        }
    }

    private static func trash(_ copies: [URL]) {
        // Captured before the old bundle goes. The login item is registered
        // against a bundle *path*, so removing the copy that registered it
        // leaves the item pointing at nothing.
        let wasLoginItem = LaunchAtLogin.isEnabled

        quitRunningCopies(at: copies)

        var failures: [(url: URL, reason: String)] = []
        for url in copies {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures.append((url, (error as NSError).localizedDescription))
            }
        }

        // Re-point launch-at-login at this bundle. Both copies share an
        // identifier, so the status read above may well have been the old
        // copy's registration.
        if wasLoginItem { LaunchAtLogin.reregister() }

        guard !failures.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't move the old copy to the Trash"
        alert.informativeText =
            failures.map { "\($0.url.path)\n\($0.reason)" }.joined(separator: "\n\n")
          + "\n\nmacOS asks permission before one app may remove another. Allow it "
          + "under System Settings › Privacy & Security › App Management, or simply "
          + "drag the old app to the Trash yourself — that always works."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Quits an old copy and waits for it to actually go.
    ///
    /// `terminate()` is asynchronous, and the old copy restores the keyboard
    /// brightness from `applicationWillTerminate` — so this waits for it rather
    /// than racing it onto the Trash. It **pumps the run loop instead of
    /// sleeping**: this runs on the main thread, and blocking main is precisely
    /// what would stop the termination it is waiting for from being delivered.
    /// The 3s cap means a wedged old copy delays launch rather than hanging it.
    private static func quitRunningCopies(at copies: [URL]) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let targets = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { app in
                guard let url = app.bundleURL?.standardizedFileURL else { return false }
                return copies.contains(url)
            }
        guard !targets.isEmpty else { return }

        targets.forEach { $0.terminate() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, targets.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
