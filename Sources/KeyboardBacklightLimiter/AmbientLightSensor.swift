import Foundation
import IOKit

/// Reads the ambient light level in lux.
///
/// The publishing driver differs per machine (AppleSPUVD6286 on Apple silicon
/// MacBook Pros, other Vishay/AMS parts elsewhere), so rather than matching a
/// class name we walk the IO registry for any entry exposing a `CurrentLux`
/// property.
final class AmbientLightSensor {
    private let service: io_service_t

    private init(service: io_service_t) { self.service = service }
    deinit { IOObjectRelease(service) }

    /// Number of times a truncated walk is retried. The registry settles in
    /// microseconds, so this is about surviving a concurrent change, not about
    /// waiting for anything.
    private static let attempts = 8

    /// Looks for the sensor, or nil if this Mac has none *right now*.
    ///
    /// "Right now" is load-bearing: a nil here is not proof the machine has no
    /// ambient light sensor, which is why `Limiter` keeps asking. Two things
    /// make a launch-time probe unreliable, and both were live at the moment
    /// this app runs — 21 seconds into boot, as a login item:
    ///
    /// 1. The driver may not have published `CurrentLux` yet.
    /// 2. **A recursive registry iterator is invalidated by any change to the
    ///    structure it is walking**, and `IOIteratorNext` then simply returns
    ///    0. A truncated walk is therefore indistinguishable from a completed
    ///    one that found nothing — and the registry churns hardest during
    ///    login, while drivers are still matching. So check `IOIteratorIsValid`
    ///    and walk again; only a walk that ran to completion may return nil.
    static func find() -> AmbientLightSensor? {
        for _ in 0..<attempts {
            var iter: io_iterator_t = 0
            guard IORegistryCreateIterator(kIOMainPortDefault,
                                           kIOServicePlane,
                                           IOOptionBits(kIORegistryIterateRecursively),
                                           &iter) == KERN_SUCCESS else { return nil }

            if let sensor = scan(iter) {
                IOObjectRelease(iter)
                return sensor
            }
            let truncated = IOIteratorIsValid(iter) == 0
            IOObjectRelease(iter)
            if !truncated { return nil }   // a complete walk: this Mac has none
        }
        return nil
    }

    /// Consumes `iter`, returning the first entry that publishes `CurrentLux`.
    private static func scan(_ iter: io_iterator_t) -> AmbientLightSensor? {
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { return nil }
            if let v = IORegistryEntryCreateCFProperty(entry, "CurrentLux" as CFString,
                                                       kCFAllocatorDefault, 0) {
                v.release()
                return AmbientLightSensor(service: entry)   // keeps the reference
            }
            IOObjectRelease(entry)
        }
    }

    /// Current ambient light in lux, or nil if the read failed.
    func lux() -> Int? {
        guard let v = IORegistryEntryCreateCFProperty(service, "CurrentLux" as CFString,
                                                      kCFAllocatorDefault, 0) else { return nil }
        defer { v.release() }
        guard let n = v.takeUnretainedValue() as? NSNumber else { return nil }
        return n.intValue
    }
}
