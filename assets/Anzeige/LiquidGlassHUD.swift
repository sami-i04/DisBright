import AppKit

enum HUDKind { case brightness, volume }

struct HUDState {
    let kind: HUDKind
    let fraction: CGFloat
    let symbolName: String
    let boost: Bool
    let muted: Bool
    let screen: NSScreen
    var disabled = false
    var hint: String? = nil
    var symbolValue: Double? = nil
}

final class HUDPillView: NSView {
    var onDragBegin: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDragBegin?(event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

final class LiquidGlassHUDWindow: NSPanel {
    private static let pillWidth: CGFloat = 50
    private static let pillHeight: CGFloat = 190
    private static let edgeInset: CGFloat = 14
    private static let pad: CGFloat = 36
    private static let maxStretch: CGFloat = 30
    private static let keyStretch: CGFloat = 16
    private static let nudgeAmount: CGFloat = 5
    private static let boostColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.15, alpha: 1.0)
    private static let fillColor = NSColor.white.withAlphaComponent(0.95)
    private static let glassOpacity: CGFloat = 0.45
    private static let verticalPosition: CGFloat = 0.5
    private static let visibleDuration: TimeInterval = 2.0
    private static let limiterDuration: CFTimeInterval = 0.5
    private static let limiterInterval: TimeInterval = 0.12

    private static let muteSequence: [Int32] = [6, 1]
    private static let muteSequenceGap: TimeInterval = 0.2

    var onUserChange: ((HUDKind, CGFloat) -> HUDState?)?

    private let pillView: HUDPillView
    private let fillView = NSView()
    private let iconImageView = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")
    private var fadeTimer: Timer?
    private var isPresented = false
    private var currentScreenFrame: NSRect = .zero
    private var presentStart: CFTimeInterval = 0
    private var state: HUDState?
    private var currentSymbolName = ""
    private var lastFraction: CGFloat = 0

    private var isDragging = false
    private var dragStartY: CGFloat = 0
    private var dragStartFraction: CGFloat = 0
    private var dragOvershooting = false
    private var lastDragY: CGFloat = 0
    private var lastDragTime: CFTimeInterval = 0
    private var dragVelocity: CGFloat = 0

    private var motionTimer: Timer?
    private var motionLink: AnyObject?
    private var currentSymbolValue: Double?
    private var lastMotionTick: CFTimeInterval = 0

    private var displayFraction: CGFloat = 0
    private var displayFractionVelocity: CGFloat = 0

    private var stretch: CGFloat = 0
    private var stretchTarget: CGFloat = 0
    private var keyHoldDirection: Int = 0
    private var keyHoldSafety: DispatchWorkItem?

    private var nudge: CGFloat = 0
    private var nudgeVelocity: CGFloat = 0
    private var keyNudge: CGFloat = 0

    private var limiterArmed = true
    private var limiterTimer: Timer?
    private var limiterStart: CFTimeInterval = 0

    private var shownPillFrame: NSRect {
        NSRect(x: Self.edgeInset, y: Self.pad, width: Self.pillWidth, height: Self.pillHeight)
    }
    private var hiddenPillFrame: NSRect {
        shownPillFrame.offsetBy(dx: -(Self.edgeInset + Self.pillWidth + 8), dy: 0)
    }

    init() {
        let winSize = NSSize(width: Self.edgeInset + Self.pillWidth + Self.pad,
                             height: Self.pillHeight + Self.pad * 2)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.pillHeight))
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.pillWidth / 2
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]

        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = Self.fillColor.cgColor
        fillView.frame = NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.pillHeight)
        fillView.layer?.transform = CATransform3DMakeScale(1, 0, 1)
        content.addSubview(fillView)

        let iconSize: CGFloat = 22
        iconImageView.frame = NSRect(x: (Self.pillWidth - iconSize) / 2, y: 14, width: iconSize, height: iconSize)
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = .white
        iconImageView.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        content.addSubview(iconImageView)

        hintLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        let hintLength = Self.pillHeight - 50
        hintLabel.frame = NSRect(x: (Self.pillWidth - hintLength) / 2, y: 40 + hintLength / 2 - 7,
                                 width: hintLength, height: 14)
        hintLabel.frameCenterRotation = 90
        hintLabel.isHidden = true
        content.addSubview(hintLabel)

        let container = HUDPillView(frame: content.frame)
        container.wantsLayer = true
        let glassView: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .clear
            glass.cornerRadius = Self.pillWidth / 2
            glassView = glass
        } else {
            let blur = NSVisualEffectView(frame: content.frame)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.pillWidth / 2
            blur.layer?.masksToBounds = true
            glassView = blur
        }
        glassView.autoresizingMask = [.width, .height]
        glassView.alphaValue = Self.glassOpacity
        container.addSubview(glassView)
        container.addSubview(content)
        pillView = container

        super.init(contentRect: NSRect(origin: .zero, size: winSize),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hideImmediately() }

        let root = NSView(frame: NSRect(origin: .zero, size: winSize))
        pillView.frame = hiddenPillFrame
        pillView.alphaValue = 0
        root.addSubview(pillView)
        contentView = root

        pillView.onDragBegin = { [weak self] p in self?.dragBegin(p) }
        pillView.onDrag = { [weak self] p in self?.dragMoved(p) }
        pillView.onDragEnd = { [weak self] in self?.dragEnded() }
    }

    private func dragBegin(_ p: NSPoint) {
        guard let st = state, !st.disabled else { return }
        isDragging = true
        fadeTimer?.invalidate()
        dragStartY = p.y
        dragStartFraction = st.fraction
        dragOvershooting = false
        lastDragY = p.y
        lastDragTime = CACurrentMediaTime()
        dragVelocity = 0
        startMotion()
    }

    private func dragMoved(_ p: NSPoint) {
        guard isDragging, let st = state else { return }
        let h = Self.pillHeight
        let rel = dragStartFraction + (p.y - dragStartY) / h
        guard let newState = onUserChange?(st.kind, min(1, max(0, rel))) else { return }
        state = newState

        let over: CGFloat = rel > 1 ? (rel - 1) * h : (rel < 0 ? rel * h : 0)
        dragOvershooting = over != 0
        stretchTarget = 0
        stretch = over == 0 ? 0 : (over > 0 ? 1 : -1) * Self.rubberBand(abs(over))

        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, now - lastDragTime)
        let instant = (p.y - lastDragY) / CGFloat(dt)
        dragVelocity += (instant - dragVelocity) * 0.35
        lastDragY = p.y
        lastDragTime = now

        updateFill(for: newState, animated: false)
    }

    private func dragEnded() {
        guard isDragging else { return }
        isDragging = false
        dragOvershooting = false
        dragVelocity = 0
        limiterArmed = true
        startMotion()
        applyKeyDeform()
        scheduleHide()
    }

    func bounce(upward: Bool) {
        let dir = upward ? 1 : -1
        scheduleKeyHoldSafety()
        guard keyHoldDirection != dir else { return }
        keyHoldDirection = dir
        keyNudge = 0
        stretchTarget = CGFloat(dir) * Self.keyStretch
        applyKeyDeformAfterSlideIn()
        triggerLimiter()
        resumeLimiter()
    }

    func nudge(upward: Bool) {
        scheduleKeyHoldSafety()
        guard keyHoldDirection == 0 else { return }
        keyNudge = upward ? Self.nudgeAmount : -Self.nudgeAmount
        applyKeyDeformAfterSlideIn()
    }

    func keyReleased() {
        keyHoldSafety?.cancel()
        keyHoldSafety = nil
        limiterArmed = true
        keyNudge = 0
        keyHoldDirection = 0
        stretchTarget = 0
        applyKeyDeform()
    }

    private func scheduleKeyHoldSafety() {
        keyHoldSafety?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.keyReleased() }
        keyHoldSafety = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }

    private var isPushingLimit: Bool { keyHoldDirection != 0 || (isDragging && dragOvershooting) }

    private func triggerLimiter() {
        guard limiterArmed else { return }
        limiterArmed = false
        limiterTimer?.invalidate()
        limiterStart = CACurrentMediaTime()
        Self.haptic()
        startLimiterTimer()
    }

    private func resumeLimiter() {
        guard limiterTimer == nil, CACurrentMediaTime() - limiterStart < Self.limiterDuration else { return }
        startLimiterTimer()
    }

    private func startLimiterTimer() {
        let t = Timer(timeInterval: Self.limiterInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if CACurrentMediaTime() - self.limiterStart >= Self.limiterDuration || !self.isPushingLimit {
                timer.invalidate()
                self.limiterTimer = nil
                return
            }
            Self.haptic()
        }
        RunLoop.main.add(t, forMode: .common)
        limiterTimer = t
    }

    private static func haptic(strength: Int32 = TrackpadHaptics.defaultStrength) {
        if !TrackpadHaptics.shared.click(strength: strength) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    func muteClick(muted: Bool) {
        let sequence = muted ? Self.muteSequence : Self.muteSequence.reversed()
        for (i, strength) in sequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.muteSequenceGap * Double(i)) {
                Self.haptic(strength: strength)
            }
        }
    }

    private static func rubberBand(_ d: CGFloat) -> CGFloat {
        maxStretch * (1 - 1 / (d * 0.55 / maxStretch + 1))
    }

    private static func spring(_ x: inout CGFloat, _ v: inout CGFloat, to target: CGFloat,
                               stiffness k: CGFloat, damping c: CGFloat, dt: CGFloat,
                               epsilon: CGFloat) -> Bool {
        v += (-k * (x - target) - c * v) * dt
        x += v * dt
        if abs(x - target) < epsilon && abs(v) < epsilon * 20 {
            x = target
            v = 0
            return true
        }
        return false
    }

    private func startMotion() {
        guard motionTimer == nil, motionLink == nil else { return }
        lastMotionTick = CACurrentMediaTime()
        if #available(macOS 14.0, *), let view = contentView {
            let link = view.displayLink(target: self, selector: #selector(motionLinkFired(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            motionLink = link
        } else {
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tickMotion() }
            RunLoop.main.add(t, forMode: .common)
            motionTimer = t
        }
    }

    @objc private func motionLinkFired(_ link: AnyObject) {
        tickMotion()
    }

    private func stopMotion() {
        motionTimer?.invalidate()
        motionTimer = nil
        if #available(macOS 14.0, *), let link = motionLink as? CADisplayLink { link.invalidate() }
        motionLink = nil
    }

    private func applyKeyDeformAfterSlideIn() {
        let sinceShow = CACurrentMediaTime() - presentStart
        guard sinceShow < 0.5 else { applyKeyDeform(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.5 - sinceShow)) { [weak self] in
            self?.applyKeyDeform()
        }
    }

    private func tickMotion() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30.0, now - lastMotionTick))
        lastMotionTick = now

        var fillSettled = true
        if isDragging {
            displayFraction = lastFraction
            displayFractionVelocity = 0
        } else {
            let k: CGFloat = 260
            fillSettled = Self.spring(&displayFraction, &displayFractionVelocity, to: lastFraction,
                                      stiffness: k, damping: 2 * sqrt(k), dt: dt, epsilon: 0.0005)
        }
        layoutFill()

        if isDragging {
            dragVelocity *= exp(-dt / 0.08)
            let nudgeTarget = dragOvershooting ? 0
                : max(-Self.nudgeAmount, min(Self.nudgeAmount, dragVelocity / 500 * Self.nudgeAmount))
            let kN: CGFloat = 120
            _ = Self.spring(&nudge, &nudgeVelocity, to: nudgeTarget,
                            stiffness: kN, damping: 2 * sqrt(kN), dt: dt, epsilon: 0.05)
            setDeformDirectly(stretch: stretch, nudge: nudge)
        }

        if fillSettled && !isDragging { stopMotion() }
    }

    private func layoutFill() {
        let f = min(1, max(0, displayFraction))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillView.layer?.transform = CATransform3DMakeScale(1, f, 1)
        CATransaction.commit()
    }

    private static func deformTransform(stretch: CGFloat, nudge: CGFloat) -> CATransform3D {
        let w0 = pillWidth, h0 = pillHeight
        let e = abs(stretch)
        let sx = max(0.75, 1 - 1.25 * e / h0)
        let sy = (h0 + e) / h0
        let tx = w0 * (1 - sx) / 2
        let ty = (stretch >= 0 ? 0 : -e) + nudge
        return CATransform3DScale(CATransform3DMakeTranslation(tx, ty, 0), sx, sy, 1)
    }

    private func applyKeyDeform() {
        guard let layer = pillView.layer, !isDragging else { return }
        let s = isPresented ? stretchTarget : 0
        let n = isPresented ? keyNudge : 0
        guard s != stretch || n != nudge else { return }
        stretch = s
        nudge = n
        let to = Self.deformTransform(stretch: s, nudge: n)
        let from = layer.presentation()?.transform ?? layer.transform

        let anim = CASpringAnimation(keyPath: "transform")
        anim.mass = 1
        anim.stiffness = 300
        anim.damping = 2 * sqrt(300)
        anim.fromValue = NSValue(caTransform3D: from)
        anim.toValue = NSValue(caTransform3D: to)
        anim.duration = anim.settlingDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        layer.add(anim, forKey: "deform")
        CATransaction.commit()
    }

    private func setDeformDirectly(stretch s: CGFloat, nudge n: CGFloat) {
        guard let layer = pillView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "deform")
        layer.transform = isPresented ? Self.deformTransform(stretch: s, nudge: n) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func resetStretch() {
        stopMotion()
        stretch = 0
        stretchTarget = 0
        keyHoldDirection = 0
        nudge = 0
        nudgeVelocity = 0
        keyNudge = 0
        dragVelocity = 0
        displayFraction = lastFraction
        displayFractionVelocity = 0
        setDeformDirectly(stretch: 0, nudge: 0)
    }

    private func updateFill(for st: HUDState, animated: Bool) {
        let fraction = min(1, max(0, st.fraction))
        lastFraction = fraction
        hintLabel.stringValue = st.hint ?? ""
        hintLabel.isHidden = !st.disabled || st.hint == nil
        if st.disabled {
            fillView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            iconImageView.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        } else {
            fillView.layer?.backgroundColor = (st.boost ? Self.boostColor : Self.fillColor).cgColor
            let iconCovered = Self.pillHeight * fraction >= iconImageView.frame.midY
            iconImageView.contentTintColor = iconCovered && !st.boost ? NSColor.black.withAlphaComponent(0.6) : .white
        }
        updateSymbol(st.symbolName, value: st.symbolValue, animated: animated)

        let atLimit = !st.muted && !st.disabled && (fraction <= 0 || fraction >= 1)
        if atLimit { triggerLimiter() } else { limiterArmed = true }

        if animated {
            startMotion()
        } else {
            displayFraction = fraction
            displayFractionVelocity = 0
            layoutFill()
        }
    }

    private func updateSymbol(_ name: String, value: Double?, animated: Bool) {
        guard name != currentSymbolName || value != currentSymbolValue else { return }
        let base = value.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let img = base?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) else { return }
        let nameChanged = name != currentSymbolName
        currentSymbolName = name
        currentSymbolValue = value
        if animated, nameChanged, #available(macOS 14.0, *) {
            iconImageView.setSymbolImage(img, contentTransition: .replace)
        } else {
            iconImageView.image = img
        }
    }

    private func scheduleHide(after delay: TimeInterval = LiquidGlassHUDWindow.visibleDuration) {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.hideIfIdle()
        }
    }

    private func hideIfIdle() {
        let pillOnScreen = convertToScreen(pillView.convert(pillView.bounds, to: nil))
        let mouseOver = pillOnScreen.contains(NSEvent.mouseLocation)
        if isDragging || mouseOver || keyHoldDirection != 0 {
            scheduleHide(after: 0.3)
            return
        }
        slideOut()
    }

    var isShowingVolume: Bool { isPresented && state?.kind == .volume }

    func show(_ newState: HUDState, suppressLimiter: Bool = false) {
        fadeTimer?.invalidate()
        if let old = state, old.kind != newState.kind, isPresented {
            keyHoldSafety?.cancel()
            keyHoldSafety = nil
            limiterArmed = true
            keyNudge = 0
            keyHoldDirection = 0
            stretchTarget = 0
            applyKeyDeform()
        }
        state = newState
        if suppressLimiter { limiterArmed = false }

        let sf = newState.screen.frame
        let screenChanged = sf != currentScreenFrame
        if !isPresented || screenChanged {
            let centerY = sf.minY + sf.height * Self.verticalPosition
            setFrameOrigin(NSPoint(x: sf.minX, y: centerY - frame.height / 2))
            let startHidden = !isVisible || screenChanged
            if startHidden {
                resetStretch()
                pillView.frame = hiddenPillFrame
                pillView.alphaValue = 0
            }
            presentStart = CACurrentMediaTime()
            currentScreenFrame = sf
            updateFill(for: newState, animated: !startHidden)
            isPresented = true
            orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                ctx.allowsImplicitAnimation = true
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1.0)
                pillView.animator().frame = shownPillFrame
                pillView.animator().alphaValue = 1
            }
        } else {
            updateFill(for: newState, animated: true)
        }

        scheduleHide()
    }

    func hideImmediately() {
        guard isVisible || isPresented else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        limiterTimer?.invalidate()
        limiterTimer = nil
        keyHoldSafety?.cancel()
        keyHoldSafety = nil
        isDragging = false
        dragOvershooting = false
        limiterArmed = true
        isPresented = false
        resetStretch()
        pillView.layer?.removeAllAnimations()
        pillView.frame = hiddenPillFrame
        pillView.alphaValue = 0
        orderOut(nil)
    }

    private func slideOut() {
        isPresented = false
        resetStretch()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.0, 0.75, 0.0)
            pillView.animator().frame = hiddenPillFrame
            pillView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self = self, !self.isPresented else { return }
            self.orderOut(nil)
        }
    }
}
