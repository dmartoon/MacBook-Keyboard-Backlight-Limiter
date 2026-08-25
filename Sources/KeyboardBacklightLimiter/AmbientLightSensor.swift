import Foundation
import IOKit

/// Reads the ambient light level in lux.
///
/// The publishing driver differs per machine (AppleSPUVD6286 on M3 MacBook Pro,
/// other Vishay/AMS parts elsewhere), so rather than matching a class name we
/// walk the IO registry once for any entry exposing a `CurrentLux` property.
final class AmbientLightSensor {
    private let service: io_service_t

    private init(service: io_service_t) { self.service = service }
    deinit { IOObjectRelease(service) }

    static func find() -> AmbientLightSensor? {
        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault,
                                       kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively),
                                       &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            if let v = IORegistryEntryCreateCFProperty(entry, "CurrentLux" as CFString,
                                                       kCFAllocatorDefault, 0) {
                v.release()
                return AmbientLightSensor(service: entry)   // keeps the reference
            }
            IOObjectRelease(entry)
        }
        return nil
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
