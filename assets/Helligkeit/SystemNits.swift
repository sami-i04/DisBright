import Foundation
import CoreGraphics
import IOKit

enum SystemNits {
    private typealias InfoFn = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private static let infoFn: InfoFn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW),
              let sym = dlsym(h, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(sym, to: InfoFn.self)
    }()

    private static func num(_ d: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let v = (d[k] as? NSNumber)?.doubleValue, v > 0 { return Int(round(v)) }
        }
        return nil
    }

    private static func edidPeak(_ edid: Data) -> Int? {
        let b = [UInt8](edid)
        guard b.count >= 256 else { return nil }
        var block = 128
        while block + 128 <= b.count {
            if b[block] == 0x02 {
                let dtdStart = Int(b[block + 2])
                var i = block + 4
                while i < block + min(dtdStart, 127) {
                    let tag = b[i] >> 5, len = Int(b[i] & 0x1F)
                    if tag == 7, len >= 4, b[i + 1] == 0x06 {
                        let cv = Double(b[i + 4])
                        if cv > 0 { return Int(round(50.0 * pow(2.0, cv / 32.0))) }
                    }
                    i += len + 1
                }
            }
            block += 128
        }
        return nil
    }

    static func read(_ id: CGDirectDisplayID, name: String) -> (sdr: Int?, peak: Int?) {
        let d = (infoFn?(id)?.takeRetainedValue() as? [String: Any]) ?? [:]
        var peak = num(d, ["NonReferencePeakHDRLuminance", "ReferencePeakHDRLuminance", "DisplayMaxLuminance", "MaxLuminance"])
        var sdr = num(d, ["NonReferencePeakSDRLuminance", "ReferencePeakSDRLuminance"])
        if peak == nil, let edid = d["IODisplayEDID"] as? Data { peak = edidPeak(edid) }
        if peak == nil || sdr == nil, CGDisplayIsBuiltin(id) == 0,
           let fb = framebufferLuminance(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), name: name) {
            peak = peak ?? fb.peak
            sdr = sdr ?? fb.frameAverage
        }
        return (sdr, peak)
    }

    private static func framebufferLuminance(vendor: UInt32, model: UInt32, name: String) -> (peak: Int?, frameAverage: Int?)? {
        for cls in ["AppleCLCD2", "IOMobileFramebufferShim"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            var e = IOIteratorNext(it)
            while e != 0 {
                defer { IOObjectRelease(e); e = IOIteratorNext(it) }
                guard let attrs = IORegistryEntryCreateCFProperty(e, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [String: Any],
                      let p = attrs["ProductAttributes"] as? [String: Any],
                      (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor,
                      (p["ProductID"] as? NSNumber)?.uint32Value == model || (p["ProductName"] as? String) == name,
                      let lum = attrs["Luminance"] as? [String: Any] else { continue }
                func nits(_ k: String) -> Int? {
                    guard let v = (lum[k] as? NSNumber)?.doubleValue, v > 0 else { return nil }
                    return Int((v / 65536).rounded())
                }
                return (nits("Max"), nits("MaxFrameAverage"))
            }
        }
        return nil
    }
}
