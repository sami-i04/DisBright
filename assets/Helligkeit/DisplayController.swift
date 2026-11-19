import AppKit
import MetalKit

typealias GammaTable = (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])

final class DisplayController {
    var screen: NSScreen
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let sdrMaxNits: Int
    let maxNits: Int
    let potentialEDR: Double

    private(set) var currentNits: Int
    private(set) var shownNits: Double

    private static let animationDuration: CFTimeInterval = 0.2
    private static let gammaTableSize = 256
    private static let dimFloorNits = 10

    private var animationFrom: Double = 0
    private var animationStart: CFTimeInterval = 0
    private var frameTimer: Timer?
    private var lastGainChange: CFTimeInterval = 0
    private var lastNative: Float

    private var originalGamma: GammaTable?
    private var appliedGain: Float = 1
    private var lastAppliedPeak: Float = 1
    private var triggerWindow: NSWindow?
    private let triggerRenderer: EDRTriggerRenderer?
    private let device: MTLDevice

    var boostIsActive: Bool { currentNits > sdrMaxNits }

    init(screen: NSScreen, device: MTLDevice) {
        self.screen = screen
        self.device = device
        self.triggerRenderer = EDRTriggerRenderer(device: device)

        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        self.displayID = id
        self.name = screen.localizedName
        self.isBuiltIn = CGDisplayIsBuiltin(id) != 0

        let potentialEDR = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        self.potentialEDR = potentialEDR
        let sys = SystemNits.read(id, name: screen.localizedName)
        var peak = sys.peak
        var sdr = sys.sdr
        if sdr == nil, let p = peak, potentialEDR > 1.0 {
            sdr = Int(round(Double(p) / potentialEDR))
        }
        let sdrVal = max(80, sdr ?? 250)
        if peak == nil, potentialEDR > 1.0 {
            peak = Int(round(Double(sdrVal) * potentialEDR))
        }
        self.sdrMaxNits = sdrVal
        let edrCap = isBuiltIn ? Int.max
            : (potentialEDR > 1.0 ? Int((Double(sdrVal) * potentialEDR).rounded()) : sdrVal)
        self.maxNits = max(sdrVal, min(peak ?? sdrVal, edrCap))
        log.notice("Bildschirm \(screen.localizedName, privacy: .public): SDR \(sdrVal) Nits, max \(self.maxNits) Nits, EDR-Spielraum \(potentialEDR)")

        let native = BrightnessManager.shared.get(for: id)
        self.lastNative = native
        self.storageKey = "brightness.\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        if !isBuiltIn, let saved = UserDefaults.standard.object(forKey: storageKey) as? Int {
            self.currentNits = max(Self.dimFloorNits, min(sdrVal, saved))
        } else {
            self.currentNits = max(10, min(sdrVal, Int(round(Double(min(1, native)) * Double(sdrVal)))))
        }
        self.shownNits = Double(currentNits)
    }

    private let storageKey: String

    private var boostStep: Int { isBuiltIn ? 50 : 25 }

    func stepIncrease(fast: Bool) {
        let c = currentNits, m = fast ? 2 : 1
        if c >= sdrMaxNits { setTarget(c + boostStep * m) }
        else if c < Self.dimFloorNits { setTarget(min(Self.dimFloorNits, c + 2 * m)) }
        else if c < 25 { setTarget(min(25, c + 5 * m)) }
        else { setTarget(min(sdrMaxNits, c + 25 * m)) }
    }

    func stepDecrease(fast: Bool) {
        let c = currentNits, m = fast ? 2 : 1
        if c > sdrMaxNits { setTarget(max(sdrMaxNits, c - boostStep * m)) }
        else if c > 25 { setTarget(max(Self.dimFloorNits, c - 25 * m)) }
        else if c > Self.dimFloorNits { setTarget(max(Self.dimFloorNits, c - 5 * m)) }
        else { setTarget(c - 2 * m) }
    }

    func setTarget(_ nits: Int) {
        currentNits = max(0, min(maxNits, nits))
        if !isBuiltIn { UserDefaults.standard.set(currentNits, forKey: storageKey) }
        let floor = Double(Self.dimFloorNits)
        if currentNits <= Self.dimFloorNits, shownNits <= floor + 0.001 {
            frameTimer?.invalidate()
            frameTimer = nil
            shownNits = Double(currentNits)
            apply(nits: shownNits)
            return
        }
        animationFrom = shownNits
        animationStart = CACurrentMediaTime()
        if boostIsActive { ensureTriggerWindow() }
        startFrameTimer()
    }

    func maintain() {
        guard frameTimer == nil else { return }
        if isBuiltIn, !boostIsActive, currentNits >= Self.dimFloorNits, lastNative >= 0 {
            let now = BrightnessManager.shared.get(for: displayID)
            if abs(now - lastNative) > 0.02 {
                let nits = max(Self.dimFloorNits, min(sdrMaxNits, Int((Double(now) * Double(sdrMaxNits)).rounded())))
                log.notice("Helligkeit \(self.name, privacy: .public) von außen geändert: \(self.lastNative) → \(now) (DisBright übernimmt \(nits) Nits)")
                lastNative = now
                currentNits = nits
                shownNits = Double(nits)
            }
            return
        }
        if boostIsActive {
            ensureTriggerWindow()
            if let cur = readGamma(), (cur.r + cur.g + cur.b).allSatisfy({ $0 <= 1.001 }) {
                originalGamma = cur
                appliedGain = 1
            }
            apply(nits: shownNits)
        } else if appliedGain < 1 {
            if let cur = readGamma(), let peak = cur.r.max(), abs(peak - lastAppliedPeak) > 0.01 {
                originalGamma = cur
                appliedGain = 1
                apply(nits: shownNits)
            }
        }
    }

    func reapply() {
        frameTimer?.invalidate()
        frameTimer = nil
        removeTriggerWindow()
        if originalGamma != nil { restoreGamma() }
        originalGamma = nil
        appliedGain = 1
        lastAppliedPeak = 1
        lastNative = -1
        shownNits = Double(currentNits)
        apply(nits: shownNits)
    }

    func shutdown() {
        frameTimer?.invalidate()
        frameTimer = nil
        removeTriggerWindow()
        restoreGamma()
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let progress = min(1, (now - animationStart) / Self.animationDuration)
        shownNits = animationFrom + (Double(currentNits) - animationFrom) * progress
        apply(nits: shownNits)

        let headroomSettled = !boostIsActive || now - lastGainChange > 0.6
        if progress >= 1, headroomSettled {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func apply(nits: Double) {
        let sdr = Double(sdrMaxNits)
        if nits <= sdr {
            if !boostIsActive { removeTriggerWindow() }
            let frac = nits / sdr
            let floor = Double(Self.dimFloorNits)
            if isBuiltIn {
                if nits < floor {
                    setNative(Float(floor / sdr))
                    setGamma(Float(max(0, nits / floor)))
                } else {
                    setNative(Float(frac))
                    restoreGamma()
                }
            } else {
                setGamma(Float(pow(max(0, frac), 1.0 / 2.2)))
            }
        } else {
            if isBuiltIn { setNative(1) }
            ensureTriggerWindow()
            let multiplier = nits / sdr
            let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            let boost = headroom > 1.0 ? min(multiplier, headroom) : multiplier
            setGamma(Float(pow(boost, 1.0 / 2.2)))
        }
    }

    private func setNative(_ value: Float) {
        guard abs(value - lastNative) > 0.0005 else { return }
        BrightnessManager.shared.set(for: displayID, value: value)
        lastNative = value
    }

    private func ensureTriggerWindow() {
        guard triggerWindow == nil else { return }

        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let mtk = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        mtk.colorPixelFormat = .rgba16Float
        mtk.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        mtk.layer?.isOpaque = false
        mtk.preferredFramesPerSecond = 10
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        (mtk.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        mtk.delegate = triggerRenderer

        win.contentView = mtk
        win.orderFrontRegardless()
        triggerWindow = win
    }

    private func removeTriggerWindow() {
        triggerWindow?.orderOut(nil)
        triggerWindow = nil
    }

    private func readGamma() -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &count) == .success, count > 0 else {
            return nil
        }
        let n = Int(count)
        return (Array(r.prefix(n)), Array(g.prefix(n)), Array(b.prefix(n)))
    }

    private func scaled(_ channel: [CGGammaValue], by factor: Float) -> [CGGammaValue] {
        let n = Self.gammaTableSize
        let last = channel.count - 1
        return (0..<n).map { i in
            let pos = Float(i) / Float(n - 1) * Float(last)
            let lo = Int(pos), hi = min(lo + 1, last), f = pos - Float(lo)
            return (channel[lo] * (1.0 - f) + channel[hi] * f) * factor
        }
    }

    private func setGamma(_ gain: Float) {
        if abs(gain - 1) < 0.0005 {
            restoreGamma()
            return
        }
        guard abs(gain - appliedGain) > 0.0005 else { return }
        if originalGamma == nil { originalGamma = readGamma() }
        guard let orig = originalGamma else { return }
        var r = scaled(orig.r, by: gain)
        var g = scaled(orig.g, by: gain)
        var b = scaled(orig.b, by: gain)
        if CGSetDisplayTransferByTable(displayID, UInt32(r.count), &r, &g, &b) == .success {
            appliedGain = gain
            lastAppliedPeak = r.max() ?? 0
            lastGainChange = CACurrentMediaTime()
        }
    }

    private func restoreGamma() {
        guard var orig = originalGamma else { return }
        _ = CGSetDisplayTransferByTable(displayID, UInt32(orig.r.count), &orig.r, &orig.g, &orig.b)
        originalGamma = nil
        appliedGain = 1
    }
}
