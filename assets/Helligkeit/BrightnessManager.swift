import Foundation
import CoreGraphics

final class BrightnessManager {
    static let shared = BrightnessManager()
    private typealias DSGetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSetBrightness = @convention(c) (UInt32, Float) -> Int32
    private var getFn: DSGetBrightness?
    private var setFn: DSSetBrightness?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        if let s = dlsym(handle, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(s, to: DSGetBrightness.self) }
        if let s = dlsym(handle, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: DSSetBrightness.self) }
    }

    func get(for displayID: CGDirectDisplayID) -> Float {
        var v: Float = 1
        return getFn?(displayID, &v) == 0 ? v : 1.0
    }

    func set(for displayID: CGDirectDisplayID, value: Float) {
        _ = setFn?(displayID, min(1, max(0, value)))
    }
}
