import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var limiter: Limiter?
    private var backlight: KeyboardBacklight?

    private var mainView: NSView!

    private var presetControl: NSSegmentedControl!
    private var slider: NSSlider!
    private var ceilingField: NSTextField!
    private var currentField: NSTextField!
    private var sensitivityControl: NSSegmentedControl!
    private var sensitivityHint: NSTextField!
    private var luxField: NSTextField!

    private var versionField: NSTextField!
    /// The update notice: a button in the version label's slot, hidden until
    /// there is an update. See `showUpdateAvailable`.
    private var updateLink: NSButton!
    /// The panel's layout depends on whether the ambient sensor exists, and
    /// that answer can change after launch — see `Limiter.sensor`. These track
    /// what the *current* panel was built for and what still owes a rebuild.
    private var sensorSectionShown = false
    private var rebuildWhenClosed = false
    /// Replayed onto a rebuilt panel: the notice lives in the version label, so
    /// a rebuild would otherwise silently drop an update the user was told about.
    private var latestUpdateVersion: String?
    private var globalClickMonitor: Any?
    /// Keeps the periodic update check alive. Six hours of wall-clock time,
    /// sleep included, with generous leeway so it coalesces with whatever else
    /// wakes the machine.
    private var updateTimer: DispatchSourceTimer?
    private static let updateInterval: TimeInterval = 6 * 60 * 60
    private var loginCheckbox: NSButton!
    private var hideIconCheckbox: NSButton!

    private let W: CGFloat = 288

    func applicationDidFinishLaunching(_ notification: Notification) {
        // variableLength, not squareLength: the icon is ~1.8:1, and a square
        // item would clip it to the menu bar's height and squash the fan.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // The app's own motif rather than a stock SF Symbol, so the menu
            // bar and the app icon read as one product. See MenuBarIcon for why
            // it is drawn rather than scaled from the icon.
            button.image = MenuBarIcon.image()
            button.image?.accessibilityDescription = "Dim Keys"
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem.isVisible = !Settings.hideMenuBarIcon

        guard let backlight = KeyboardBacklight.open() else {
            buildUnavailable()
            return
        }
        self.backlight = backlight

        let sensor = AmbientLightSensor.find()
        let limiter = Limiter(backlight: backlight,
                              sensor: sensor,
                              ceiling: Settings.ceiling,
                              sensitivity: Settings.sensitivity)
        self.limiter = limiter

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        buildMainView(backlight: backlight, hasSensor: sensor != nil)
        installMainView()

        // The sensor may only turn up seconds after launch, and the panel is
        // laid out differently with and without it, so rebuild when it does.
        limiter.onSensorAppeared = { [weak self] in self?.sensorAppeared() }

        limiter.onChange = { [weak self] observed, lux, gated in
            guard let self else { return }
            self.currentField.stringValue = self.currentText(observed)
            if let lux {
                self.luxField.stringValue = gated ? "\(lux) lux — off" : "\(lux) lux"
            }
        }
        limiter.start()

        // The mouse monitor below catches clicks, but not a keyboard app
        // switch. Resigning active covers Cmd-Tab and anything else that takes
        // focus without a click landing outside us.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        // Clicking the notification opens the releases page, same as clicking
        // the notice in the panel. Set during launch — a delegate installed
        // later does not receive the click.
        UpdateNotifier.shared.onOpen = { [weak self] in self?.openReleases() }
        UpdateNotifier.shared.start()

        checkForUpdate()
        startUpdateTimer()

        // Deferred one turn on purpose: running a modal from inside
        // didFinishLaunching puts the alert up before the status item is on
        // screen, so an accessory app appears to be a dialog with no app
        // behind it. OldVersionCleanup.run() is a no-op unless a pre-rename
        // copy is actually installed.
        DispatchQueue.main.async { OldVersionCleanup.run() }

        if ProcessInfo.processInfo.environment["KBL_SELFTEST"] != nil { runSelfTest() }
    }

    /// Layout guard for the single-page popover.
    ///
    /// The old two-page swap regression (see CLAUDE.md) cannot happen any more
    /// — there is only one page — so this checks what *can* still break on one
    /// page: nothing may escape the view's bounds, and the bottom row must not
    /// collide. That row is positioned from measured text (`sizeToFit` on the
    /// Support button), so a longer title or version string is exactly the kind
    /// of change that would silently overlap the version label.
    private func runSelfTest() {
        var failures = 0
        func fail(_ m: String) { failures += 1; print("  FAIL  \(m)") }
        func name(_ v: NSView) -> String {
            if let b = v as? NSButton, !b.title.isEmpty { return "button \u{22}\(b.title)\u{22}" }
            if let t = v as? NSTextField {
                let sv = t.stringValue
                return sv.isEmpty ? "label (empty)" : "label \u{22}\(sv.prefix(28))\u{22}"
            }
            return String(describing: type(of: v))
        }
        func pump(_ secs: Double) {
            let end = Date().addingTimeInterval(secs)
            while Date() < end {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        /// `pump` runs the run loop but never hands an event to a window. This
        /// suite runs inside applicationDidFinishLaunching, before NSApp's own
        /// event loop has started, so anything that needs an event delivered,
        /// a click or the app losing focus, has to wait with this instead.
        func dispatch(_ secs: Double) {
            let end = Date().addingTimeInterval(secs)
            while Date() < end {
                if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                           inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
            }
        }

        // A real window so the popover can actually lay out — placed on the
        // sharpest screen attached. `CGWindowListCreateImage` captures at the
        // window's backing scale, so on a 1x external monitor the snapshot comes
        // out half the size of the same panel on the built-in Retina display.
        // docs/screenshot.png wants the 2x one.
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let origin = screen?.frame.origin ?? .zero
        //
        // Big enough for the panel to sit entirely over it, and black: the
        // backdrop blends with whatever is *behind* the window, so a default
        // grey harness window washes the whole panel out — visible in the
        // snapshot, and not how the popover looks over a real desktop.
        let win = NSWindow(contentRect: NSRect(x: origin.x + 120, y: origin.y + 120,
                                               width: 640, height: 640),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.backgroundColor = .black
        win.makeKeyAndOrderFront(nil)
        // Low in the window: `.maxY` puts the panel *above* the anchor, so an
        // anchor near the top pushes it off the window entirely and it blends
        // with the desktop instead.
        let anchor = NSView(frame: NSRect(x: 300, y: 60, width: 20, height: 20))
        win.contentView?.addSubview(anchor)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.4)

        print("popover layout self-test:")
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        pump(0.5)
        print(String(format: "  view %.0fx%.0f   contentSize %.0fx%.0f   shown=%@",
                     mainView.frame.width, mainView.frame.height,
                     popover.contentSize.width, popover.contentSize.height,
                     (popover.isShown ? "Y" : "n") as NSString))

        func checkBounds(_ what: String) {
            for sub in mainView.subviews where !mainView.bounds.contains(sub.frame) {
                fail("out of bounds (\(what)): \(name(sub)) at \(NSStringFromRect(sub.frame))")
            }
        }
        checkBounds("normal")

        func checkBottomRow(_ what: String) {
            let row = mainView.subviews
                .filter { $0.frame.minY < 40 && !$0.isHidden }
                .filter { !($0 is NSVisualEffectView) }   // full-bounds backdrop
                .sorted { $0.frame.minX < $1.frame.minX }
            for i in 0..<row.count {
                for j in (i + 1)..<row.count where row[i].frame.intersects(row[j].frame) {
                    fail("bottom row overlap (\(what)): \(name(row[i])) x \(name(row[j]))")
                }
            }
            print("  bottom row \(what): " + row.map(name).joined(separator: " | "))
        }
        print("  \(mainView.subviews.count) subviews in bounds")
        checkBottomRow("normal")

        // Staged for the README asset this also produces: the checkboxes are
        // shown in their on state so the picture demonstrates both options.
        // Nothing else is faked — the values are whatever the machine reports.
        let priorLogin = loginCheckbox.state, priorHide = hideIconCheckbox.state
        if ProcessInfo.processInfo.environment["KBL_SNAPSHOT"] != nil {
            loginCheckbox.state = .on
            hideIconCheckbox.state = .on
        }

        // KBL_SNAPSHOT=<path> dumps what the panel actually renders, which is
        // the only way to catch layout that is technically in-bounds but ugly.
        // It runs here, on the plain panel, rather than after the update-notice
        // cases below — those leave an absurd "Update to 10.20.30" in the
        // version slot, which is neither what the panel normally looks like nor
        // what docs/screenshot.png should show.
        //
        // Capture the popover's own window off the window server. Both
        // offscreen paths (cacheDisplay and dataWithPDF) render the text but
        // drop every AppKit control — sliders, segmented controls, checkboxes
        // and buttons all come back blank — so the only faithful render is the
        // real composited window.
        if let out = ProcessInfo.processInfo.environment["KBL_SNAPSHOT"] {
            pump(0.4)
            if let win = mainView.window {
                let id = CGWindowID(win.windowNumber)
                // The window *and everything below it*, over an explicit rect.
                // Capturing the popover alone (.optionIncludingWindow with a
                // .null rect) leaves the `.behindWindow` backdrop with nothing
                // to blend against, and the whole panel comes back a flat grey
                // that is not what it looks like on a desktop.
                //
                // CGWindowListCreateImage takes global coordinates: origin at
                // the *primary* display's top-left, y growing downward, so the
                // Cocoa frame has to be flipped through that display's height.
                let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }
                                ?? NSScreen.main)?.frame.height ?? win.frame.maxY
                // Padded: the popover's arrow sits right on the frame edge and
                // comes back clipped otherwise. The margin is the black window
                // behind, which is what the rounded corners want anyway.
                let pad: CGFloat = 6
                let f = win.frame.insetBy(dx: -pad, dy: -pad)
                let rect = CGRect(x: f.origin.x, y: primaryH - f.origin.y - f.height,
                                  width: f.width, height: f.height)
                if let img = CGWindowListCreateImage(rect,
                                                     [.optionIncludingWindow, .optionOnScreenBelowWindow],
                                                     id, [.bestResolution]) {
                    let rep = NSBitmapImageRep(cgImage: img)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                        print("  snapshot \(img.width)x\(img.height) -> \(out)")
                    }
                } else {
                    print("  snapshot unavailable (screen recording permission?)")
                }
            }
        }
        loginCheckbox.state = priorLogin
        hideIconCheckbox.state = priorHide

        // The update notice reuses the version label's slot rather than adding a
        // row, and "Update to ..." is wider than "Version ...". Two separate
        // guarantees: a realistic version must not truncate, and even an absurd
        // one must not collide with the Support button.
        //
        // Truncation is measured off the cell, not off the string: NSTextField
        // adds internal insets, so measuring the string alone reports ~4pt more
        // room than actually exists and calls a truncating label "fits".
        //
        // The link also has to answer a click, which no layout check sees. It
        // was dead from 1.2.0 to 1.2.2 with this suite green (CLAUDE.md, fixed
        // bug 12),
        // so it is clicked for real: posted to the app's event queue as a real
        // click arrives, and dispatched. The browser is swapped out.
        func click(_ view: NSView) {
            guard let win = view.window else { return }
            let p = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            for (type, dt, pressure) in [(NSEvent.EventType.leftMouseDown, 0.0, Float(1)),
                                         (.leftMouseUp, 0.08, Float(0))] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                 timestamp: now + dt, windowNumber: win.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: pressure) else { continue }
                NSApp.postEvent(e, atStart: false)
            }
            dispatch(0.5)
        }
        // Up to three tries, reopening the panel if it has closed. A click
        // anywhere else on screen closes it (the global monitor), so someone
        // using the Mac while the suite runs can make a try miss, and did. A
        // dead link misses every try.
        func linkOpens() -> Bool {
            var opened: URL?
            let realOpen = openURL
            openURL = { opened = $0 }
            defer { openURL = realOpen }
            for _ in 0..<3 where opened == nil {
                if !popover.isShown {
                    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
                    pump(0.5)
                }
                click(updateLink)
            }
            return opened == UpdateCheck.releasesPage
        }
        // The panel has been used before the update turns up, as it always has
        // in real life. That is the condition the old click handling failed in.
        click(versionField)
        showUpdateAvailable("1.10.0")
        mainView.layoutSubtreeIfNeeded()
        pump(0.2)
        if updateLink.isHidden || !versionField.isHidden {
            fail("the update notice did not take the version label's place")
        }
        if let cell = updateLink.cell {
            let needed = cell.cellSize.width, have = updateLink.frame.width
            if needed > have {
                fail(String(format: "update notice truncates at a realistic version: needs %.1fpt, has %.1fpt", needed, have))
            } else {
                print(String(format: "  update notice \u{22}%@\u{22} needs %.1fpt of %.1fpt", updateLink.title as NSString, needed, have))
            }
        }
        checkBottomRow("update available")

        showUpdateAvailable("10.20.30")
        mainView.layoutSubtreeIfNeeded()
        pump(0.2)
        checkBottomRow("update, absurd version")

        // The panel has two layouts, and until now only the one this machine
        // happens to produce was ever checked. The short no-sensor layout and
        // the rebuild that replaces it when the sensor turns up late are the
        // whole point of the sensor handling, so drive both for real.
        //
        // `isShown` flips well before the close animation delivers
        // `popoverDidClose`, and the deferred rebuild hangs off that delegate
        // call — so poll the monitor teardown, which is the real signal.
        func waitClosed() {
            popover.performClose(nil)
            let deadline = Date().addingTimeInterval(3)
            while (popover.isShown || globalClickMonitor != nil) && Date() < deadline { pump(0.1) }
            pump(0.2)
        }
        // Clicking the link closes the panel, so this goes last on it.
        if linkOpens() {
            print("  update link: a click opens the releases page")
        } else {
            fail("clicking the update link did nothing")
        }
        waitClosed()
        // Skipped rather than failed on a Mac that genuinely has no sensor:
        // there is no tall layout to compare against there, and a suite that
        // fails for environmental reasons is a suite people learn to ignore.
        if let backlight, limiter?.hasSensor == true {
            waitClosed()
            let tall = mainView.frame.height
            buildMainView(backlight: backlight, hasSensor: false)
            installMainView()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            pump(0.5)
            let short = mainView.frame.height
            print(String(format: "  no-sensor panel %.0fpt vs %.0fpt with sensor", short, tall))
            if short >= tall { fail("no-sensor panel is not shorter than the sensor one") }
            if popover.contentSize.height != short {
                fail(String(format: "contentSize %.0fpt does not match the no-sensor view %.0fpt",
                            popover.contentSize.height, short))
            }
            checkBounds("no sensor")
            checkBottomRow("no sensor")

            // A rebuild must never swap the content out from under an open
            // panel — it has to wait for the close.
            sensorAppeared()
            if mainView.frame.height != short { fail("panel rebuilt while the popover was open") }
            waitClosed()
            if !sensorSectionShown { fail("deferred rebuild never ran after the popover closed") }

            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            pump(0.5)
            if mainView.frame.height != tall {
                fail(String(format: "rebuilt panel is %.0fpt, expected %.0fpt", mainView.frame.height, tall))
            }
            if popover.contentSize.height != mainView.frame.height {
                fail("contentSize did not follow the rebuilt view")
            }
            checkBounds("rebuilt with sensor")
            checkBottomRow("rebuilt with sensor")
            // The notice lives in the version label, which the rebuild threw away.
            if updateLink.isHidden {
                fail("update notice lost in the rebuild")
            } else {
                print("  update notice survived the rebuild: \u{22}\(updateLink.title)\u{22}")
            }
            if !linkOpens() { fail("the rebuilt update link does not answer a click") }
            waitClosed()
        } else {
            print("  layout swap check skipped (no ambient sensor on this Mac)")
        }

        // The notifier must be completely inert in a process with no bundle.
        // It is reached on every real update, so a crash there would take the
        // app down for everybody at exactly the worst moment.
        //
        // Three things this check got wrong, all of which hid each other:
        //
        //  - "No bundle" is only true of the bare .build/release binary. The
        //    documented screenshot capture runs this same suite from *inside*
        //    the .app, where there is a bundle and the notifier is supposed to
        //    work — so there the assertion demanded the opposite of the
        //    requirement.
        //  - `notifyIfNew` writes from an async authorization callback, so the
        //    unconditional check raced it and usually ran first. It passed by
        //    losing the race, which is a green result proving nothing.
        //  - In a bundle this is the *real* preference domain, so the suite
        //    was stranding a bogus 99.0.0 in it — silencing the notification
        //    for a genuine 99.0.0 release. Found by that value sitting in live
        //    preferences with nothing else able to explain it.
        //
        // And a fourth, found after the other three were fixed: in a bundle
        // the notifier is live, so calling it delivers a real "Dim Keys 99.0.0"
        // banner to whoever ran the suite. It did, the day 1.2.1 shipped, from
        // a check of the release build. So `notifyIfNew` is only exercised
        // where it must do nothing. In a bundle the suite asks whether the
        // notifier is live and never posts.
        let notifiedKey = "lastNotifiedVersion"
        let savedNotified = UserDefaults.standard.string(forKey: notifiedKey)
        UpdateNotifier.shared.start()
        if Bundle.main.bundleIdentifier == nil {
            UpdateNotifier.shared.notifyIfNew(version: "99.0.0")
            // Give the async write its chance to land, or this passes for the
            // same wrong reason as before.
            pump(0.5)
            if UserDefaults.standard.string(forKey: notifiedKey) == "99.0.0" {
                fail("notifier wrote state from a process with no bundle")
            } else {
                print("  update notifier: inert without a bundle, as required")
            }
        } else if UpdateNotifier.shared.isLive {
            print("  update notifier: live in a bundle, as required (nothing posted)")
        } else {
            fail("update notifier is not live inside a bundle")
        }
        // Restore unconditionally — see above for what leaving it behind costs.
        if let savedNotified {
            UserDefaults.standard.set(savedNotified, forKey: notifiedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: notifiedKey)
        }

        // Dismissal. A process launched from a terminal does not become active
        // on its own, so NSApp.isActive starts out false and the app could
        // never *resign* active either. The update link check's clicks do
        // activate it, so the focus-loss check below now runs from a terminal
        // too. It still skips itself when the app is not active: asserting it
        // unconditionally would fail for purely environmental reasons, which
        // is worse than not testing it — a suite that cries wolf gets ignored.
        //
        // Its wait has to dispatch events. The app learns it lost focus from
        // an event, and with `pump` that event was never delivered, so the
        // check could not pass. Until the link check, it had never run.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let showDeadline = Date().addingTimeInterval(3)
        while globalClickMonitor == nil && Date() < showDeadline { pump(0.1) }
        if globalClickMonitor == nil {
            fail("no click monitor installed while the popover is shown")
        } else {
            print("  dismissal: click monitor installed while shown")
        }

        if NSApp.isActive {
            if let other = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.finder"
            }) {
                other.activate()
                dispatch(1.0)
                if popover.isShown { fail("popover stayed open after another app took focus") }
                else { print("  dismissal: closed when another app took focus") }
            }
        } else {
            print("  dismissal: focus-loss check skipped (cannot activate from a terminal launch)")
        }

        // Poll rather than sleep a fixed amount: performClose animates, and
        // popoverDidClose lands somewhere past half a second. A fixed 0.4s
        // wait reported a teardown failure that was purely the test being
        // impatient.
        popover.performClose(nil)
        let closeDeadline = Date().addingTimeInterval(3)
        while globalClickMonitor != nil && Date() < closeDeadline { pump(0.1) }
        if globalClickMonitor != nil { fail("click monitor left installed after close") }
        else { print("  dismissal: monitor torn down on close, nothing runs at idle") }

        popover.performClose(nil); pump(0.2)
        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    func applicationWillTerminate(_ notification: Notification) { limiter?.stop() }

    // MARK: - Main view

    /// Hands the freshly built `mainView` to the popover in a **new** view
    /// controller.
    ///
    /// Deliberately not `popover.contentViewController.view = mainView`: that
    /// makes AppKit resize the *outgoing* view, whose subviews keep their
    /// absolute positions and are pushed out of bounds (CLAUDE.md, fixed bug 4).
    /// Replacing the controller discards the old view instead of resizing it,
    /// and every frame in the new one is computed from scratch by `buildMainView`.
    private func installMainView() {
        let vc = NSViewController()
        vc.view = mainView
        popover.contentViewController = vc
        popover.contentSize = mainView.frame.size
    }

    /// The sensor showed up after launch. Rebuild the panel around it — but not
    /// underneath the user: swapping the content of a popover that is currently
    /// on screen resizes it mid-display. It is closed almost all of the time,
    /// so waiting costs nothing.
    private func sensorAppeared() {
        guard !sensorSectionShown, let backlight else { return }
        guard !popover.isShown else { rebuildWhenClosed = true; return }
        rebuildWhenClosed = false
        buildMainView(backlight: backlight, hasSensor: true)
        installMainView()
        if let latest = latestUpdateVersion { showUpdateAvailable(latest) }
    }

    private func buildMainView(backlight: KeyboardBacklight, hasSensor: Bool) {
        sensorSectionShown = hasSensor
        // 366/266. Both checkboxes used to carry an explanatory note under
        // them, worth 68pt between them; the notes were removed as noise.
        let h: CGFloat = hasSensor ? 366 : 266
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: h))

        // Belt and braces with the activation ordering above: an explicit
        // backdrop pinned to .active never renders the inactive,
        // over-transparent variant, whatever the window is doing.
        let backdrop = NSVisualEffectView(frame: v.bounds)
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        v.addSubview(backdrop)

        var y = h - 30

        let title = label("Dim Keys", 13, .semibold)
        title.frame = NSRect(x: 16, y: y, width: W - 32, height: 18)
        v.addSubview(title)
        y -= 30

        let maxLabel = label("Maximum brightness limit", 11, .regular)
        maxLabel.textColor = .secondaryLabelColor
        maxLabel.frame = NSRect(x: 16, y: y, width: W - 32, height: 15)
        v.addSubview(maxLabel)
        y -= 28

        presetControl = NSSegmentedControl(
            labels: Preset.allCases.map(\.label),
            trackingMode: .selectOne,
            target: self,
            action: #selector(presetChanged(_:)))
        presetControl.frame = NSRect(x: 16, y: y, width: W - 32, height: 24)
        v.addSubview(presetControl)
        y -= 32

        slider = NSSlider(value: Self.percent(for: Settings.ceiling), minValue: 1, maxValue: 100,
                          target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.isEnabled = Settings.ceiling > 0
        slider.frame = NSRect(x: 16, y: y, width: W - 32, height: 20)
        v.addSubview(slider)
        y -= 24

        ceilingField = label(Self.ceilingText(Settings.ceiling), 11, .regular)
        ceilingField.frame = NSRect(x: 16, y: y, width: (W - 32) / 2, height: 15)
        v.addSubview(ceilingField)

        currentField = label(currentText(backlight.brightness()), 11, .regular)
        currentField.textColor = .secondaryLabelColor
        currentField.alignment = .right
        currentField.frame = NSRect(x: W / 2, y: y, width: W / 2 - 16, height: 15)
        v.addSubview(currentField)
        y -= 18

        if hasSensor {
            v.addSubview(separator(at: y))
            y -= 26

            let sensLabel = label("Ambient light sensitivity", 11, .regular)
            sensLabel.textColor = .secondaryLabelColor
            sensLabel.frame = NSRect(x: 16, y: y, width: W - 32, height: 15)
            v.addSubview(sensLabel)
            y -= 28

            sensitivityControl = NSSegmentedControl(
                labels: Sensitivity.allCases.map(\.label),
                trackingMode: .selectOne,
                target: self,
                action: #selector(sensitivityChanged(_:)))
            sensitivityControl.frame = NSRect(x: 16, y: y, width: W - 32, height: 24)
            sensitivityControl.selectedSegment = Settings.sensitivity.rawValue
            v.addSubview(sensitivityControl)
            y -= 22

            sensitivityHint = label(Settings.sensitivity.explanation, 10, .regular)
            sensitivityHint.textColor = .tertiaryLabelColor
            sensitivityHint.frame = NSRect(x: 16, y: y, width: (W - 32) * 0.62, height: 14)
            v.addSubview(sensitivityHint)

            luxField = label("Ambient: — lux", 10, .regular)
            luxField.textColor = .tertiaryLabelColor
            luxField.alignment = .right
            luxField.frame = NSRect(x: W * 0.55, y: y, width: W * 0.45 - 16, height: 14)
            v.addSubview(luxField)
            y -= 24
        } else {
            luxField = label("", 10, .regular)
            sensitivityHint = label("", 10, .regular)
        }

        v.addSubview(separator(at: y))
        y -= 26

        loginCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                 target: self, action: #selector(loginToggled(_:)))
        loginCheckbox.frame = NSRect(x: 16, y: y, width: W - 32, height: 20)
        v.addSubview(loginCheckbox)
        y -= 30

        hideIconCheckbox = NSButton(checkboxWithTitle: "Hide menu bar icon",
                                    target: self, action: #selector(hideIconToggled(_:)))
        hideIconCheckbox.frame = NSRect(x: 16, y: y, width: W - 32, height: 20)
        v.addSubview(hideIconCheckbox)

        // Bottom row: version left, the support button and Quit right. That
        // button is measured rather than fixed-width — its title is the one
        // piece here that might be reworded, and has been — and everything to
        // its left is positioned off the result. `KBL_SELFTEST` asserts they
        // never collide, and that the update notice still fits what is left.
        // Both buttons are measured. Quit used to be a fixed 58pt, which was
        // ~10pt of slack nobody needed; the longer support title spends the
        // row's whole budget, so that slack now belongs to the version label.
        let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.sizeToFit()
        let qw = Swift.max(ceil(quit.frame.width), 46)
        quit.frame = NSRect(x: W - 16 - qw, y: 12, width: qw, height: 22)
        v.addSubview(quit)

        let support = NSButton(title: "Buy me a cookie", target: self, action: #selector(openSupport))
        support.bezelStyle = .rounded
        support.controlSize = .small
        support.sizeToFit()
        let sw = Swift.max(ceil(support.frame.width), 86)
        support.frame = NSRect(x: quit.frame.minX - 6 - sw, y: 12, width: sw, height: 22)
        v.addSubview(support)

        let version = label("Version \(Self.displayVersion)", 10, .regular)
        version.textColor = .tertiaryLabelColor
        version.lineBreakMode = .byTruncatingTail
        version.frame = NSRect(x: 16, y: 18,
                               width: Swift.max(40, support.frame.minX - 6 - 16), height: 14)
        v.addSubview(version)
        versionField = version

        // The update notice takes the label's slot as a borderless button, not
        // a clickable label. In macOS 27 AppKit runs its controls on gesture
        // recognisers, and a click recogniser added to the label lost to
        // AppKit's own (CLAUDE.md, fixed bug 12). A button is the standard
        // control for an action, and Apple's guidance for macOS 27 is that
        // standard controls work with touch as they are.
        let link = NSButton(title: "", target: self, action: #selector(openReleases))
        link.isBordered = false
        link.alignment = .left
        link.lineBreakMode = .byTruncatingTail
        link.toolTip = "A newer version is available on GitHub"
        // 1pt in from the label's frame: a borderless button pads its title
        // 1pt less than a label does, so this puts the text exactly where the
        // version's was, in line with the labels above. Measured at 1x.
        link.frame = NSRect(x: version.frame.minX + 1, y: version.frame.minY,
                            width: version.frame.width - 1, height: version.frame.height)
        link.isHidden = true
        v.addSubview(link)
        updateLink = link

        mainView = v
        syncPresetSelection()
        refreshLoginState()
    }

    private func separator(at y: CGFloat) -> NSBox {
        let sep = NSBox(frame: NSRect(x: 16, y: y, width: W - 32, height: 1))
        sep.boxType = .separator
        return sep
    }

    private func buildUnavailable() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 96))
        let msg = label("No keyboard backlight found on this Mac.", 12, .regular)
        (msg.cell as? NSTextFieldCell)?.wraps = true
        msg.frame = NSRect(x: 16, y: 48, width: W - 32, height: 34)
        v.addSubview(msg)
        let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.frame = NSRect(x: W - 74, y: 12, width: 58, height: 22)
        v.addSubview(quit)
        let vc = NSViewController(); vc.view = v
        popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = v.frame.size
        popover.behavior = .transient
    }

    private func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: size, weight: weight)
        return f
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let b = backlight {
                currentField?.stringValue = currentText(b.brightness())
            }
            refreshLoginState()
            limiter?.refresh()
            // Checking only at launch was near-useless: this app runs for
            // weeks at a time, so a long-lived install would never notice a
            // release. The panel is also the only place the notice appears, so
            // opening it is exactly the right moment. Still throttled to once
            // an hour, so this is at most one request an hour, not per open.
            checkForUpdate()
            // Activate *before* showing. The popover's material follows the
            // window's active state, so showing first meant it rendered in the
            // washed-out inactive look until activation caught up — visibly
            // over-transparent for the first moments after every open.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func presetChanged(_ sender: NSSegmentedControl) {
        guard let preset = Preset(rawValue: sender.selectedSegment) else { return }
        applyCeiling(preset.ceiling)
        slider.doubleValue = Self.percent(for: preset.ceiling)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        applyCeiling(Self.ceiling(forPercent: sender.doubleValue))
        syncPresetSelection()
    }

    private func applyCeiling(_ fraction: Float) {
        limiter?.setCeiling(fraction)
        Settings.ceiling = fraction
        ceilingField.stringValue = Self.ceilingText(fraction)
        // A maximum brightness means nothing while the keys are held off, so
        // the slider goes inert — the Off segment is the way back out.
        slider.isEnabled = fraction > 0
    }

    // MARK: - Slider scale
    //
    // The slider spans the *usable* ceiling range: 1% is the dimmest level the
    // hardware still lights (PWM 101), 100% is full. There is deliberately no
    // 0% on the slider — labelling the dimmest lit state "0%" read as if the
    // keyboard were off, and a genuinely off keyboard is now the Off preset,
    // which sets the ceiling to 0 outright and disables the slider.

    static func ceiling(forPercent p: Double) -> Float {
        let mv = Double(Limiter.minVisible)
        let clamped = max(1, min(100, p))
        return Float(mv + (clamped - 1) / 99.0 * (1.0 - mv))
    }

    static func percent(for ceiling: Float) -> Double {
        let mv = Double(Limiter.minVisible)
        let c = max(mv, min(1.0, Double(ceiling)))
        return 1 + (c - mv) / (1.0 - mv) * 99.0
    }

    static func ceilingText(_ c: Float) -> String {
        // percent(for:) floors at minVisible, so a 0 ceiling would otherwise
        // read as "1%" — the one value the slider cannot express.
        c <= 0 ? "Ceiling: off"
               : String(format: "Ceiling: %.0f%%", percent(for: c))
    }

    /// Reports the live brightness. Shows "off" rather than "0%" when dark,
    /// and never rounds a lit keyboard down to 0%.
    private func currentText(_ v: Float) -> String {
        v < 0.00001 ? "Current: off"
                    : String(format: "Current: %.0f%%", max(1.0, Double(v) * 100))
    }

    /// Highlight a preset only when the slider sits exactly on it.
    private func syncPresetSelection() {
        if let p = Preset.matching(Settings.ceiling) {
            presetControl.selectedSegment = p.rawValue
        } else {
            presetControl.selectedSegment = -1
        }
    }

    @objc private func sensitivityChanged(_ sender: NSSegmentedControl) {
        guard let s = Sensitivity(rawValue: sender.selectedSegment) else { return }
        Settings.sensitivity = s
        limiter?.setSensitivity(s)
        sensitivityHint.stringValue = s.explanation
    }

    /// The note under the checkbox used to carry this, and it is gone. Snapping
    /// the checkbox back with no explanation reads as a bug, so the failure
    /// gets an alert — a rare path, and the only channel left that costs no
    /// panel height. The /Applications caveat rides along here rather than
    /// sitting on screen permanently: it only ever mattered when this fails.
    @objc private func loginToggled(_ sender: NSButton) {
        let wanted = sender.state == .on
        guard let err = LaunchAtLogin.set(wanted) else {
            refreshLoginState()
            return
        }
        sender.state = wanted ? .off : .on
        popover.performClose(nil)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = wanted ? "Couldn't turn on launch at login"
                                   : "Couldn't turn off launch at login"
        var detail = err
        if wanted && !LaunchAtLogin.isInApplications {
            detail += "\n\nThe app is running from \(Bundle.main.bundlePath). "
                    + "Login items register the app at its current path, so move it "
                    + "to /Applications and try again."
        }
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshLoginState() {
        hideIconCheckbox.state = Settings.hideMenuBarIcon ? .on : .off
        loginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func hideIconToggled(_ sender: NSButton) {
        let hide = sender.state == .on
        Settings.hideMenuBarIcon = hide
        if hide { popover.performClose(nil) }
        statusItem.isVisible = !hide
    }

    /// Re-opening the app is the only way back once the icon is hidden, so
    /// always restore it here rather than silently doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !statusItem.isVisible {
            Settings.hideMenuBarIcon = false
            statusItem.isVisible = true
            hideIconCheckbox?.state = .off
        }
        return true
    }

    /// Read from the bundle, never hardcoded — the panel would otherwise drift
    /// from Info.plist, and the version is now load-bearing for update checks.
    /// Falls back when there is no bundle at all, i.e. the bare test binary.
    private static var displayVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Repurposes the version label rather than adding a row. The panel is laid
    /// out with absolute frames at one fixed height, so an appearing row would
    /// mean reflowing everything below it; reusing this slot leaves the bottom
    /// row exactly as the layout self-test already guards it.
    // MARK: - Dismissal

    /// `.transient` is documented to close the popover when the user interacts
    /// outside it, and it does for ordinary windows — but **not for menu bar
    /// extras**. Clicking Control Center, Wi-Fi or the clock left the panel
    /// sitting open, and only clicking our own icon again dismissed it.
    ///
    /// A global mouse monitor sees those clicks. It is installed only while the
    /// popover is up and torn down on close, so nothing runs at idle — which
    /// matters for an app whose pitch is 0.0% CPU when nothing is happening.
    func popoverDidShow(_ notification: Notification) {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if rebuildWhenClosed { sensorAppeared() }
    }

    /// Notifies only — never installs. Silent on failure, and skipped when
    /// there is no bundle to read a version from (the bare test binary).
    private func checkForUpdate() {
        guard Self.displayVersion != "dev" else { return }
        UpdateCheck.check(currentVersion: Self.displayVersion) { [weak self] latest in
            self?.showUpdateAvailable(latest)
            // Also as a system notification, which is the only channel that
            // reaches a hidden icon or an app nobody has opened in weeks.
            // Deduplicated by version inside the notifier.
            UpdateNotifier.shared.notifyIfNew(version: latest)
        }
    }

    /// Checking at launch and on panel open was never enough on its own: with
    /// the menu bar icon hidden the panel cannot be opened at all, so the launch
    /// check was the *only* one that ever ran — for an app that stays up for
    /// weeks. A notification with nothing to report is useless, so the schedule
    /// is the load-bearing half of this.
    ///
    /// `UpdateCheck` still throttles to one request an hour, so this cannot
    /// become chatty regardless of the interval chosen here.
    ///
    /// Wall-clock time, not `deadline:`. A `DispatchTime` deadline runs on
    /// `mach_absolute_time()`, which stops while the Mac sleeps, so "six hours"
    /// meant six hours *awake*. On a laptop that is closer to a day: the
    /// installed 1.2.0 had been awake 2h42m of the 6h32m after its launch and
    /// still had not checked for 1.2.1. A wall-clock timer that comes due
    /// during sleep fires on the next wake.
    private func startUpdateTimer() {
        guard Self.displayVersion != "dev" else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + Self.updateInterval,
                   repeating: Self.updateInterval,
                   leeway: .seconds(600))
        t.setEventHandler { [weak self] in self?.checkForUpdate() }
        updateTimer = t
        t.resume()
    }

    private func showUpdateAvailable(_ latest: String) {
        latestUpdateVersion = latest
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        updateLink.attributedTitle = NSAttributedString(
            string: "Update to \(latest)",
            attributes: [.font: versionField.font ?? .systemFont(ofSize: 10),
                         .foregroundColor: NSColor.linkColor,
                         .paragraphStyle: style])
        updateLink.isHidden = false
        versionField.isHidden = true
    }

    /// How the releases page is opened. The self-test swaps this out, so it can
    /// click the link for real without launching a browser.
    private var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @objc private func openReleases() {
        popover.performClose(nil)
        openURL(UpdateCheck.releasesPage)
    }

    private static let supportURL = "https://buymeacoffee.com/martun"

    /// The popover is `.transient` and the browser taking focus would dismiss
    /// it anyway; closing it first makes that look deliberate rather than like
    /// the panel glitched away.
    @objc private func openSupport() {
        popover.performClose(nil)
        if let url = URL(string: Self.supportURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
