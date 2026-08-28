import Foundation

/// Drives the keyboard backlight from the ambient light sensor.
///
/// Design note — why this owns the curve instead of just clamping:
/// writing KeyboardBacklightBrightness is treated by macOS as a manual
/// override and permanently disengages its own auto-brightness for that
/// property (verified: a single write held for 12s at 96 lux, a level where
/// macOS had been suppressing to 0). So a passive "clamp only when it exceeds
/// the ceiling" limiter breaks the ALS the first time it fires, and a gate that
/// writes 0 leaves the set-point at "user turned it off" — which nothing ever
/// raises again. Instead we read lux ourselves and compute the whole curve.
///
/// This also works if macOS ever does keep driving: we recompute on every
/// change notification, so the last write wins and it converges either way.
final class Limiter {
    private let backlight: KeyboardBacklight
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.martun.KeyboardBacklightLimiter.drive", qos: .utility)

    /// Smallest change worth writing. Must stay well below the smallest
    /// ceiling we support: at the Min preset the entire on/off swing is only
    /// 0.01, so a deadband of 0.015 (the previous value) swallowed the whole
    /// transition and the keys never switched at all. One PWM step is roughly
    /// 0.00007, so 0.002 is ~29 steps — fine enough for Min, coarse enough to
    /// avoid thrashing.
    private static let deadband: Float = 0.002

    private var _ceiling: Float
    private var _sensitivity: Sensitivity
    private var isWriting = false
    private var lastWrite = Date.distantPast
    /// Whether the keys are currently meant to be lit — carried across samples
    /// so the ambient threshold can apply hysteresis.
    private var isLit = false

    /// Brightness the keyboard was at when we took it over, so quitting can
    /// hand it back instead of inventing a level.
    ///
    /// Read in `init` because that is the last moment it is still the user's
    /// value: `start()` writes on its first `update()`, and anything read
    /// after that is our own output.
    private let initialBrightness: Float

    /// The sensor, which may arrive *after* launch.
    ///
    /// This used to be a `let` decided once in `applicationDidFinishLaunching`,
    /// and that was wrong: as a login item the app probes 21 seconds into boot,
    /// where the answer is unreliable for the two reasons documented on
    /// `AmbientLightSensor.find()`. A machine with a perfectly good sensor
    /// therefore spent its entire session in no-sensor mode — the panel hid the
    /// sensitivity control and `computeTarget` just held the ceiling, with no
    /// ambient response at all — until the app was restarted by hand.
    ///
    /// So a nil is treated as "not yet", not as "never".
    private var sensor: AmbientLightSensor?
    /// How long after launch to keep re-probing on the sampling timer.
    /// Measured: 1.7ms per walk when the sensor is there (the walk stops at it),
    /// 7.1ms on a Mac that genuinely has none. So at worst ~0.85s of work spread
    /// across two minutes, once, and then nothing at idle. Past the deadline the
    /// only remaining probes are on panel open, which covers the long tail free.
    private let probeUntil = Date().addingTimeInterval(120)

    /// (brightness now in force, lux, whether the ambient gate is holding it off)
    var onChange: ((Float, Int?, Bool) -> Void)?
    /// Fired on the main queue the first time the sensor turns up, so the panel
    /// can grow the section it left out. Never fired if it was there at launch.
    var onSensorAppeared: (() -> Void)?

    var ceiling: Float { lock.lock(); defer { lock.unlock() }; return _ceiling }
    var sensitivity: Sensitivity { lock.lock(); defer { lock.unlock() }; return _sensitivity }
    var hasSensor: Bool { lock.lock(); defer { lock.unlock() }; return sensor != nil }

    init(backlight: KeyboardBacklight, sensor: AmbientLightSensor?,
         ceiling: Float, sensitivity: Sensitivity) {
        self.backlight = backlight
        self.sensor = sensor
        self._ceiling = Self.clamp(ceiling)
        self._sensitivity = sensitivity
        self.initialBrightness = backlight.brightness()
    }

    func start() {
        backlight.observeBrightness { [weak self] in self?.update() }
        // Ambient light has no change notification, so sample it. One IO
        // registry read per second is microseconds of work.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.update() }
        timer = t
        t.resume()
        update()
    }

    func stop() {
        timer?.cancel(); timer = nil
        backlight.stopObserving()

        // Hand back the level we found, not one we invented. Once we exit,
        // nothing drives the backlight at all — macOS does not resume, so
        // whatever we leave is what the user lives with until they press
        // F5/F6.
        //
        // The floor stays, and it is not paranoia: keys that were dark at
        // launch were dark *under macOS's management*, which would have re-lit
        // them when the room darkened. We cannot give that back — only a
        // frozen 0, which reads as a broken keyboard. So a dark starting point
        // restores to `restoreOnQuit`; every lit one restores exactly.
        let target = initialBrightness < Self.offEpsilon ? Self.restoreOnQuit : initialBrightness
        backlight.setBrightness(target)

        // Deliberately NOT setAutoBrightness(true) here. That call did not do
        // what its old comment claimed. Measured on J714s / macOS 26.6.2:
        //
        //   * The toggle is never flipped by writing the brightness property.
        //     It reads ON before our first write, after it, and 25s later —
        //     while the backlight sits frozen at PWM 0.1 in a 5 lux room. So
        //     there is no toggle state for us to repair.
        //   * Setting it true does not re-engage anything. Cycling it
        //     false -> true left the backlight untouched for 20s in that same
        //     dark room.
        //   * But it *is* a real preference, and writing it unconditionally
        //     clobbered users who had deliberately turned it off: quitting
        //     switched it back on every time.
        //
        // All cost, no benefit. The app never turns the toggle off, so simply
        // not touching it leaves it exactly as the user set it.
    }

    func setCeiling(_ value: Float) {
        lock.lock(); _ceiling = Self.clamp(value); lock.unlock()
        update(force: true)
    }

    func setSensitivity(_ s: Sensitivity) {
        lock.lock(); _sensitivity = s; lock.unlock()
        update(force: true)
    }

    /// Dimmest level the hardware produces without being off: PWM 101 of
    /// 14660. Measured on this machine — anything above 0 snaps to at least
    /// PWM 100, and 0 is fully dark. Confirmed visible in a dark room.
    static let minVisible: Float = 0.0001

    /// Anything below this counts as off. Must sit well under `minVisible`,
    /// or a keyboard lit at the floor is misread as dark and rewritten on
    /// every sample.
    private static let offEpsilon: Float = 0.00001

    /// Fallback level for quitting when there is nothing worth handing back —
    /// i.e. the keyboard was already dark when we took it over, so restoring
    /// what we found would strand the user with a frozen-off keyboard.
    /// Deliberately mid-scale rather than `minVisible`: the point is to leave
    /// no doubt the backlight still works, and PWM 101 in a lit room reads as
    /// every bit as broken as PWM 0.
    private static let restoreOnQuit: Float = 0.5

    /// Brightness the backlight should be at for a given ambient level.
    ///
    /// Fully dark gives the ceiling; brightness falls off as the room lightens
    /// and switches off at the sensitivity threshold. The 1.4 factor lets it
    /// saturate at the ceiling somewhat before pitch black, so a normally dark
    /// room gets the full allowance rather than a fraction of it.
    ///
    /// The lit state is floored at `minVisible` rather than fading toward
    /// zero: scaling a low ceiling by the ambient factor otherwise lands below
    /// the visible threshold. On means visible; off is a separate decision.
    private func computeTarget(lux: Int?, ceiling: Float, sensitivity: Sensitivity) -> Float {
        guard let lux else { return ceiling }   // no sensor: just hold the ceiling
        let offLux = Float(sensitivity.offLux)
        let onLux = Float(sensitivity.onLux)
        let level = Float(lux)

        lock.lock()
        if isLit {
            if level >= offLux { isLit = false }
        } else {
            if level < onLux { isLit = true }
        }
        let lit = isLit
        lock.unlock()

        guard lit else { return 0 }
        let darkness = 1.0 - min(1.0, level / offLux)
        let scaled = ceiling * min(1.0, darkness * 1.4)
        return max(min(Self.minVisible, ceiling), scaled)
    }

    /// Recompute and apply now — used when the panel opens. Always retries the
    /// sensor, however long the app has been up: the panel is about to be
    /// rebuilt around the answer, and one registry walk per open is free.
    func refresh() { update(probeSensor: true) }

    private func update(force: Bool = false, probeSensor: Bool = false) {
        lock.lock()
        if isWriting { lock.unlock(); return }
        let ceil = _ceiling
        let sens = _sensitivity
        var als = sensor
        let probe = als == nil && (probeSensor || Date() < probeUntil)
        lock.unlock()

        var appeared = false
        if probe, let found = AmbientLightSensor.find() {
            lock.lock()
            if sensor == nil { sensor = found; appeared = true }
            als = sensor
            lock.unlock()
        }
        if appeared {
            DispatchQueue.main.async { [weak self] in self?.onSensorAppeared?() }
        }

        let lux = als?.lux()
        let target = computeTarget(lux: lux, ceiling: ceil, sensitivity: sens)
        let current = backlight.brightness()

        // Only write on a meaningful difference, and never faster than 5 Hz,
        // so we don't thrash if something else is also writing. Crossing
        // between lit and dark always counts, however small the numeric gap —
        // that is the transition the user actually perceives.
        let isOff: (Float) -> Bool = { $0 < Self.offEpsilon }
        let crossesOnOff = isOff(target) != isOff(current)
        let differs = abs(current - target) > Self.deadband || crossesOnOff
        let cooled = Date().timeIntervalSince(lastWrite) > 0.2
        if differs && (cooled || force) {
            lock.lock(); isWriting = true; lock.unlock()
            backlight.setBrightness(target)
            lastWrite = Date()
            lock.lock(); isWriting = false; lock.unlock()
        }

        let shown = differs ? target : current
        let gated = target < Self.offEpsilon
        DispatchQueue.main.async { [weak self] in self?.onChange?(shown, lux, gated) }
    }

    private static func clamp(_ v: Float) -> Float { max(0, min(1, v)) }
}
