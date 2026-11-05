import Foundation
import AppKit
import simd
import LocalAuthentication

enum GuardState: Equatable {
    case idle
    case arming(Int)        // seconds left
    case locked             // monitoring, nothing happened
    case warning(String)    // small movement: screen warning, no sound
    case alarm(String)      // big movement / lid closed: warning + siren

    var isArmed: Bool { self != .idle }
    var isMonitoring: Bool {
        switch self {
        case .locked, .warning, .alarm: return true
        default: return false
        }
    }
}

/// The brain of the app: arms/disarms, reads sensors and decides between warning and alarm.
final class GuardController: ObservableObject {
    static let shared = GuardController()

    @Published private(set) var state: GuardState = .idle {
        didSet { if state != oldValue { NSLog("Guard state: %@", String(describing: state)) } }
    }
    @Published private(set) var motionLevel = 0.0      // g, for the live meter
    @Published private(set) var tiltDegrees = 0.0
    @Published private(set) var lidAngle: Double?
    @Published private(set) var motionAvailable = false
    @Published private(set) var lidAngleAvailable = false
    @Published private(set) var lidSleepPrevented = false
    @Published private(set) var unlockPanelVisible = false
    @Published private(set) var touchIDContext: LAContext?
    @Published private(set) var unlockError: String?
    @Published private(set) var checkingPassword = false
    private var unlockTimeout: DispatchWorkItem?
    private var protectionGeneration = 0
    private var showingTouchIDError = false
    private enum AuthenticationPause: Hashable { case application, display, session, system }
    private var authenticationPauses = Set<AuthenticationPause>()
    private var authenticationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var touchID: TouchIDSession<LAContext> = {
        let session = TouchIDSession(makeContext: { LAContext() })
        session.onContextChanged = { [weak self] context in
            guard let self else { return }
            self.touchIDContext = context
            if context != nil, self.showingTouchIDError {
                self.showingTouchIDError = false
                self.unlockError = nil
            }
        }
        session.onAuthenticated = { [weak self] in
            guard let self, self.state.isArmed else { return }
            self.disarm()
        }
        session.onUnavailable = { [weak self] in
            guard let self, self.state.isArmed, !self.unlockPanelVisible else { return }
            self.showUnlockPanel(retryTouchID: false)
        }
        session.onPasswordRequired = { [weak self] code in
            guard let self, self.state.isArmed else { return }
            if !self.unlockPanelVisible { self.showUnlockPanel(retryTouchID: false) }
            guard self.touchIDContext == nil else { return }
            switch code {
            case .biometryLockout:
                self.showingTouchIDError = true
                self.unlockError = "Touch ID is locked. Enter your Mac password."
            case .biometryNotEnrolled:
                self.showingTouchIDError = true
                self.unlockError = "Touch ID is not set up. Enter your Mac password."
            case .passcodeNotSet:
                self.showingTouchIDError = true
                self.unlockError = "Touch ID requires a Mac login password."
            default: break
            }
        }
        return session
    }()

    let settings = Settings.shared
    private let motion = MotionSensor()
    private let lid = LidSensor()
    private let alarm = AlarmPlayer()
    private let power = PowerManager()
    private lazy var overlay = OverlayController(controller: self)

    // Signal processing
    private var gravity: SIMD3<Double>?
    private var baselineGravity: SIMD3<Double>?
    private var baselineLid: Double?
    private var smoothDyn = 0.0
    private var peakDyn = 0.0
    private var activity = 0.0
    private var lidWasClosed = false
    private var lastPublish = Date.distantPast

    // Timing
    private var warningUntil = Date.distantPast
    private var alarmUntil = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var ignoreUntil = Date.distantPast
    private var lastDisplayWake = Date.distantPast
    private var tickTimer: Timer?
    private var lidTimer: Timer?
    private var armTimer: Timer?
    private var sensorClients = 0
    private var testSoundWork: DispatchWorkItem?

    private static let lidClosedBelow = 20.0
    private static let lidOpenAbove = 30.0

    private init() {
        motionAvailable = Self.hasMotionSensor()
        lid.start()
        lidAngleAvailable = lid.hasAngleSensor
        lid.stop()

        motion.onSample = { [weak self] in self?.handle(sample: $0) }
        power.onWillSleep = { [weak self] allow in self?.systemWillSleep(allow: allow) }
        power.onDidWake = { [weak self] in self?.systemDidWake() }
        observeAuthenticationLifecycle()
    }

    // MARK: - Sensors on demand (armed, or settings window open for the live meter)

    func acquireSensors() {
        sensorClients += 1
        guard sensorClients == 1 else { return }
        gravity = nil
        motion.start()
        lid.start()
        lidTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.lidTick() }
        RunLoop.main.add(lidTimer!, forMode: .common)
    }

    func releaseSensors() {
        sensorClients = max(0, sensorClients - 1)
        guard sensorClients == 0 else { return }
        motion.stop()
        lid.stop()
        lidTimer?.invalidate()
        lidTimer = nil
    }

    // MARK: - Arm / disarm

    private func showNoMotionSensorAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This Mac has no motion sensor"
        alert.informativeText = "Guard needs a MacBook with Apple silicon (M1 or newer). Desktop Macs like the Mac mini, iMac and Mac Studio have no motion sensor, so Guard can't protect them."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func toggle() {
        if state == .idle { arm() } else { requestDisarm() }
    }

    /// Developer test: STAYPUT_FAKE_NO_MOTION=1 behaves like a Mac without a motion sensor.
    private static func hasMotionSensor() -> Bool {
        if ProcessInfo.processInfo.environment["STAYPUT_FAKE_NO_MOTION"] != nil { return false }
        return MotionSensor.isAvailable
    }

    func arm() {
        guard state == .idle else { return }
        // Desktop Macs (mini, iMac, Studio) have no motion sensor: refuse instead of
        // showing a lock screen that can't detect anything.
        motionAvailable = Self.hasMotionSensor()
        guard motionAvailable else {
            showNoMotionSensorAlert()
            return
        }
        protectionGeneration += 1
        stopTestSound()
        acquireSensors()
        if Settings.lidSleepOptionAvailable, settings.preventLidSleep {
            lidSleepPrevented = power.preventLidSleep()
        }
        power.beginArmed(keepDisplayOn: settings.keepDisplayOn)
        overlay.show()

        let delay = Int(settings.armDelay.rounded())
        state = .arming(max(delay, 0)) // must leave .idle even with no delay
        if delay > 0 {
            var left = delay
            armTimer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
                left -= 1
                if left <= 0 { t.invalidate(); self?.finishArming() } else { self?.state = .arming(left) }
            }
            RunLoop.main.add(armTimer!, forMode: .common)
        } else {
            finishArming()
        }
        tickTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tickTimer!, forMode: .common)
        startTouchID()
    }

    private func finishArming() {
        armTimer = nil
        guard state.isArmed else { return }
        state = .locked
        lidWasClosed = isLidClosed(angle: lid.angle())
        rebaseline()
        injectTestMovementIfRequested()
    }

    /// Developer test: STAYPUT_TEST_BUMP=<g> adds a fake jolt of that size 1.5 s after arming.
    private func injectTestMovementIfRequested() {
        // Developer test: STAYPUT_TEST_UNLOCK=<text> opens the unlock panel and submits <text> as password.
        if let pw = ProcessInfo.processInfo.environment["STAYPUT_TEST_UNLOCK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showUnlockPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.submitPassword(pw) }
        }
        guard let s = ProcessInfo.processInfo.environment["STAYPUT_TEST_BUMP"], let size = Double(s) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let g = self.gravity else { return }
            for _ in 0..<15 { self.handle(sample: g + SIMD3(size, 0, 0)) }
        }
    }

    /// Shortcut / Unlock button: turn off directly, or show the unlock panel on the lock screen.
    func requestDisarm() {
        guard state.isArmed else { return }
        guard settings.requireAuth else { disarm(); return }
        showUnlockPanel()
    }

    // MARK: - Unlock panel (Touch ID + password, drawn inside Guard's own lock screen)
    //
    // The macOS Touch ID / password dialog can't come to the front while the lock screen
    // blocks app switching, so Guard never relies on it.

    func showUnlockPanel(retryTouchID: Bool = true) {
        guard state.isArmed else { return }
        showingTouchIDError = false
        unlockError = nil
        scheduleUnlockTimeout()
        overlay.focus()
        unlockPanelVisible = true
        if retryTouchID { touchID.retryIfNeeded() }
    }

    func hideUnlockPanel() {
        unlockPanelVisible = false
        showingTouchIDError = false
        unlockError = nil
        unlockTimeout?.cancel()
        unlockTimeout = nil
    }

    /// Touch ID listens the whole time the lock screen is up: just touch the sensor.
    /// It is shown inside Guard's window (see TouchIDView), not as a system dialog.
    func startTouchID() {
        stopTouchID()
        guard state.isArmed, settings.requireAuth, authenticationPauses.isEmpty, NSApp.isActive else { return }
        touchID.start()
    }

    func stopTouchID() {
        touchID.stop()
    }

    func touchIDViewDidAttach(_ context: LAContext) {
        guard state.isArmed, settings.requireAuth, authenticationPauses.isEmpty else { return }
        touchID.viewDidAttach(context)
    }

    private func observeAuthenticationLifecycle() {
        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name, AuthenticationPause, Bool)] = [
            (appCenter, NSApplication.willResignActiveNotification, .application, true),
            (appCenter, NSApplication.didBecomeActiveNotification, .application, false),
            (workspaceCenter, NSWorkspace.screensDidSleepNotification, .display, true),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification, .display, false),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .session, true),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, .session, false),
        ]
        for (center, name, reason, pause) in events {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if pause { self?.pauseTouchID(for: reason) } else { self?.resumeTouchID(after: reason) }
            }
            authenticationObservers.append((center, observer))
        }
    }

    private func pauseTouchID(for reason: AuthenticationPause) {
        authenticationPauses.insert(reason)
        stopTouchID()
    }

    private func resumeTouchID(after reason: AuthenticationPause) {
        authenticationPauses.remove(reason)
        // A fresh context is needed after foreground, display or session changes.
        startTouchID()
    }

    func submitPassword(_ password: String) {
        guard state.isArmed, !password.isEmpty, !checkingPassword else { return }
        checkingPassword = true
        showingTouchIDError = false
        unlockError = nil
        scheduleUnlockTimeout()
        let requestGeneration = protectionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = PasswordCheck.verify(password)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.isArmed,
                      self.protectionGeneration == requestGeneration else { return }
                self.checkingPassword = false
                NSLog("Guard password check: %@", ok ? "ok" : "rejected")
                if ok { self.disarm() } else { self.unlockError = "Wrong password" }
            }
        }
    }

    /// Hide the panel again after a minute without input.
    private func scheduleUnlockTimeout() {
        unlockTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.touchIDContext != nil else { return }
            self.hideUnlockPanel()
        }
        unlockTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func disarm() {
        guard state.isArmed else { return }
        protectionGeneration += 1
        hideUnlockPanel()
        stopTouchID()
        checkingPassword = false
        armTimer?.invalidate(); armTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        alarm.stop()
        overlay.hide()
        power.endArmed()
        power.allowLidSleep()
        lidSleepPrevented = false
        state = .idle
        releaseSensors()
    }

    // MARK: - Detection

    private func handle(sample a: SIMD3<Double>) {
        guard let g = gravity else { gravity = a; return }
        let newGravity = g + (a - g) * 0.05      // low-pass ≈ 0.2 s: the direction of "down"
        gravity = newGravity
        let dyn = simd_length(a - newGravity)     // what's left is movement
        smoothDyn = smoothDyn * 0.6 + dyn * 0.4
        peakDyn = max(peakDyn * 0.97, smoothDyn)
        let tilt = baselineGravity.map { Self.angle($0, newGravity) } ?? 0

        let now = Date()
        if now.timeIntervalSince(lastPublish) > 0.1 {
            motionLevel = peakDyn
            tiltDegrees = tilt
            lastPublish = now
        }

        guard state.isMonitoring, now > ignoreUntil else { return }
        let th = Thresholds(sensitivity: settings.sensitivity)
        // Leaky counter: ~1 s of continuous movement above the warning level escalates to an alarm.
        activity = activity * 0.99 + (smoothDyn > th.warnAccel ? 1 : 0)

        if smoothDyn > th.alarmAccel {
            triggerAlarm("The MacBook was moved.")
        } else if tilt > th.alarmTilt {
            triggerAlarm("The MacBook was lifted or tilted.")
        } else if activity > 65 {
            triggerAlarm("The MacBook keeps being moved.")
        } else if smoothDyn > th.warnAccel || tilt > th.warnTilt {
            triggerWarning("Movement detected.")
        }
    }

    private func isLidClosed(angle: Double?) -> Bool {
        if let angle { return angle < Self.lidClosedBelow }
        return LidSensor.clamshellClosed() ?? false
    }

    private func lidTick() {
        let angle = lid.angle()
        if angle != lidAngle { lidAngle = angle }
        guard state.isMonitoring else { return }

        let closed = isLidClosed(angle: angle)
        if closed && !lidWasClosed {
            lidWasClosed = true
            triggerAlarm("The lid was closed.", force: true)
        } else if lidWasClosed && !closed && (angle ?? 90) > Self.lidOpenAbove {
            lidWasClosed = false
            baselineLid = angle
            triggerWarning("The lid was closed while protected.")
        } else if !closed, let angle, let base = baselineLid, Date() > ignoreUntil,
                  abs(angle - base) > Thresholds(sensitivity: settings.sensitivity).warnLid {
            triggerWarning("The display angle was changed.")
        }
    }

    private func triggerWarning(_ reason: String) {
        let now = Date()
        warningUntil = now.addingTimeInterval(8)
        if case .alarm = state { return }
        if state != .warning(reason) { state = .warning(reason) }
        wakeDisplayThrottled()
    }

    private func triggerAlarm(_ reason: String, force: Bool = false) {
        let now = Date()
        if alarm.isPlaying { return }
        if case .alarm = state, !force { return }
        if !force && now < cooldownUntil {
            triggerWarning(reason)
            return
        }
        state = .alarm(reason)
        warningUntil = now.addingTimeInterval(10)
        wakeDisplayThrottled(force: true)
        if settings.soundEnabled {
            alarm.play(volume: settings.volume, overrideSystem: settings.overrideSystemVolume)
            alarmUntil = now.addingTimeInterval(settings.alarmDuration)
        } else {
            alarmUntil = now.addingTimeInterval(10) // red screen only
        }
    }

    /// Runs 4× per second: ends the siren and warnings when their time is up.
    private func tick() {
        let now = Date()
        if case .alarm(let reason) = state, now >= alarmUntil {
            alarm.stop()
            cooldownUntil = now.addingTimeInterval(4)
            state = .warning(reason)
            warningUntil = now.addingTimeInterval(8)
            rebaseline()
        } else if case .warning = state, now >= warningUntil {
            state = .locked
            rebaseline()
        }
    }

    /// Accept the current position as the new normal (e.g. after someone nudged it).
    private func rebaseline() {
        baselineGravity = gravity
        baselineLid = lid.angle()
        activity = 0
        ignoreUntil = Date().addingTimeInterval(0.5)
    }

    private func wakeDisplayThrottled(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDisplayWake) > 2 else { return }
        lastDisplayWake = now
        power.wakeDisplay()
    }

    private static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0.01, lb > 0.01 else { return 0 }
        let c = max(-1, min(1, simd_dot(a, b) / (la * lb)))
        return acos(c) * 180 / .pi
    }

    // MARK: - Sleep (lid closed)

    private func systemWillSleep(allow: @escaping () -> Void) {
        pauseTouchID(for: .system)
        guard state.isMonitoring else { allow(); return }
        // The lid switch may flip before our 10 Hz poll sees it.
        if !lidWasClosed, LidSensor.clamshellClosed() == true {
            lidWasClosed = true
            triggerAlarm("The lid was closed.", force: true)
        } else if !alarm.isPlaying {
            // Sleeping while armed (e.g. power button) is suspicious too.
            triggerAlarm("The MacBook is being put to sleep.", force: true)
        }
        guard alarm.isPlaying else { allow(); return }
        // Hold back sleep while the siren plays (macOS forces sleep after ~30 s anyway).
        let wait = min(max(alarmUntil.timeIntervalSinceNow, 0), 25)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.alarm.stop()
            allow()
        }
    }

    private func systemDidWake() {
        authenticationPauses.remove(.system)
        guard state.isArmed else { return }
        // Sensors may need a restart after sleep.
        motion.start()
        lid.stop(); lid.start()
        gravity = nil
        if state.isMonitoring {
            // If the lid was closed, the lid poll sees it open again and shows the warning.
            ignoreUntil = Date().addingTimeInterval(1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.rebaselineIfCalm() }
        }
        overlay.show()
        startTouchID()
    }

    private func rebaselineIfCalm() {
        guard state.isMonitoring else { return }
        baselineGravity = gravity
        if case .locked = state { baselineLid = lid.angle() }
    }

    // MARK: - Settings helpers

    var thresholds: Thresholds { Thresholds(sensitivity: settings.sensitivity) }

    func playTestSound() {
        guard state == .idle else { return }
        stopTestSound()
        alarm.play(volume: settings.volume, overrideSystem: settings.overrideSystemVolume)
        let work = DispatchWorkItem { [weak self] in self?.alarm.stop() }
        testSoundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func stopTestSound() {
        testSoundWork?.cancel()
        testSoundWork = nil
        if state == .idle { alarm.stop() }
    }
}
