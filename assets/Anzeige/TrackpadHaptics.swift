import Foundation
import IOKit

final class TrackpadHaptics {
    static let shared = TrackpadHaptics()

    private typealias CreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenFn = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    private var createFn: CreateFn?
    private var openFn: OpenFn?
    private var actuateFn: ActuateFn?
    private var actuators: [CFTypeRef] = []
    static let defaultStrength: Int32 = 3

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        else { return }
        if let s = dlsym(h, "MTActuatorCreateFromDeviceID") { createFn = unsafeBitCast(s, to: CreateFn.self) }
        if let s = dlsym(h, "MTActuatorOpen") { openFn = unsafeBitCast(s, to: OpenFn.self) }
        if let s = dlsym(h, "MTActuatorActuate") { actuateFn = unsafeBitCast(s, to: ActuateFn.self) }
    }

    private func openActuators() {
        actuators.removeAll()
        guard let create = createFn, let open = openFn else { return }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &it) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            if let n = IORegistryEntryCreateCFProperty(svc, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber,
               let a = create(n.uint64Value)?.takeRetainedValue(),
               open(a) == 0 {
                actuators.append(a)
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
    }

    func click(strength: Int32 = TrackpadHaptics.defaultStrength) -> Bool {
        guard let actuate = actuateFn else { return false }
        let id = min(6, max(1, strength))
        let actuateAll = { self.actuators.map { actuate($0, id, 0, 0, 0) }.contains(0) }
        if actuators.isEmpty { openActuators() }
        if actuateAll() { return true }
        openActuators()
        return actuateAll()
    }
}
