import Foundation
import CoreAudio
import AudioToolbox
import QuartzCore

final class VolumeController {
    static let shared = VolumeController()
    private static let steps: Float = 16
    private static let ddcRetryInterval: CFTimeInterval = 10

    enum Mode { case software, ddc, gain, unavailable }
    private static let defaultHint = String(localized: "Lautstärke am Gerät regeln")

    var onChange: (() -> Void)?

    private enum Backend {
        case main
        case channels([AudioObjectPropertyElement])
        case ddc(DDCVolumeTarget)
        case gain(SoftwareVolumeEngine)
        case none
    }

    private(set) var device: AudioDeviceID?
    private(set) var deviceName = ""
    private var backend: Backend = .none
    private var muteElement: AudioObjectPropertyElement?
    private var emulatedMuteVolume: Float?

    private(set) var unavailableHint = VolumeController.defaultHint
    private var softEngine: SoftwareVolumeEngine?
    private var softFailedUIDs: Set<String> = []
    private var softFailures: [String: [CFTimeInterval]] = [:]
    private static let maxFailuresPerMinute = 3
    private var replacedEngine: SoftwareVolumeEngine?
    private var permissionTimer: Timer?
    private var lastReported = ""

    private var ddcCache: [String: DDCVolumeTarget] = [:]
    private var ddcLastFail: [String: CFTimeInterval] = [:]
    private var ddcProbing: Set<String> = []
    private let probeQueue = DispatchQueue(label: "local.disbright.ddcprobe")

    private init() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) {
            [weak self] _, _ in self?.refresh()
        }
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main) {
            [weak self] _, _ in self?.refresh()
        }
        refresh()
    }

    var mode: Mode {
        switch backend {
        case .main, .channels: return .software
        case .ddc: return .ddc
        case .gain: return .gain
        case .none: return .unavailable
        }
    }

    func refresh(rescanDDC: Bool = false) {
        if rescanDDC {
            ddcCache.removeAll()
            ddcLastFail.removeAll()
            softFailedUIDs.removeAll()
            softFailures.removeAll()
        }
        let newDevice = Self.defaultOutputDevice()
        if newDevice != device { emulatedMuteVolume = nil }
        device = newDevice
        backend = .none
        muteElement = nil
        unavailableHint = Self.defaultHint
        let uid = newDevice.flatMap { Self.string($0, kAudioDevicePropertyDeviceUID) }
        if let e = softEngine {
            if e.outputUID != uid {
                e.stop()
                softEngine = nil
            } else if e.outputDevice != newDevice {
                replacedEngine = e
                softEngine = nil
            }
        }
        guard let d = newDevice else { finishReplacement(); reportIfChanged(); return }
        deviceName = Self.string(d, kAudioObjectPropertyName) ?? "?"

        let main = kAudioObjectPropertyElementMain
        muteElement = [main, 1, 2].first { Self.isSettable(d, kAudioDevicePropertyMute, $0) }
        if Self.isSettable(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, main) {
            backend = .main
        } else if Self.isSettable(d, kAudioDevicePropertyVolumeScalar, main) {
            backend = .channels([main])
        } else {
            let ch: [AudioObjectPropertyElement] = [1, 2].filter { Self.isSettable(d, kAudioDevicePropertyVolumeScalar, $0) }
            if !ch.isEmpty { backend = .channels(ch) }
        }
        if case .none = backend {
            if let e = softEngine {
                backend = .gain(e)
            } else {
                if Self.isDisplayAudio(d) && replacedEngine == nil { resolveDDC(for: d) }
                if case .none = backend, let uid = uid, !ddcProbing.contains(uid) {
                    startSoftwareVolume(uid: uid)
                }
            }
        } else if let e = softEngine {
            e.stop()
            softEngine = nil
        }
        finishReplacement()
        reportIfChanged()
    }

    private func finishReplacement() {
        guard let old = replacedEngine else { return }
        replacedEngine = nil
        old.stop()
        if let e = softEngine { e.muted = UserDefaults.standard.bool(forKey: Self.muteKey(e.outputUID)) }
    }

    private func reportIfChanged() {
        let now = "\(device ?? 0)|\(mode)|\(unavailableHint)"
        guard now != lastReported else { return }
        lastReported = now
        log.notice("Ausgabegerät: \(self.deviceName, privacy: .public) → \(String(describing: self.mode), privacy: .public)")
        onChange?()
    }

    func retryIfUnavailable() {
        if mode == .unavailable { refresh() }
    }

    private func resolveDDC(for d: AudioDeviceID) {
        let key = Self.string(d, kAudioDevicePropertyDeviceUID) ?? "\(d)"
        if let t = ddcCache[key] { backend = .ddc(t); return }
        if let failed = ddcLastFail[key], CACurrentMediaTime() - failed < Self.ddcRetryInterval { return }
        guard !ddcProbing.contains(key) else { return }
        ddcProbing.insert(key)
        let audioName = deviceName
        probeQueue.async { [weak self] in
            let target = Self.probeDDC(audioName: audioName)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.ddcProbing.remove(key)
                if let t = target {
                    self.ddcCache[key] = t
                    log.notice("DDC-Lautstärke verfügbar: \(t.display.name, privacy: .public) (max \(t.maxVolume))")
                } else {
                    self.ddcLastFail[key] = CACurrentMediaTime()
                    log.notice("Keine DDC-Lautstärke für \(audioName, privacy: .public)")
                }
                guard self.device == d, case .none = self.backend else { return }
                if let t = target {
                    self.backend = .ddc(t)
                } else {
                    self.startSoftwareVolume(uid: key)
                }
                self.reportIfChanged()
            }
        }
    }

    private func startSoftwareVolume(uid: String) {
        guard let d = device else { return }
        guard !softFailedUIDs.contains(uid) else {
            if AudioCapturePermission.status == .denied { unavailableHint = String(localized: "Audioaufnahme erlauben") }
            return
        }
        switch AudioCapturePermission.status {
        case .denied:
            unavailableHint = String(localized: "Audioaufnahme erlauben")
            log.notice("Software-Lautstärke: Erlaubnis „Audioaufnahme“ verweigert")
            return
        case .unknown, .granted:
            break
        }
        let saved = UserDefaults.standard.object(forKey: Self.volumeKey(uid)) as? Float ?? 1
        let savedMute = UserDefaults.standard.bool(forKey: Self.muteKey(uid))
        guard let e = SoftwareVolumeEngine(outputDevice: d, outputUID: uid, volume: saved) else {
            softFailedUIDs.insert(uid)
            return
        }
        e.muted = replacedEngine != nil ? true : savedMute
        e.onFailure = { [weak self] in self?.softwareVolumeFailed(uid: uid) }
        softEngine = e
        backend = .gain(e)
        if AudioCapturePermission.status != .granted { watchPermission(uid: uid) }
    }

    private func watchPermission(uid: String) {
        permissionTimer?.invalidate()
        let started = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, let e = self.softEngine, e.outputUID == uid else { timer.invalidate(); return }
            let status = AudioCapturePermission.status
            if status == .granted {
                log.notice("Erlaubnis „Audioaufnahme“ erteilt")
                timer.invalidate()
            } else if status == .denied || CACurrentMediaTime() - started > 60 {
                log.notice("Erlaubnis „Audioaufnahme“ fehlt → Software-Lautstärke beendet")
                timer.invalidate()
                e.stop()
                self.softEngine = nil
                self.softFailedUIDs.insert(uid)
                self.refresh()
                self.unavailableHint = String(localized: "Audioaufnahme erlauben")
                self.reportIfChanged()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    private func softwareVolumeFailed(uid: String) {
        softEngine = nil
        let now = CACurrentMediaTime()
        var times = (softFailures[uid] ?? []).filter { now - $0 < 60 }
        times.append(now)
        softFailures[uid] = times
        if times.count > Self.maxFailuresPerMinute {
            log.error("Software-Lautstärke für \(uid, privacy: .public) zu oft gescheitert → aus bis Bildschirm-/Gerätewechsel")
            softFailedUIDs.insert(uid)
            refresh()
            return
        }
        backend = .none
        reportIfChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func didWake() {
        refresh(rescanDDC: true)
    }

    private static func volumeKey(_ uid: String) -> String { "softVolume.\(uid)" }
    private static func muteKey(_ uid: String) -> String { "softMute.\(uid)" }

    func shutdown() {
        replacedEngine?.stop()
        replacedEngine = nil
        softEngine?.stop()
        softEngine = nil
    }

    private static func probeDDC(audioName: String) -> DDCVolumeTarget? {
        let displays = DDCDisplay.all()
        let n = audioName.lowercased()
        let matching = displays.filter {
            let dn = $0.name.lowercased()
            return !dn.isEmpty && (n.contains(dn) || dn.contains(n))
        }
        let candidates = matching.isEmpty && displays.count == 1 ? displays : matching
        for disp in candidates {
            guard let vol = disp.read(DDCDisplay.vcpVolume), vol.max > 0 else { continue }
            let mute = disp.read(DDCDisplay.vcpMute)
            return DDCVolumeTarget(display: disp, maxVolume: vol.max,
                                   volume: min(1, Float(vol.cur) / Float(vol.max)),
                                   hasMute: mute != nil, muted: mute?.cur == 1)
        }
        return nil
    }

    var volume: Float {
        guard let d = device else { return 0 }
        switch backend {
        case .main:
            return Self.getFloat(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain) ?? 0
        case .channels(let ch):
            let values = ch.compactMap { Self.getFloat(d, kAudioDevicePropertyVolumeScalar, $0) }
            return values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        case .ddc(let t):
            return t.volume
        case .gain(let e):
            return e.volume
        case .none:
            return 0
        }
    }

    var isMuted: Bool {
        if emulatedMuteVolume != nil { return true }
        switch backend {
        case .ddc(let t) where t.hasMute:
            return t.muted
        case .gain(let e):
            return e.muted
        case .main, .channels:
            guard let d = device, let el = muteElement else { return false }
            return (Self.getUInt32(d, kAudioDevicePropertyMute, el) ?? 0) != 0
        default:
            return false
        }
    }

    func setVolume(_ value: Float) {
        guard let d = device else { return }
        let v = min(1, max(0, value))
        switch backend {
        case .main:
            Self.setFloat(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain, v)
        case .channels(let ch):
            ch.forEach { Self.setFloat(d, kAudioDevicePropertyVolumeScalar, $0, v) }
        case .ddc(let t):
            t.volume = v
            t.send(DDCDisplay.vcpVolume, Int((v * Float(t.maxVolume)).rounded()))
        case .gain(let e):
            e.volume = v
            UserDefaults.standard.set(v, forKey: Self.volumeKey(e.outputUID))
        case .none:
            break
        }
    }

    func setMuted(_ muted: Bool) {
        guard mode != .unavailable else { return }
        switch backend {
        case .ddc(let t) where t.hasMute:
            t.muted = muted
            t.send(DDCDisplay.vcpMute, muted ? 1 : 2)
            return
        case .gain(let e):
            e.muted = muted
            UserDefaults.standard.set(muted, forKey: Self.muteKey(e.outputUID))
            return
        case .main, .channels:
            if let d = device, let el = muteElement {
                Self.setUInt32(d, kAudioDevicePropertyMute, el, muted ? 1 : 0)
                return
            }
        default:
            break
        }
        if muted {
            guard emulatedMuteVolume == nil else { return }
            let v = volume
            setVolume(0)
            emulatedMuteVolume = v
        } else if let v = emulatedMuteVolume {
            emulatedMuteVolume = nil
            setVolume(v)
        }
    }

    func step(up: Bool, fast: Bool) {
        if isMuted { setMuted(false) }
        let m: Float = fast ? 2 : 1
        let current = (volume * Self.steps).rounded()
        setVolume((current + (up ? m : -m)) / Self.steps)
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    private static func address(_ sel: AudioObjectPropertySelector, _ el: AudioObjectPropertyElement,
                                _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyElementMain,
                           kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func isSettable(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector,
                                   _ el: AudioObjectPropertyElement) -> Bool {
        var addr = address(sel, el)
        guard AudioObjectHasProperty(d, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(d, &addr, &settable) == noErr && settable.boolValue
    }

    var deviceSymbol: String? {
        guard let d = device else { return nil }
        let n = deviceName.lowercased()
        switch Self.transportType(d) {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return n.contains("4") ? "airpods.gen4" : (n.contains("3") ? "airpods.gen3" : "airpods") }
            if n.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeUSB:
            return n.contains("headset") || n.contains("headphone") || n.contains("kopfh") ? "headphones" : "hifispeaker.fill"
        case kAudioDeviceTransportTypeBuiltIn:
            var addr = Self.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyElementMain)
            var src: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let ok = AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &src) == noErr
            return ok && src == 0x6864_706E ? "headphones" : nil
        default:
            return nil
        }
    }

    private static func transportType(_ d: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType, kAudioObjectPropertyElementMain, kAudioObjectPropertyScopeGlobal)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &t) == noErr ? t : 0
    }

    private static func isDisplayAudio(_ d: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyTransportType, kAudioObjectPropertyElementMain, kAudioObjectPropertyScopeGlobal)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
    }

    private static func string(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel, kAudioObjectPropertyElementMain, kAudioObjectPropertyScopeGlobal)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &s) == noErr, let v = s?.takeRetainedValue()
        else { return nil }
        return v as String
    }

    private static func getFloat(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector,
                                 _ el: AudioObjectPropertyElement) -> Float? {
        var addr = address(sel, el)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func setFloat(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector,
                                 _ el: AudioObjectPropertyElement, _ value: Float) {
        var addr = address(sel, el)
        var v = Float32(value)
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static func getUInt32(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector,
                                  _ el: AudioObjectPropertyElement) -> UInt32? {
        var addr = address(sel, el)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func setUInt32(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector,
                                  _ el: AudioObjectPropertyElement, _ value: UInt32) {
        var addr = address(sel, el)
        var v = value
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}
