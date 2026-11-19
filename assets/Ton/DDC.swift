import Foundation
import IOKit
import QuartzCore

final class DDCDisplay {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ name: String) -> T? {
        guard let l = lib, let s = dlsym(l, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
    private static let createFn: CreateFn? = sym("IOAVServiceCreateWithService")
    private static let writeFn: I2CFn? = sym("IOAVServiceWriteI2C")
    private static let readFn: I2CFn? = sym("IOAVServiceReadI2C")

    static let vcpVolume: UInt8 = 0x62
    static let vcpMute: UInt8 = 0x8D

    let name: String
    private let service: CFTypeRef

    private init(name: String, service: CFTypeRef) {
        self.name = name
        self.service = service
    }

    static func all() -> [DDCDisplay] {
        guard let create = createFn else { return [] }
        func prop(_ e: io_registry_entry_t, _ k: String) -> Any? {
            IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        var result: [DDCDisplay] = []
        var lastName = ""
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(it) }
        var e = IOIteratorNext(it)
        while e != 0 {
            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(e, &cls)
            let c = String(cString: cls)
            if c.contains("AppleCLCD2") || c.contains("IOMobileFramebufferShim") {
                if let attrs = prop(e, "DisplayAttributes") as? [String: Any],
                   let p = attrs["ProductAttributes"] as? [String: Any] {
                    lastName = (p["ProductName"] as? String) ?? ""
                }
            } else if c == "DCPAVServiceProxy", (prop(e, "Location") as? String) == "External",
                      let svc = create(kCFAllocatorDefault, e)?.takeRetainedValue() {
                result.append(DDCDisplay(name: lastName, service: svc))
            }
            IOObjectRelease(e)
            e = IOIteratorNext(it)
        }
        return result
    }

    func read(_ code: UInt8) -> (cur: Int, max: Int)? {
        guard let write = Self.writeFn, let read = Self.readFn else { return nil }
        var req: [UInt8] = [0x82, 0x01, code, 0]
        req[3] = 0x6E ^ 0x51 ^ req[0] ^ req[1] ^ req[2]
        for _ in 0..<3 {
            var ok = false
            for _ in 0..<2 {
                ok = write(service, 0x37, 0x51, &req, 4) == KERN_SUCCESS || ok
                usleep(10_000)
            }
            guard ok else { return nil }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if read(service, 0x37, 0x51, &reply, 11) == KERN_SUCCESS,
               let i = reply.firstIndex(of: 0x02), i + 7 < reply.count, reply[i + 2] == code {
                guard reply[i + 1] == 0 else { return nil }
                return (Int(reply[i + 6]) << 8 | Int(reply[i + 7]), Int(reply[i + 4]) << 8 | Int(reply[i + 5]))
            }
            usleep(40_000)
        }
        return nil
    }

    @discardableResult
    func write(_ code: UInt8, _ value: Int) -> Bool {
        guard let write = Self.writeFn else { return false }
        var p: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        p[5] = 0x6E ^ 0x51 ^ p[0] ^ p[1] ^ p[2] ^ p[3] ^ p[4]
        var ok = false
        for _ in 0..<2 {
            ok = write(service, 0x37, 0x51, &p, 6) == KERN_SUCCESS || ok
            usleep(10_000)
        }
        return ok
    }
}

final class DDCVolumeTarget {
    let display: DDCDisplay
    let maxVolume: Int
    let hasMute: Bool
    var volume: Float
    var muted: Bool

    private let queue = DispatchQueue(label: "local.disbright.ddc")
    private let lock = NSLock()
    private var pending: [UInt8: Int] = [:]

    init(display: DDCDisplay, maxVolume: Int, volume: Float, hasMute: Bool, muted: Bool) {
        self.display = display
        self.maxVolume = maxVolume
        self.volume = volume
        self.hasMute = hasMute
        self.muted = muted
    }

    func send(_ code: UInt8, _ value: Int) {
        lock.lock()
        let idle = pending.isEmpty
        pending[code] = value
        lock.unlock()
        guard idle else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending.first else { lock.unlock(); return }
                pending[next.key] = nil
                lock.unlock()
                if !display.write(next.key, next.value) {
                    log.error("DDC-Schreiben fehlgeschlagen (VCP \(next.key))")
                }
            }
        }
    }
}
