import Foundation

/// Bridge to CoreBrightness.framework's BrightnessSystemClient — the layer
/// corebrightnessd itself sits on. Reads and writes the normalized keyboard
/// backlight brightness (0.0–1.0) and delivers change notifications.
///
/// This is the only path that actually reaches the hardware from an
/// unprivileged process: the HID SetReport path and KeyboardBrightnessClient's
/// setBrightness: both report success but are silently dropped by the driver,
/// which honors only clients holding com.apple.hid.manager.user-access-protected.
final class KeyboardBacklight {

    static let brightnessKey = "KeyboardBacklightBrightness"

    @objc private protocol BrightnessSystemClientShim {
        @objc(copyPropertyForKey:keyboardID:)
        func copyProperty(forKey key: String, keyboardID: UInt64) -> Any?
        @objc(setProperty:withKey:keyboardID:)
        func setProperty(_ value: Any, withKey key: String, keyboardID: UInt64) -> Bool
        @objc(isAlsSupported)
        func isAlsSupported() -> Bool
    }

    @objc private protocol KeyboardBrightnessClientShim {
        func copyKeyboardBacklightIDs() -> [NSNumber]?
        @objc(isKeyboardBuiltIn:)
        func isKeyboardBuiltIn(_ kid: UInt64) -> Bool
        @objc(isAmbientFeatureAvailableOnKeyboard:)
        func isAmbientFeatureAvailable(onKeyboard kid: UInt64) -> Bool
        @objc(isAutoBrightnessEnabledForKeyboard:)
        func isAutoBrightnessEnabled(forKeyboard kid: UInt64) -> Bool
        @objc(enableAutoBrightness:forKeyboard:)
        func enableAutoBrightness(_ enabled: Bool, forKeyboard kid: UInt64) -> Bool
        @objc(backlightLevelForKeyboard:)
        func backlightLevel(forKeyboard kid: UInt64) -> Float
        @objc(registerNotificationForKeys:keyboardID:block:)
        func registerNotification(forKeys keys: [String], keyboardID: UInt64, block: @escaping (Any?) -> Void)
        @objc(unregisterKeyboardNotificationBlock)
        func unregisterKeyboardNotificationBlock()
    }

    private let bsc: BrightnessSystemClientShim
    private let kbc: KeyboardBrightnessClientShim
    private let bscObject: NSObject   // keep the instances alive
    private let kbcObject: NSObject
    let keyboardID: UInt64

    static func open() -> KeyboardBacklight? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let bscClass = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              let kbcClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }

        let bscObj = bscClass.init()
        let kbcObj = kbcClass.init()
        let bsc = unsafeBitCast(bscObj, to: BrightnessSystemClientShim.self)
        let kbc = unsafeBitCast(kbcObj, to: KeyboardBrightnessClientShim.self)

        guard let ids = kbc.copyKeyboardBacklightIDs(), !ids.isEmpty else { return nil }
        let kid = (ids.first { kbc.isKeyboardBuiltIn($0.uint64Value) } ?? ids[0]).uint64Value

        // Confirm the property actually exists on this machine.
        guard bsc.copyProperty(forKey: brightnessKey, keyboardID: kid) != nil else { return nil }

        return KeyboardBacklight(bsc: bsc, kbc: kbc, bscObject: bscObj, kbcObject: kbcObj, keyboardID: kid)
    }

    private init(bsc: BrightnessSystemClientShim,
                 kbc: KeyboardBrightnessClientShim,
                 bscObject: NSObject,
                 kbcObject: NSObject,
                 keyboardID: UInt64) {
        self.bsc = bsc
        self.kbc = kbc
        self.bscObject = bscObject
        self.kbcObject = kbcObject
        self.keyboardID = keyboardID
    }

    /// Current normalized brightness, 0.0–1.0.
    func brightness() -> Float {
        (bsc.copyProperty(forKey: Self.brightnessKey, keyboardID: keyboardID) as? NSNumber)?.floatValue ?? 0
    }

    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        let v = max(0, min(1, value))
        return bsc.setProperty(NSNumber(value: v), withKey: Self.brightnessKey, keyboardID: keyboardID)
    }

    /// Fires whenever the brightness changes — including changes driven by the
    /// ambient light sensor or the F5/F6 keys.
    func observeBrightness(_ handler: @escaping () -> Void) {
        kbc.registerNotification(forKeys: [Self.brightnessKey], keyboardID: keyboardID) { _ in
            handler()
        }
    }

    func stopObserving() { kbc.unregisterKeyboardNotificationBlock() }

    var isAutoBrightnessOn: Bool { kbc.isAutoBrightnessEnabled(forKeyboard: keyboardID) }

    /// - Warning: This is a **user preference**, and writing it is not the
    ///   harmless no-op it looks like. It does not re-engage macOS's ambient
    ///   control (measured: cycling false -> true left the backlight frozen for
    ///   20s in a 5 lux room), and calling it unconditionally on quit switched
    ///   the setting back on for users who had deliberately turned it off.
    ///   `Limiter.stop()` used to do exactly that. Do not reintroduce it.
    @discardableResult
    func setAutoBrightness(_ enabled: Bool) -> Bool {
        kbc.enableAutoBrightness(enabled, forKeyboard: keyboardID)
    }
    var hasAmbientSensor: Bool { kbc.isAmbientFeatureAvailable(onKeyboard: keyboardID) }
}
