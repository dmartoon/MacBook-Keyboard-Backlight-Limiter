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
    private let sensor: AmbientLightSensor?
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

    /// (brightness now in force, lux, whether the ambient gate is holding it off)
    var onChange: ((Float, Int?, Bool) -> Void)?

    var ceiling: Float { lock.lock(); defer { lock.unlock() }; return _ceiling }
    var sensitivity: Sensitivity { lock.lock(); defer { lock.unlock() }; return _sensitivity }
    var hasSensor: Bool { sensor != nil }

    init(backlight: KeyboardBacklight, sensor: AmbientLightSensor?,
         ceiling: Float, sensitivity: Sensitivity) {
        self.backlight = backlight
        self.sensor = sensor
        self._ceiling = Self.clamp(ceiling)
        self._sensitivity = sensitivity
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

        // Leaving the keys dark on quit strands them. macOS does not pick the
        // backlight back up on its own — measured: a graceful quit with the
        // keys held dark at 5 lux left PWM 0 sitting there untouched. Once we
        // exit nothing is driving it at all, so hand back a plainly lit
        // keyboard rather than one that looks broken. A keyboard the user
        // already had lit is left exactly as it was.
        if backlight.brightness() < Self.offEpsilon {
            backlight.setBrightness(Self.restoreOnQuit)
        }

        // Best effort, and it must come *after* the write above: writing the
        // brightness property is itself what disengages auto-brightness, so
        // enabling it first would be undone immediately. It has never actually
        // been observed to re-engage, but it costs nothing on the way out.
        backlight.setAutoBrightness(true)
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

    /// Level handed back on quit when the keys would otherwise be left dark.
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

    /// Recompute and apply now — used when the panel opens.
    func refresh() { update() }

    private func update(force: Bool = false) {
        lock.lock()
        if isWriting { lock.unlock(); return }
        let ceil = _ceiling
        let sens = _sensitivity
        lock.unlock()

        let lux = sensor?.lux()
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
