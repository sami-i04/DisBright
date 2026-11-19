import AppKit

enum HDRMode {
    private typealias BoolFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func sym<T>(_ name: String) -> T? {
        guard let l = lib, let s = dlsym(l, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
    private static let supportsFn: BoolFn? = sym("SLSDisplaySupportsHDRMode")
    private static let isEnabledFn: BoolFn? = sym("SLSDisplayIsHDRModeEnabled")
    private static let setFn: SetFn? = sym("SLSDisplaySetHDRModeEnabled")

    static func isSupported(_ id: CGDirectDisplayID) -> Bool {
        guard setFn != nil, isEnabledFn != nil, let supports = supportsFn else { return false }
        return supports(id)
    }

    static func isEnabled(_ id: CGDirectDisplayID) -> Bool {
        isEnabledFn?(id) ?? false
    }

    static func isAvailable(_ id: CGDirectDisplayID) -> Bool {
        isSupported(id) && !HiDPIMode.isHiDPI(id)
    }

    static func set(_ id: CGDirectDisplayID, enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard isAvailable(id), let set = setFn else { completion(false); return }
        guard isEnabled(id) != enabled else { completion(true); return }
        _ = set(id, enabled, 0, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let ok = isEnabled(id) == enabled
            completion(ok)
            log.notice("HDR \(enabled ? "an" : "aus", privacy: .public) für Bildschirm \(id): \(ok ? "ok" : "abgelehnt", privacy: .public)")
        }
    }
}
