import AppKit
import MetalKit
import ApplicationServices

private let systemDefinedEventType: UInt32 = 14

private func mediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return delegate.handleMediaKeyEvent(type: type, event: event)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var device: MTLDevice!
    private var controllers: [CGDirectDisplayID: DisplayController] = [:]
    private var hud: LiquidGlassHUDWindow!
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var tapHealthTimer: Timer?
    private var watchdogTimer: Timer?
    private var tapRetryTimer: Timer?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal wird nicht unterstützt")
        }
        device = dev
        hud = LiquidGlassHUDWindow()
        hud.onUserChange = { [weak self] kind, fraction in
            guard let self = self else { return nil }
            switch kind {
            case .brightness:
                guard let c = self.hudBrightnessController else { return nil }
                for t in self.targets(for: c) {
                    t.setTarget(Int((fraction * CGFloat(t.maxNits)).rounded()))
                }
                self.syncSliders()
                return self.brightnessState(c)
            case .volume:
                let vol = VolumeController.shared
                guard vol.mode != .unavailable else { return nil }
                if vol.isMuted { vol.setMuted(false) }
                vol.setVolume(Float(fraction))
                return self.volumeState(on: self.hudScreen ?? NSScreen.main ?? NSScreen.screens[0])
            }
        }
        VolumeController.shared.onChange = { [weak self] in
            guard let self = self, self.hud.isShowingVolume else { return }
            self.hud.show(self.volumeState(on: self.hudScreen ?? NSScreen.main ?? NSScreen.screens[0]))
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Helligkeit und Lautstärke")
        ProcessInfo.processInfo.disableAutomaticTermination("EDR Boost")
        ProcessInfo.processInfo.disableSuddenTermination()

        refreshDisplays()
        setupStatusBar()
        startWatchdog()
        setupEventTap()

        startTapHealthCheck()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let wsnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            wsnc.addObserver(self, selector: #selector(systemDidWake(_:)), name: name, object: nil)
        }
        logConflictingApps()
    }

    @objc private func screensChanged() {
        refreshDisplays()
        VolumeController.shared.refresh(rescanDDC: true)
    }

    private var wakeWork: [DispatchWorkItem] = []

    @objc private func systemDidWake(_ note: Notification) {
        log.notice("Aufgewacht (\(note.name.rawValue, privacy: .public)) → Tap und Bildschirme neu aufbauen")
        wakeWork.forEach { $0.cancel() }
        wakeWork = []
        for delay in [1.0, 3.0] {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.recreateEventTap()
                self.refreshDisplays()
                if delay == 1.0 { VolumeController.shared.didWake() } else { VolumeController.shared.refresh(rescanDDC: true) }
                self.controllers.values.forEach { $0.reapply() }
            }
            wakeWork.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func addDisplayModeItems(to menu: NSMenu, for c: DisplayController) {
        let id = c.displayID
        func item(_ title: String, _ action: Selector, on: Bool, enabled: Bool, tip: String) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            i.tag = Int(id)
            i.state = on ? .on : .off
            i.isEnabled = enabled
            i.indentationLevel = 1
            i.toolTip = tip
            menu.addItem(i)
        }
        let hidpiOK = HiDPIMode.isAvailable(id)
        item(hidpiOK ? String(localized: "Hohe Auflösung (HiDPI)") : String(localized: "Hohe Auflösung (HiDPI) – nicht verfügbar"),
             #selector(toggleHiDPI(_:)), on: HiDPIMode.isHiDPI(id), enabled: hidpiOK,
             tip: String(localized: "Schärfere Darstellung bei gleicher Größe. Schaltet HDR ab (Vorgabe von macOS)."))
        if HDRMode.isSupported(id) {
            let hdrOK = HDRMode.isAvailable(id)
            item(hdrOK ? "HDR" : String(localized: "HDR – nicht zusammen mit HiDPI"), #selector(toggleHDR(_:)),
                 on: HDRMode.isEnabled(id), enabled: hdrOK,
                 tip: String(localized: "Nötig für Helligkeit über der SDR-Grenze des Monitors."))
        }
    }

    @objc private func toggleHDR(_ item: NSMenuItem) {
        let id = CGDirectDisplayID(item.tag)
        let wanted = !HDRMode.isEnabled(id)
        HDRMode.set(id, enabled: wanted) { [weak self] ok in
            guard let self = self else { return }
            self.refreshDisplays()
            self.controllers[id]?.reapply()
            if !ok { self.showModeError(wanted ? String(localized: "HDR konnte nicht eingeschaltet werden.") : String(localized: "HDR konnte nicht ausgeschaltet werden.")) }
        }
    }

    private func showModeError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = String(localized: "macOS hat die Änderung für diesen Monitor abgelehnt. Die bisherige Einstellung bleibt erhalten.")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleHiDPI(_ item: NSMenuItem) {
        let id = CGDirectDisplayID(item.tag)
        let wanted = !HiDPIMode.isHiDPI(id)
        let ok = HiDPIMode.set(id, hiDPI: wanted)
        refreshDisplays()
        controllers[id]?.reapply()
        if !ok { showModeError(wanted ? String(localized: "Hohe Auflösung (HiDPI) konnte nicht eingeschaltet werden.") : String(localized: "Hohe Auflösung (HiDPI) konnte nicht ausgeschaltet werden.")) }
    }

    private static let conflictingApps: [String: String] = [
        "pro.betterdisplay.BetterDisplay": "BetterDisplay",
        "me.guillaumeb.MonitorControl": "MonitorControl",
        "fyi.lunar.Lunar": "Lunar",
        "org.herf.Flux": "f.lux",
        "com.rogueamoeba.soundsource": "SoundSource",
        "com.bitgapp.eqmac": "eqMac",
    ]

    private func runningConflicts() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.flatMap { Self.conflictingApps[$0] }
        }.sorted()
    }

    private func logConflictingApps() {
        let c = runningConflicts()
        if !c.isEmpty { log.notice("Laufende Apps, die stören können: \(c.joined(separator: ", "), privacy: .public)") }
    }

    private func refreshDisplays() {
        var newControllers: [CGDirectDisplayID: DisplayController] = [:]
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let edr = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            if let existing = controllers[id], existing.isBuiltIn || abs(existing.potentialEDR - edr) < 0.01 {
                existing.screen = screen
                newControllers[id] = existing
            } else if let existing = controllers[id] {
                existing.shutdown()
                let c = DisplayController(screen: screen, device: device)
                c.setTarget(min(existing.currentNits, c.sdrMaxNits))
                newControllers[id] = c
            } else {
                let c = DisplayController(screen: screen, device: device)
                c.reapply()
                newControllers[id] = c
            }
        }
        for (id, old) in controllers where newControllers[id] == nil {
            old.shutdown()
        }
        controllers = newControllers
    }

    private weak var hudBrightnessController: DisplayController?
    private var hudScreen: NSScreen?

    private func brightnessState(_ c: DisplayController) -> HUDState {
        HUDState(kind: .brightness,
                 fraction: min(1, max(0, CGFloat(c.currentNits) / CGFloat(c.maxNits))),
                 symbolName: "sun.max.fill", boost: c.boostIsActive, muted: false, screen: c.screen)
    }

    private func volumeState(on screen: NSScreen) -> HUDState {
        let vol = VolumeController.shared
        let deviceSymbol = vol.deviceSymbol
        if vol.mode == .unavailable {
            return HUDState(kind: .volume, fraction: 1, symbolName: deviceSymbol ?? "speaker.fill", boost: false,
                            muted: false, screen: screen, disabled: true, hint: vol.unavailableHint)
        }
        let muted = vol.isMuted
        let level = muted ? 0 : CGFloat(vol.volume)
        if muted || level <= 0 {
            return HUDState(kind: .volume, fraction: level, symbolName: "speaker.slash.fill", boost: false,
                            muted: muted, screen: screen)
        }
        if let s = deviceSymbol {
            return HUDState(kind: .volume, fraction: level, symbolName: s, boost: false, muted: false, screen: screen)
        }
        return HUDState(kind: .volume, fraction: level, symbolName: "speaker.wave.3.fill", boost: false,
                        muted: false, screen: screen, symbolValue: Double(level))
    }

    private func targetControllerForMouse() -> DisplayController? {
        let mouseLoc = NSEvent.mouseLocation
        return controllers.values.first { $0.screen.frame.contains(mouseLoc) } ?? controllers.values.first
    }

    private func targets(for controller: DisplayController) -> [DisplayController] {
        globalMode ? Array(controllers.values) : [controller]
    }

    private static let globalModeKey = "globalMode"
    private var globalMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.globalModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.globalModeKey) }
    }

    private var sliders: [CGDirectDisplayID: NSSlider] = [:]
    private static let menuWidth: CGFloat = 280

    private func symbol(_ name: String, size: CGFloat = 13) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        img?.isTemplate = true
        return img
    }

    private func sortedControllers() -> [DisplayController] {
        controllers.values.sorted { a, b in
            a.isBuiltIn != b.isBuiltIn ? a.isBuiltIn : a.displayID < b.displayID
        }
    }

    private func displayTitle(_ c: DisplayController) -> String {
        c.isBuiltIn ? String(localized: "Integriertes Display") : c.name
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "disBrightStatusItem"
        statusItem.isVisible = true
        if let img = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "DisBright") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "✦"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        sliders.removeAll()

        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "DisBright",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        for c in sortedControllers() {
            menu.addItem(.separator())
            let item = NSMenuItem(title: displayTitle(c), action: nil, keyEquivalent: "")
            item.image = symbol(c.isBuiltIn ? "laptopcomputer" : "display")
            item.submenu = infoMenu(for: c)
            menu.addItem(item)

            if !c.isBuiltIn { addDisplayModeItems(to: menu, for: c) }

            let sliderItem = NSMenuItem()
            sliderItem.view = makeSliderView(for: c)
            menu.addItem(sliderItem)
        }

        menu.addItem(.separator())
        let modeLabel = NSMenuItem(title: String(localized: "Helligkeitstasten regeln"), action: nil, keyEquivalent: "")
        modeLabel.isEnabled = false
        menu.addItem(modeLabel)
        let modeItem = NSMenuItem()
        modeItem.view = makeModeView()
        menu.addItem(modeItem)

        let conflicts = runningConflicts()
        if !conflicts.isEmpty {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: String(localized: "Läuft gleichzeitig: \(conflicts.joined(separator: ", "))"), action: nil, keyEquivalent: "")
            warn.image = symbol("exclamationmark.triangle")
            warn.toolTip = String(localized: "Diese Apps steuern ebenfalls Tasten, Helligkeit oder Ton und können sich mit DisBright gegenseitig überschreiben.")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let permItem = NSMenuItem(title: String(localized: "Bedienungshilfen-Zugriff erteilen…"), action: #selector(askForAccessibility), keyEquivalent: "")
            permItem.image = symbol("exclamationmark.triangle")
            permItem.target = self
            menu.addItem(permItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: String(localized: "DisBright beenden"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeSliderView(for c: DisplayController) -> NSView {
        let w = Self.menuWidth
        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 28))

        let lo = NSImageView(frame: NSRect(x: 20, y: 6, width: 16, height: 16))
        lo.image = symbol("sun.min", size: 11)
        lo.contentTintColor = .secondaryLabelColor

        let hi = NSImageView(frame: NSRect(x: w - 36, y: 6, width: 16, height: 16))
        hi.image = symbol("sun.max", size: 13)
        hi.contentTintColor = .secondaryLabelColor

        let slider = NSSlider(value: Double(c.currentNits), minValue: 0, maxValue: Double(c.maxNits),
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 42, y: 4, width: w - 84, height: 20)
        slider.isContinuous = true
        slider.tag = Int(c.displayID)

        [lo, slider, hi].forEach(view.addSubview)
        if c.maxNits > c.sdrMaxNits {
            let inset = ((slider.cell as? NSSliderCell)?.knobThickness ?? 20) / 2
            let frac = CGFloat(c.sdrMaxNits) / CGFloat(c.maxNits)
            let x = slider.frame.minX + inset + frac * (slider.frame.width - 2 * inset)
            let mark = NSView(frame: NSRect(x: (x - 1).rounded(), y: 1, width: 2, height: 5))
            mark.wantsLayer = true
            mark.layer?.backgroundColor = NSColor.systemOrange.cgColor
            mark.layer?.cornerRadius = 1
            mark.toolTip = String(localized: "Ab hier Boost (über \(c.sdrMaxNits) Nits, nur mit HDR)")
            view.addSubview(mark)
        }
        sliders[c.displayID] = slider
        return view
    }

    private func makeModeView() -> NSView {
        let w = Self.menuWidth
        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 32))
        let seg = NSSegmentedControl(labels: [String(localized: "Mauszeiger"), String(localized: "Global")], trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
        seg.setImage(symbol("cursorarrow"), forSegment: 0)
        seg.setImage(symbol("rectangle.on.rectangle"), forSegment: 1)
        seg.segmentDistribution = .fillEqually
        seg.selectedSegment = globalMode ? 1 : 0
        seg.frame = NSRect(x: 20, y: 4, width: w - 40, height: 24)
        view.addSubview(seg)
        return view
    }

    private func infoMenu(for c: DisplayController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        func row(_ label: String, _ value: String) {
            let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let s = NSMutableAttributedString(string: label + "   ",
                                              attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            s.append(NSAttributedString(string: value, attributes: [.foregroundColor: NSColor.labelColor]))
            i.attributedTitle = s
            i.isEnabled = true
            m.addItem(i)
        }

        let id = c.displayID
        row(String(localized: "Typ"), c.isBuiltIn ? String(localized: "Intern") : String(localized: "Extern"))
        if let mode = CGDisplayCopyDisplayMode(id) {
            let px = "\(mode.pixelWidth) × \(mode.pixelHeight)"
            let pt = "\(mode.width) × \(mode.height)"
            row(String(localized: "Auflösung"), px == pt ? px : String(localized: "\(px) (dargestellt als \(pt))"))
        }

        var maxHz = Double(c.screen.maximumFramesPerSecond)
        if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
            maxHz = max(maxHz, modes.map(\.refreshRate).max() ?? 0)
        }
        row(String(localized: "Max. Bildwiederholrate"), maxHz > 0 ? String(localized: "\(Int(maxHz.rounded())) Hz") : String(localized: "Unbekannt"))

        row(String(localized: "Max. Helligkeit (SDR)"), String(localized: "\(c.sdrMaxNits) Nits"))
        let edr = Double(c.screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        if edr > 1.0 {
            row(String(localized: "Max. Helligkeit (HDR)"), String(localized: "\(c.maxNits) Nits"))
            row("HDR", String(localized: "Aktiv"))
        } else {
            row("HDR", HDRMode.isSupported(id) ? String(localized: "Aus") : String(localized: "Nicht unterstützt"))
        }
        row(String(localized: "Farbprofil"), c.screen.colorSpace?.localizedName ?? String(localized: "Unbekannt"))
        return m
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let c = controllers[CGDirectDisplayID(s.tag)] else { return }
        c.setTarget(Int(s.doubleValue.rounded()))
    }

    @objc private func modeChanged(_ seg: NSSegmentedControl) {
        globalMode = seg.selectedSegment == 1
    }

    private func syncSliders() {
        for (id, s) in sliders {
            if let c = controllers[id] { s.doubleValue = Double(c.currentNits) }
        }
    }

    @objc private func askForAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "DisBright braucht Bedienungshilfen-Zugriff")
        alert.informativeText = String(localized: "Damit die Helligkeitstasten funktionieren, bitte DisBright unter Datenschutz & Sicherheit → Bedienungshilfen aktivieren. Die App erkennt die Freigabe automatisch.")
        alert.addButton(withTitle: String(localized: "Einstellungen öffnen"))
        alert.addButton(withTitle: String(localized: "Später"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupEventTap(prompt: Bool = true) {
        if prompt && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << systemDefinedEventType),
            callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if tapRetryTimer == nil {
                tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    guard let self = self, self.eventTap == nil, AXIsProcessTrusted() else { return }
                    self.setupEventTap(prompt: false)
                }
            }
            return
        }

        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("Event-Tap erstellt")
    }

    private func recreateEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
        setupEventTap(prompt: false)
    }

    private func startTapHealthCheck() {
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let tap = self.eventTap else {
                if AXIsProcessTrusted() { self.setupEventTap(prompt: false) }
                return
            }
            if !CFMachPortIsValid(tap) {
                log.error("Event-Tap ungültig → neu erstellen")
                self.recreateEventTap()
            } else if !CGEvent.tapIsEnabled(tap: tap) {
                log.error("Event-Tap deaktiviert → wieder aktivieren")
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) { self.recreateEventTap() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tapHealthTimer = t
    }

    func handleMediaKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("Event-Tap von macOS deaktiviert (\(type.rawValue)) → wieder aktivieren")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let isKeyDown = (data1 & 0x0000FF00) >> 8 == 0x0A
        let isRepeat = (data1 & 0x1) != 0

        let soundUp: Int32 = 0, soundDown: Int32 = 1
        let brightnessUp: Int32 = 2, brightnessDown: Int32 = 3
        let mute: Int32 = 7

        if keyCode == soundUp || keyCode == soundDown || keyCode == mute {
            let vol = VolumeController.shared
            guard isKeyDown else {
                DispatchQueue.main.async { [weak self] in self?.hud.keyReleased() }
                return nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let screen = self.targetControllerForMouse()?.screen else { return }
                self.hudScreen = screen
                if vol.mode == .unavailable {
                    vol.retryIfUnavailable()
                    self.hud.show(self.volumeState(on: screen), suppressLimiter: true)
                    return
                }
                let before = self.volumeState(on: screen)
                if keyCode == mute {
                    vol.toggleMute()
                } else {
                    vol.step(up: keyCode == soundUp, fast: isRepeat)
                }
                let after = self.volumeState(on: screen)
                self.hudScreen = screen
                if keyCode == mute {
                    self.hud.muteClick(muted: after.muted)
                }
                self.hud.show(after, suppressLimiter: keyCode == mute)
                if keyCode != mute, !before.muted, before.fraction == after.fraction,
                   after.fraction <= 0 || after.fraction >= 1 {
                    self.hud.bounce(upward: keyCode == soundUp)
                } else if keyCode != mute, isRepeat {
                    self.hud.nudge(upward: keyCode == soundUp)
                }
            }
            return nil
        }

        guard keyCode == brightnessUp || keyCode == brightnessDown else {
            return Unmanaged.passUnretained(event)
        }
        guard isKeyDown else {
            DispatchQueue.main.async { [weak self] in self?.hud.keyReleased() }
            return nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let mouseTarget = self.targetControllerForMouse() else { return }
            let before = mouseTarget.currentNits
            for t in self.targets(for: mouseTarget) {
                if keyCode == brightnessUp { t.stepIncrease(fast: isRepeat) } else { t.stepDecrease(fast: isRepeat) }
            }
            self.hudBrightnessController = mouseTarget
            self.hudScreen = mouseTarget.screen
            self.hud.show(self.brightnessState(mouseTarget))
            let atLimit = mouseTarget.currentNits == before && (before == 0 || before == mouseTarget.maxNits)
            if atLimit {
                self.hud.bounce(upward: keyCode == brightnessUp)
            } else if isRepeat {
                self.hud.nudge(upward: keyCode == brightnessUp)
            }
            self.syncSliders()
        }
        return nil
    }

    private func startWatchdog() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.controllers.values.forEach { $0.maintain() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdogTimer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdogTimer?.invalidate()
        tapHealthTimer?.invalidate()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        controllers.values.forEach { $0.shutdown() }
        VolumeController.shared.shutdown()
        CGDisplayRestoreColorSyncSettings()
    }
}
