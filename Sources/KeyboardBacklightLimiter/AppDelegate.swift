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
    private var globalClickMonitor: Any?
    private var loginCheckbox: NSButton!
    private var loginNote: NSTextField!
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
            button.image?.accessibilityDescription = "Keyboard Backlight Limiter"
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

        buildMainView(backlight: backlight, hasSensor: sensor != nil)

        let vc = NSViewController()
        vc.view = mainView
        popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = mainView.frame.size
        popover.behavior = .transient
        popover.delegate = self

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

        checkForUpdate()

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

        // A real window so the popover can actually lay out.
        let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.makeKeyAndOrderFront(nil)
        let anchor = NSView(frame: NSRect(x: 180, y: 140, width: 20, height: 20))
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

        for sub in mainView.subviews where !mainView.bounds.contains(sub.frame) {
            fail("out of bounds: \(name(sub)) at \(NSStringFromRect(sub.frame))")
        }

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

        // The update notice reuses the version label's slot rather than adding a
        // row, and "Update to ..." is wider than "Version ...". Two separate
        // guarantees: a realistic version must not truncate, and even an absurd
        // one must not collide with the Support button.
        //
        // Truncation is measured off the cell, not off the string: NSTextField
        // adds internal insets, so measuring the string alone reports ~4pt more
        // room than actually exists and calls a truncating label "fits".
        showUpdateAvailable("1.10.0")
        mainView.layoutSubtreeIfNeeded()
        pump(0.2)
        if let cell = versionField.cell {
            let needed = cell.cellSize.width, have = versionField.frame.width
            if needed > have {
                fail(String(format: "update notice truncates at a realistic version: needs %.1fpt, has %.1fpt", needed, have))
            } else {
                print(String(format: "  update notice \u{22}%@\u{22} needs %.1fpt of %.1fpt", versionField.stringValue as NSString, needed, have))
            }
        }
        checkBottomRow("update available")

        showUpdateAvailable("10.20.30")
        mainView.layoutSubtreeIfNeeded()
        pump(0.2)
        checkBottomRow("update, absurd version")

        // KBL_SNAPSHOT=<path> dumps what the panel actually renders, which is
        // the only way to catch layout that is technically in-bounds but ugly.
        // Capture the popover's own window off the window server. Both
        // offscreen paths (cacheDisplay and dataWithPDF) render the text but
        // drop every AppKit control — sliders, segmented controls, checkboxes
        // and buttons all come back blank — so the only faithful render is the
        // real composited window.
        if let out = ProcessInfo.processInfo.environment["KBL_SNAPSHOT"] {
            pump(0.4)
            if let win = mainView.window {
                let id = CGWindowID(win.windowNumber)
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                     [.boundsIgnoreFraming, .bestResolution]) {
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

        // Dismissal. Only the monitor lifecycle is assertable here: a process
        // launched from a terminal cannot become frontmost, so NSApp.isActive
        // stays false and the app can never *resign* active either. Asserting
        // the focus-loss behaviour unconditionally would fail for purely
        // environmental reasons, which is worse than not testing it — a suite
        // that cries wolf gets ignored.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        pump(0.4)
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
                pump(1.0)
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

    private func buildMainView(backlight: KeyboardBacklight, hasSensor: Bool) {
        let h: CGFloat = hasSensor ? 434 : 334
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

        let title = label("Keyboard Backlight Limiter", 13, .semibold)
        title.frame = NSRect(x: 16, y: y, width: W - 32, height: 18)
        v.addSubview(title)
        y -= 30

        let maxLabel = label("Maximum brightness", 11, .regular)
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
        y -= 32

        loginNote = label("", 10, .regular)
        loginNote.textColor = .tertiaryLabelColor
        (loginNote.cell as? NSTextFieldCell)?.wraps = true
        loginNote.frame = NSRect(x: 34, y: y, width: W - 50, height: 30)
        v.addSubview(loginNote)
        y -= 34

        hideIconCheckbox = NSButton(checkboxWithTitle: "Hide menu bar icon",
                                    target: self, action: #selector(hideIconToggled(_:)))
        hideIconCheckbox.frame = NSRect(x: 16, y: y, width: W - 32, height: 20)
        v.addSubview(hideIconCheckbox)
        y -= 32

        let hideNote = label("The app keeps running. Open it again to bring the icon back.",
                             10, .regular)
        hideNote.textColor = .tertiaryLabelColor
        (hideNote.cell as? NSTextFieldCell)?.wraps = true
        hideNote.frame = NSRect(x: 34, y: y, width: W - 50, height: 28)
        v.addSubview(hideNote)

        // Bottom row: version left, Support me and Quit right. The Support
        // button is measured rather than fixed-width — its title is the one
        // piece here that might be reworded — and everything to its left is
        // positioned off the result. `KBL_SELFTEST` asserts they never collide.
        let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.frame = NSRect(x: W - 74, y: 12, width: 58, height: 22)
        v.addSubview(quit)

        let support = NSButton(title: "Support me", target: self, action: #selector(openSupport))
        support.bezelStyle = .rounded
        support.controlSize = .small
        support.sizeToFit()
        let sw = Swift.max(ceil(support.frame.width), 86)
        support.frame = NSRect(x: quit.frame.minX - 8 - sw, y: 12, width: sw, height: 22)
        v.addSubview(support)

        let version = label("Version \(Self.displayVersion)", 10, .regular)
        version.textColor = .tertiaryLabelColor
        version.lineBreakMode = .byTruncatingTail
        version.frame = NSRect(x: 16, y: 18,
                               width: Swift.max(40, support.frame.minX - 8 - 16), height: 14)
        v.addSubview(version)
        versionField = version

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

    @objc private func loginToggled(_ sender: NSButton) {
        let wanted = sender.state == .on
        if let err = LaunchAtLogin.set(wanted) {
            sender.state = wanted ? .off : .on
            loginNote.stringValue = "Couldn't change: \(err)"
            loginNote.textColor = .systemRed
        } else {
            refreshLoginState()
        }
    }

    private func refreshLoginState() {
        hideIconCheckbox.state = Settings.hideMenuBarIcon ? .on : .off
        loginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        loginNote.textColor = .tertiaryLabelColor
        loginNote.stringValue = LaunchAtLogin.isInApplications
            ? "Starts automatically when you log in."
            : "Move the app to /Applications first — otherwise the login item breaks if the app moves."
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
    }

    /// Notifies only — never installs. Silent on failure, and skipped when
    /// there is no bundle to read a version from (the bare test binary).
    private func checkForUpdate() {
        guard Self.displayVersion != "dev" else { return }
        UpdateCheck.check(currentVersion: Self.displayVersion) { [weak self] latest in
            self?.showUpdateAvailable(latest)
        }
    }

    private func showUpdateAvailable(_ latest: String) {
        versionField.stringValue = "Update to \(latest)"
        versionField.textColor = .linkColor
        versionField.toolTip = "A newer version is available on GitHub"
        // Guarded: this can now run on every panel open, and a recogniser per
        // call would stack up duplicates on the same label.
        if versionField.gestureRecognizers.isEmpty {
            versionField.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(openReleases)))
        }
    }

    @objc private func openReleases() {
        popover.performClose(nil)
        NSWorkspace.shared.open(UpdateCheck.releasesPage)
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
