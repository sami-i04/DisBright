import AppKit

enum HiDPIMode {
    struct Mode {
        let number: Int32
        let width: UInt32
        let height: UInt32
        let density: Float
        let refresh: UInt16
    }

    private typealias CountFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
    private typealias DescFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError
    private typealias CurrentFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
    private typealias ConfigureFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func sym<T>(_ name: String) -> T? {
        guard let l = lib, let s = dlsym(l, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }
    private static let countFn: CountFn? = sym("CGSGetNumberOfDisplayModes")
    private static let descFn: DescFn? = sym("CGSGetDisplayModeDescriptionOfLength")
    private static let currentFn: CurrentFn? = sym("CGSGetCurrentDisplayMode")
    private static let configureFn: ConfigureFn? = sym("CGSConfigureDisplayMode")

    private static let descLength = 0xD4

    static func modes(_ id: CGDirectDisplayID) -> [Mode] {
        guard let count = countFn, let desc = descFn else { return [] }
        var n: Int32 = 0
        guard count(id, &n) == .success, n > 0 else { return [] }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: descLength, alignment: 8)
        defer { buf.deallocate() }
        var result: [Mode] = []
        for i in 0..<n {
            buf.initializeMemory(as: UInt8.self, repeating: 0, count: descLength)
            guard desc(id, i, buf, Int32(descLength)) == .success else { continue }
            result.append(Mode(number: Int32(bitPattern: buf.load(fromByteOffset: 0, as: UInt32.self)),
                               width: buf.load(fromByteOffset: 8, as: UInt32.self),
                               height: buf.load(fromByteOffset: 12, as: UInt32.self),
                               density: buf.load(fromByteOffset: 208, as: Float.self),
                               refresh: buf.load(fromByteOffset: 190, as: UInt16.self)))
        }
        return result
    }

    static func current(_ id: CGDirectDisplayID) -> Mode? {
        guard let cur = currentFn else { return nil }
        var number: Int32 = 0
        guard cur(id, &number) == .success else { return nil }
        return modes(id).first { $0.number == number }
    }

    static func isHiDPI(_ id: CGDirectDisplayID) -> Bool {
        (current(id)?.density ?? 1) >= 2
    }

    static func partner(_ id: CGDirectDisplayID, hiDPI: Bool) -> Mode? {
        guard let c = current(id) else { return nil }
        let wanted: Float = hiDPI ? 2 : 1
        return modes(id).first { $0.width == c.width && $0.height == c.height && $0.refresh == c.refresh
            && abs($0.density - wanted) < 0.01 }
    }

    static func isAvailable(_ id: CGDirectDisplayID) -> Bool {
        configureFn != nil && (isHiDPI(id) || partner(id, hiDPI: true) != nil)
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, hiDPI: Bool) -> Bool {
        guard let configure = configureFn, let before = current(id) else { return false }
        if (before.density >= 2) == hiDPI { return true }
        guard let target = partner(id, hiDPI: hiDPI) else {
            log.error("HiDPI: kein passender Modus (\(before.width)×\(before.height) @ \(before.refresh) Hz)")
            return false
        }
        guard apply(configure, id, target.number) else { return false }

        guard let m = CGDisplayCopyDisplayMode(id) else { return false }
        let ok = m.width == Int(before.width) && m.height == Int(before.height)
            && m.pixelWidth == Int(Float(target.width) * target.density)
            && abs(m.refreshRate - Double(before.refresh)) < 1
        let got = "\(m.width)×\(m.height) pt / \(m.pixelWidth)×\(m.pixelHeight) px @ \(m.refreshRate) Hz"
        if !ok {
            log.error("HiDPI: Ergebnis passt nicht (\(got, privacy: .public)) → zurück auf Modus \(before.number)")
            _ = apply(configure, id, before.number)
            return false
        }
        log.notice("HiDPI \(hiDPI ? "an" : "aus", privacy: .public): Modus \(before.number) → \(target.number), \(got, privacy: .public)")
        return true
    }

    private static func apply(_ configure: ConfigureFn, _ id: CGDirectDisplayID, _ number: Int32) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        let e = configure(cfg, id, number)
        guard e == .success else {
            CGCancelDisplayConfiguration(cfg)
            log.error("HiDPI: Modus \(number) abgelehnt (\(e.rawValue))")
            return false
        }
        let c = CGCompleteDisplayConfiguration(cfg, .permanently)
        if c != .success { log.error("HiDPI: Umschalten fehlgeschlagen (\(c.rawValue))") }
        return c == .success
    }
}
