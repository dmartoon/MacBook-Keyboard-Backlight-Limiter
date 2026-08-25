import Foundation

/// Brightness ceiling presets. Values are normalized 0.0–1.0, which the
/// hardware maps linearly onto PWM 100–14660.
enum Preset: Int, CaseIterable {
    case off = 0, min = 1, med = 2, max = 3

    /// 0 is fully dark — the only ceiling that keeps the keys unlit at every
    /// ambient level. 0.0001 ≈ PWM 101 is the hardware's floor short of that;
    /// anything above 0 snaps to at least PWM 100 on this hardware.
    var ceiling: Float {
        switch self {
        case .off:  return 0.0
        case .min:  return 0.0001
        case .med:  return 0.35
        case .max:  return 1.0
        }
    }

    var label: String {
        switch self {
        case .off:  return "Off"
        case .min:  return "Min"
        case .med:  return "Med"
        case .max:  return "Max"
        }
    }

    /// Nearest preset for a given ceiling, or nil if the slider sits between them.
    ///
    /// Off is matched exactly rather than by proximity: it sits 0.0001 from
    /// Min — far inside the tolerance the other presets need — so a proximity
    /// match would claim Min's position as well and Min would never highlight.
    static func matching(_ ceiling: Float) -> Preset? {
        if ceiling <= 0 { return .off }
        return allCases.first { $0 != .off && abs($0.ceiling - ceiling) < 0.005 }
    }
}

/// How readily the backlight comes on, expressed as the ambient light level
/// at which it reaches zero.
///
/// macOS exposes no sensitivity control, and writing the brightness property
/// disengages its auto-brightness entirely, so the app supplies the whole
/// curve itself. That also means High can legitimately light the keys in room
/// light where stock macOS would suppress them.
enum Sensitivity: Int, CaseIterable {
    case low = 0, med = 1, high = 2

    /// Ambient level at or above which the keys switch off.
    var offLux: Int {
        switch self {
        case .low:  return 10    // effectively an unlit room
        case .med:  return 60    // a dimly lit room
        case .high: return 150   // normal room light
        }
    }

    /// Ambient level below which the keys switch back on. The gap between this
    /// and `offLux` is the hysteresis band: sensor readings jitter by a few
    /// lux, and without a gap the keys blink on and off at the boundary.
    var onLux: Int {
        switch self {
        case .low:  return 7
        case .med:  return 48
        case .high: return 120
        }
    }

    var label: String {
        switch self {
        case .low:  return "Low"
        case .med:  return "Med"
        case .high: return "High"
        }
    }

    var explanation: String {
        switch self {
        case .low:  return "Only when it's really dark"
        case .med:  return "In a dimly lit room"
        case .high: return "Even in normal room light"
        }
    }
}

/// Persisted preferences.
enum Settings {
    private static let ceilingKey = "ceilingFraction"
    private static let sensitivityKey = "sensitivity"
    private static let hideIconKey = "hideMenuBarIcon"

    static var ceiling: Float {
        get {
            let v = UserDefaults.standard.object(forKey: ceilingKey) as? Double
            return Float(v ?? 1.0)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: ceilingKey) }
    }

    /// Hide the menu bar icon while leaving the app running. Re-opening the
    /// app brings it back — otherwise there would be no way to reach settings.
    static var hideMenuBarIcon: Bool {
        get { UserDefaults.standard.bool(forKey: hideIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideIconKey) }
    }

    static var sensitivity: Sensitivity {
        get {
            let raw = UserDefaults.standard.object(forKey: sensitivityKey) as? Int
            return Sensitivity(rawValue: raw ?? Sensitivity.high.rawValue) ?? .high
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sensitivityKey) }
    }
}
