import Foundation
import CoreAudio
import AudioToolbox

final class SoftwareVolumeEngine {
    private struct Shared {
        var targetGain: Float = 1
        var currentGain: Float = 1
        var heartbeat: UInt64 = 0
    }

    private static let bufferSizes: [UInt32] = [64, 128, 256, 512]

    let outputUID: String
    let outputDevice: AudioDeviceID
    private var deviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var startRate: Float64 = 0
    private let shared = UnsafeMutablePointer<Shared>.allocate(capacity: 1)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var bufferIndex = 0
    private var overloadListener: AudioObjectPropertyListenerBlock?
    private var watchdog: Timer?
    private var lastHeartbeat: UInt64 = 0
    private var stalledChecks = 0
    private var stopped = false
    private var hasRun = false
    private var loggedRun = false

    var onFailure: (() -> Void)?

    var volume: Float { didSet { updateGain() } }
    var muted = false { didSet { updateGain() } }

    init?(outputDevice: AudioDeviceID, outputUID: String, volume: Float) {
        self.outputDevice = outputDevice
        self.outputUID = outputUID
        self.volume = volume
        shared.initialize(to: Shared())
        guard #available(macOS 14.2, *), start() else {
            teardown()
            return nil
        }
        updateGain()
        shared.pointee.currentGain = shared.pointee.targetGain
        startWatchdog()
        log.notice("Software-Lautstärke aktiv für \(outputUID, privacy: .public) (Puffer \(Self.bufferSizes[self.bufferIndex]) Samples)")
    }

    deinit {
        stop()
        shared.deallocate()
    }

    static let loudnessExponent: Float = 1 / 0.6
    static func gain(for volume: Float) -> Float {
        let v = min(1, max(0, volume))
        return v <= 0 ? 0 : powf(v, loudnessExponent)
    }

    private func updateGain() {
        shared.pointee.targetGain = muted ? 0 : Self.gain(for: volume)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        watchdog?.invalidate()
        watchdog = nil
        teardown()
        log.notice("Software-Lautstärke beendet für \(self.outputUID, privacy: .public)")
    }

    @available(macOS 14.2, *)
    private func start() -> Bool {
        guard let ownProcess = Self.ownProcessObject() else {
            log.error("Software-Lautstärke: eigenes Prozessobjekt nicht gefunden → nicht gestartet")
            return false
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        desc.name = "DisBright Lautstärke"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        desc.deviceUID = outputUID
        desc.stream = 0

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            log.error("Process-Tap fehlgeschlagen (\(err))")
            return false
        }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DisBright Lautstärke",
            kAudioAggregateDeviceUIDKey: "local.disbright.softvolume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr, agg != kAudioObjectUnknown else {
            log.error("Aggregate-Device fehlgeschlagen (\(err))")
            return false
        }
        aggregateID = agg

        setBufferSize(Self.bufferSizes[bufferIndex])
        listenForOverload()
        startRate = Self.sampleRate(outputDevice)
        listenToOutputDevice()

        let state = shared
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, output, _ in
            Self.process(input: input, output: output, state: state)
        }
        guard err == noErr, let p = proc else {
            log.error("IOProc fehlgeschlagen (\(err))")
            return false
        }
        procID = p

        err = AudioDeviceStart(agg, p)
        guard err == noErr else {
            log.error("Start fehlgeschlagen (\(err))")
            return false
        }
        return true
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            if let l = overloadListener {
                var addr = Self.address(kAudioDeviceProcessorOverload)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, DispatchQueue.main, l)
            }
            for (sel, l) in deviceListeners {
                var addr = Self.address(sel)
                AudioObjectRemovePropertyListenerBlock(outputDevice, &addr, DispatchQueue.main, l)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        overloadListener = nil
        deviceListeners = []
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func process(input: UnsafePointer<AudioBufferList>,
                                output: UnsafeMutablePointer<AudioBufferList>,
                                state: UnsafeMutablePointer<Shared>) {
        state.pointee.heartbeat &+= 1
        let target = state.pointee.targetGain
        let start = state.pointee.currentGain
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var totalIn = 0
        for b in inList { totalIn += Int(b.mNumberChannels) }

        var outChannel = 0
        for ob in outList {
            let onc = Int(ob.mNumberChannels)
            guard onc > 0, let od = ob.mData?.assumingMemoryBound(to: Float.self) else {
                outChannel += onc
                continue
            }
            let frames = Int(ob.mDataByteSize) / MemoryLayout<Float>.size / onc
            let step = frames > 0 ? (target - start) / Float(frames) : 0

            for c in 0..<onc {
                var wanted = outChannel + c
                if totalIn == 1 && wanted < 2 { wanted = 0 }
                var src: UnsafeMutablePointer<Float>?
                var srcStride = 0
                var srcFrames = 0
                var base = 0
                for ib in inList {
                    let inc = Int(ib.mNumberChannels)
                    if wanted >= base && wanted < base + inc, inc > 0,
                       let d = ib.mData?.assumingMemoryBound(to: Float.self) {
                        src = d + (wanted - base)
                        srcStride = inc
                        srcFrames = Int(ib.mDataByteSize) / MemoryLayout<Float>.size / inc
                        break
                    }
                    base += inc
                }

                var g = start
                if let s = src {
                    let n = min(frames, srcFrames)
                    for f in 0..<frames {
                        g += step
                        od[f * onc + c] = f < n ? s[f * srcStride] * g : 0
                    }
                } else {
                    for f in 0..<frames { od[f * onc + c] = 0 }
                }
            }
            outChannel += onc
        }
        state.pointee.currentGain = target
    }

    private func setBufferSize(_ frames: UInt32) {
        var addr = Self.address(kAudioDevicePropertyBufferFrameSize)
        var v = frames
        let err = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        if err != noErr { log.error("Puffergröße \(frames) nicht setzbar (\(err))") }
    }

    private func listenForOverload() {
        var addr = Self.address(kAudioDeviceProcessorOverload)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, !self.stopped, self.bufferIndex + 1 < Self.bufferSizes.count else { return }
            self.bufferIndex += 1
            let size = Self.bufferSizes[self.bufferIndex]
            log.notice("Audio-Überlastung → Puffer auf \(size) Samples")
            self.setBufferSize(size)
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &addr, DispatchQueue.main, block) == noErr {
            overloadListener = block
        }
    }

    private func startWatchdog() {
        lastHeartbeat = shared.pointee.heartbeat
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.stopped else { return }
            let hb = self.shared.pointee.heartbeat
            if hb == self.lastHeartbeat {
                guard self.outputIsPlaying() else {
                    self.stalledChecks = 0
                    self.hasRun = false
                    return
                }
                self.stalledChecks += 1
                let limit = self.hasRun ? 3 : 10
                if self.stalledChecks >= limit {
                    self.logDiagnostics()
                    log.error("Software-Lautstärke hängt → beendet, Originalton wieder frei")
                    self.stop()
                    self.onFailure?()
                }
            } else {
                self.hasRun = true
                if !self.loggedRun {
                    self.loggedRun = true
                    log.notice("Software-Lautstärke: Verarbeitung läuft (\(hb) Blöcke)")
                }
                self.stalledChecks = 0
            }
            self.lastHeartbeat = hb
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func listenToOutputDevice() {
        for sel in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            var addr = Self.address(sel)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self = self, !self.stopped else { return }
                let alive = Self.uint32(self.outputDevice, kAudioDevicePropertyDeviceIsAlive) ?? 0
                let rate = Self.sampleRate(self.outputDevice)
                guard alive == 0 || rate != self.startRate else { return }
                log.notice("Ausgabegerät \(alive == 0 ? "verschwunden" : "neue Abtastrate \(rate)", privacy: .public) → Software-Lautstärke neu aufbauen")
                self.stop()
                self.onFailure?()
            }
            if AudioObjectAddPropertyListenerBlock(outputDevice, &addr, DispatchQueue.main, block) == noErr {
                deviceListeners.append((sel, block))
            }
        }
    }

    private static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = address(sel)
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }

    private static func sampleRate(_ obj: AudioObjectID) -> Float64 {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var v: Float64 = 0
        var sz = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : 0
    }

    private func outputIsPlaying() -> Bool {
        var a = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(outputDevice, &a, 0, nil, &sz, &v) == noErr && v != 0
    }

    private func logDiagnostics() {
        func uint(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
            var a = Self.address(sel); var v: UInt32 = 0; var sz = UInt32(4)
            return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : 9999
        }
        func streams(_ scope: AudioObjectPropertyScope) -> String {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                               mElement: kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(aggregateID, &a, 0, nil, &sz) == noErr, sz > 0 else { return "-" }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(aggregateID, &a, 0, nil, &sz, raw) == noErr else { return "?" }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        }
        var rate: Float64 = 0
        var a = Self.address(kAudioDevicePropertyNominalSampleRate)
        var sz = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(aggregateID, &a, 0, nil, &sz, &rate)
        log.notice("""
            Software-Lautstärke Diagnose: läuft=\(uint(self.aggregateID, kAudioDevicePropertyDeviceIsRunning)) \
            Rate=\(rate) Puffer=\(uint(self.aggregateID, kAudioDevicePropertyBufferFrameSize)) \
            Eingang=\(streams(kAudioObjectPropertyScopeInput), privacy: .public) \
            Ausgang=\(streams(kAudioObjectPropertyScopeOutput), privacy: .public) \
            Blöcke=\(self.shared.pointee.heartbeat) Erlaubnis=\(String(describing: AudioCapturePermission.status), privacy: .public)
            """)
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}

enum AudioCapturePermission {
    enum Status { case granted, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let lib = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)

    static var status: Status {
        guard let l = lib, let s = dlsym(l, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(s, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }
}
