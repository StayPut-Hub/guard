import Foundation
import AppKit
import Combine
import LocalAuthentication

// These module-local test doubles shadow imported framework symbols. The runner
// compiles the two production source files unchanged. Nothing can open a window,
// read a sensor, verify an account password, or start real authentication.
final class TestApplication {
    var isActive = true
    func activate(ignoringOtherApps: Bool) { isActive = true }
}
let NSApp = TestApplication()
enum NSApplication {
    static let willResignActiveNotification = Notification.Name("test.app.willResignActive")
    static let didBecomeActiveNotification = Notification.Name("test.app.didBecomeActive")
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    let notificationCenter = NotificationCenter()
    static let screensDidSleepNotification = Notification.Name("test.workspace.screensDidSleep")
    static let screensDidWakeNotification = Notification.Name("test.workspace.screensDidWake")
    static let sessionDidResignActiveNotification = Notification.Name("test.workspace.sessionDidResignActive")
    static let sessionDidBecomeActiveNotification = Notification.Name("test.workspace.sessionDidBecomeActive")
}
final class LAContext {
    static var nextErrors: [NSError?] = []
    static var created: [LAContext] = []
    let preflightError: NSError?
    private(set) var invalidated = false
    private(set) var evaluationCount = 0
    private var reply: ((Bool, Error?) -> Void)?
    init() {
        preflightError = Self.nextErrors.isEmpty ? nil : Self.nextErrors.removeFirst()
        Self.created.append(self)
    }
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        error?.pointee = preflightError
        return preflightError == nil
    }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String,
                        reply: @escaping (Bool, Error?) -> Void) {
        evaluationCount += 1
        self.reply = reply
    }
    func invalidate() { invalidated = true }
    func complete(_ success: Bool, error: LAError.Code? = nil) {
        reply?(success, error.map { NSError(domain: LAErrorDomain, code: $0.rawValue) })
    }
}
final class Settings {
    static let shared = Settings()
    static let lidSleepOptionAvailable = false
    var requireAuth = true
    var preventLidSleep = false
    var keepDisplayOn = true
    var armDelay = 0.0
    var sensitivity = 5.0
    var soundEnabled = false
    var volume = 0.0
    var overrideSystemVolume = false
    var alarmDuration = 0.0
}
final class MotionSensor {
    static let isAvailable = true
    var onSample: ((SIMD3<Double>) -> Void)?
    func start() {}
    func stop() {}
}
final class LidSensor {
    let hasAngleSensor = true
    func start() {}
    func stop() {}
    func angle() -> Double? { 90 }
    static func clamshellClosed() -> Bool? { false }
}
final class AlarmPlayer {
    var isPlaying = false
    func play(volume: Double, overrideSystem: Bool) { isPlaying = true }
    func stop() { isPlaying = false }
}
final class PowerManager {
    static var latest: PowerManager!
    var onWillSleep: ((_ allow: @escaping () -> Void) -> Void)?
    var onDidWake: (() -> Void)?
    init() { Self.latest = self }
    func preventLidSleep() -> Bool { false }
    func beginArmed(keepDisplayOn: Bool) {}
    func endArmed() {}
    func allowLidSleep() {}
    func wakeDisplay() {}
}
final class OverlayController {
    static var focuses = 0
    init(controller: GuardController) {}
    func show() {}
    func hide() {}
    func focus() { Self.focuses += 1; NSApp.isActive = true }
}
enum PasswordCheck {
    static var accepted = false
    static var calls = 0
    static var entered: DispatchSemaphore?
    static var blocker: DispatchSemaphore?
    static func verify(_ password: String) -> Bool {
        calls += 1
        let result = accepted
        let entered = Self.entered
        let blocker = Self.blocker
        entered?.signal()
        blocker?.wait()
        return result
    }
}
struct Thresholds {
    let warnAccel = 1.0
    let alarmAccel = 2.0
    let warnTilt = 90.0
    let alarmTilt = 120.0
    let warnLid = 90.0
    init(sensitivity: Double) {}
}

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) throws {
    if !value() { throw TestFailure(description: "Line \(line): \(message)") }
}
@discardableResult
private func pump(until condition: () -> Bool, timeout: TimeInterval = 1.5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}
private func error(_ code: LAError.Code) -> NSError { NSError(domain: LAErrorDomain, code: code.rawValue) }
private func post(_ name: Notification.Name, workspace: Bool = false) {
    (workspace ? NSWorkspace.shared.notificationCenter : NotificationCenter.default).post(name: name, object: nil)
}
private func prepare(errors: [NSError?] = []) -> GuardController {
    let c = GuardController.shared
    c.disarm()
    NSApp.isActive = true
    post(NSApplication.didBecomeActiveNotification)
    post(NSWorkspace.screensDidWakeNotification, workspace: true)
    post(NSWorkspace.sessionDidBecomeActiveNotification, workspace: true)
    PowerManager.latest.onDidWake?()
    Settings.shared.requireAuth = true
    Settings.shared.soundEnabled = false
    PasswordCheck.accepted = false
    PasswordCheck.calls = 0
    PasswordCheck.entered = nil
    PasswordCheck.blocker = nil
    LAContext.nextErrors = errors
    LAContext.created.removeAll()
    OverlayController.focuses = 0
    return c
}
private func availableNeedsReadinessAndDisarmsOnSuccess() throws {
    let c = prepare()
    c.arm()
    let context = try current(c)
    try expect(c.state == .locked, "Arming must reach monitoring")
    try expect(context.evaluationCount == 0, "Authentication must wait for embedded view")
    try expect(!c.unlockPanelVisible, "Available biometrics must not force password entry")
    c.touchIDViewDidAttach(context)
    try expect(context.evaluationCount == 1, "View readiness starts one authentication")
    context.complete(true)
    try expect(pump { c.state == .idle }, "Current biometric success must disarm")
    try expect(!c.unlockPanelVisible && c.touchIDContext == nil, "Disarming must clear all unlock UI")
}
private func current(_ c: GuardController) throws -> LAContext {
    guard let context = c.touchIDContext else { throw TestFailure(description: "Missing current Touch ID context") }
    return context
}
private func unavailableShowsPasswordImmediately() throws {
    let c = prepare(errors: [error(.biometryNotAvailable), nil])
    c.arm()
    try expect(c.unlockPanelVisible, "A failed preflight must immediately open password input")
    try expect(c.touchIDContext == nil, "Unavailable biometrics must expose inactive state to UI")
    try expect(OverlayController.focuses == 1, "Password panel must receive focus once")
    try expect(pump { c.touchIDContext != nil }, "Temporary unavailability must recover automatically")
    try expect(c.unlockPanelVisible, "Recovery must preserve an open password panel")
    try expect(OverlayController.focuses == 1, "Recovery must not steal focus again")
    c.disarm()
}
private func repeatedFailurePreservesPasswordError() throws {
    let c = prepare(errors: [error(.biometryNotAvailable), error(.biometryNotAvailable)])
    c.arm()
    c.submitPassword("deliberately-invalid-test-value")
    try expect(pump { c.unlockError == "Wrong password" }, "Fake rejected password must leave an inline error")
    try expect(pump { LAContext.created.count >= 2 }, "A second transient attempt must occur")
    try expect(c.unlockError == "Wrong password", "Background retry must preserve the password error")
    try expect(c.unlockPanelVisible && OverlayController.focuses == 1, "Retry must preserve the existing panel and focus")
    try expect(c.state.isArmed, "Rejected password must keep protection active")
    c.disarm()
}
private func lockoutAlwaysHasPasswordPath() throws {
    let c = prepare(errors: [error(.biometryLockout)])
    c.arm()
    try expect(c.unlockPanelVisible && c.touchIDContext == nil, "Lockout must open password input with inactive biometrics")
    try expect(c.unlockError?.contains("locked") == true, "Lockout must explain the password requirement")
    PasswordCheck.accepted = true
    c.submitPassword("fake-accepted-test-value")
    try expect(pump { c.state == .idle }, "A verified password must disarm despite biometric lockout")
    try expect(PasswordCheck.calls == 1, "Password verification must run exactly once")
}
private func overlappingDisplayAndSessionPauses() throws {
    let c = prepare()
    c.arm()
    let previous = try current(c)
    c.touchIDViewDidAttach(previous)
    post(NSWorkspace.screensDidSleepNotification, workspace: true)
    post(NSWorkspace.sessionDidResignActiveNotification, workspace: true)
    try expect(c.touchIDContext == nil && previous.invalidated, "Sleep must invalidate the previous authentication")
    let count = LAContext.created.count
    post(NSWorkspace.screensDidWakeNotification, workspace: true)
    try expect(c.touchIDContext == nil && LAContext.created.count == count, "Display wake alone must not resume an inactive session")
    previous.complete(true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    try expect(c.state.isArmed, "A late previous-session success must not disarm")
    post(NSWorkspace.sessionDidBecomeActiveNotification, workspace: true)
    let resumed = try current(c)
    try expect(resumed !== previous, "Final lifecycle resume must create a fresh context")
    c.touchIDViewDidAttach(resumed)
    resumed.complete(true)
    try expect(pump { c.state == .idle }, "A fresh resumed authentication must work")
}
private func appPauseBlocksDisplayWake() throws {
    let c = prepare()
    c.arm()
    NSApp.isActive = false
    post(NSApplication.willResignActiveNotification)
    post(NSWorkspace.screensDidSleepNotification, workspace: true)
    post(NSWorkspace.screensDidWakeNotification, workspace: true)
    try expect(c.touchIDContext == nil, "Display wake must respect app inactivity")
    NSApp.isActive = true
    post(NSApplication.didBecomeActiveNotification)
    try expect(c.touchIDContext != nil, "Returning to active app must restore authentication")
    c.disarm()
}
private func systemWakeRespectsOtherPauses() throws {
    let c = prepare()
    c.arm()
    var allowed = false
    PowerManager.latest.onWillSleep? { allowed = true }
    try expect(allowed, "Fake silent sleep must be allowed immediately")
    try expect(c.touchIDContext == nil, "System sleep must invalidate authentication")
    post(NSWorkspace.sessionDidResignActiveNotification, workspace: true)
    PowerManager.latest.onDidWake?()
    try expect(c.touchIDContext == nil, "System wake must respect inactive session")
    post(NSWorkspace.sessionDidBecomeActiveNotification, workspace: true)
    try expect(c.touchIDContext != nil, "Resuming final pause must restore authentication")
    c.disarm()
}
private func disabledAuthenticationDoesNotAttemptBiometrics() throws {
    let c = prepare()
    Settings.shared.requireAuth = false
    c.arm()
    try expect(c.touchIDContext == nil && LAContext.created.isEmpty, "Disabled auth must not create a context")
    c.requestDisarm()
    try expect(c.state == .idle, "Explicit auth-disabled setting must permit direct disarm")
}
private func ignoresPasswordResultFromPreviousProtectionSession() throws {
    let c = prepare()
    c.arm()
    PasswordCheck.accepted = true
    let entered = DispatchSemaphore(value: 0)
    let blocker = DispatchSemaphore(value: 0)
    PasswordCheck.entered = entered
    PasswordCheck.blocker = blocker
    c.submitPassword("fake-old-session-password")
    try expect(entered.wait(timeout: .now() + 1) == .success, "The delayed old password check must begin")
    c.disarm()
    c.arm()
    blocker.signal()
    try expect(pump { !c.checkingPassword }, "Old password reply must be delivered")
    // Allow the main-queue reply to run even though the new session starts with
    // checkingPassword == false, so the predicate above can already be true.
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    try expect(c.state.isArmed, "An old password success must never disarm a newly armed session")
    c.disarm()
}
private func preventsDuplicatePasswordChecks() throws {
    let c = prepare(errors: [error(.biometryLockout)])
    c.arm()
    let entered = DispatchSemaphore(value: 0)
    let blocker = DispatchSemaphore(value: 0)
    PasswordCheck.entered = entered
    PasswordCheck.blocker = blocker
    c.submitPassword("first-invalid-test-value")
    try expect(entered.wait(timeout: .now() + 1) == .success, "The first password check must begin")
    c.submitPassword("second-invalid-test-value")
    try expect(PasswordCheck.calls == 1, "Repeated submission must not launch concurrent password checks")
    blocker.signal()
    try expect(pump { !c.checkingPassword }, "Rejected password must finish")
    try expect(c.state.isArmed && c.unlockError == "Wrong password", "Rejected password must preserve protection and report the error")
    c.disarm()
}
private func oldRejectionPreservesNewPasswordCheck() throws {
    let c = prepare()
    c.arm()
    let oldEntered = DispatchSemaphore(value: 0)
    let oldBlocker = DispatchSemaphore(value: 0)
    PasswordCheck.entered = oldEntered
    PasswordCheck.blocker = oldBlocker
    c.submitPassword("fake-old-rejected-password")
    try expect(oldEntered.wait(timeout: .now() + 1) == .success, "The old rejected check must begin")
    c.disarm()
    c.arm()
    c.showUnlockPanel()
    let newEntered = DispatchSemaphore(value: 0)
    let newBlocker = DispatchSemaphore(value: 0)
    PasswordCheck.entered = newEntered
    PasswordCheck.blocker = newBlocker
    c.submitPassword("fake-new-rejected-password")
    try expect(newEntered.wait(timeout: .now() + 1) == .success, "The new check must begin independently")
    oldBlocker.signal()
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    try expect(c.checkingPassword, "An old rejection must not clear the new check's progress state")
    try expect(c.unlockError == nil, "An old rejection must not write an error into the new session")
    newBlocker.signal()
    try expect(pump { !c.checkingPassword }, "The new password reply must finish normally")
    try expect(c.unlockError == "Wrong password" && c.state.isArmed, "Only the new rejection may update its session")
    c.disarm()
}
private func clearsResolvedBiometricError() throws {
    let c = prepare(errors: [error(.biometryLockout)])
    c.arm()
    try expect(c.unlockError?.contains("locked") == true, "The initial lockout must explain its restriction")
    post(NSApplication.didBecomeActiveNotification)
    try expect(c.touchIDContext != nil, "The active app must pick up restored Touch ID availability")
    try expect(c.unlockError == nil, "A resolved biometric restriction must not remain visible")
    c.disarm()
}
private func biometricRecoveryPreservesWrongPasswordError() throws {
    let c = prepare(errors: [error(.biometryLockout)])
    c.arm()
    c.submitPassword("fake-invalid-password-before-recovery")
    try expect(pump { c.unlockError == "Wrong password" }, "The rejected password must report its own error")
    post(NSApplication.didBecomeActiveNotification)
    try expect(c.touchIDContext != nil, "A fresh active context must restore Touch ID")
    try expect(c.unlockError == "Wrong password", "Biometric recovery must not erase a password validation error")
    c.disarm()
}

@main
private enum GuardAuthenticationTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("waits for view and handles successful authentication", availableNeedsReadinessAndDisarmsOnSuccess),
            ("opens password immediately and preserves panel on recovery", unavailableShowsPasswordImmediately),
            ("preserves password errors during background retries", repeatedFailurePreservesPasswordError),
            ("allows verified password during biometric lockout", lockoutAlwaysHasPasswordPath),
            ("resumes overlapping display and session pauses safely", overlappingDisplayAndSessionPauses),
            ("respects app inactivity during display wake", appPauseBlocksDisplayWake),
            ("respects session inactivity during system wake", systemWakeRespectsOtherPauses),
            ("respects authentication-disabled preference", disabledAuthenticationDoesNotAttemptBiometrics),
            ("ignores password success from previous protection session", ignoresPasswordResultFromPreviousProtectionSession),
            ("prevents duplicate password checks", preventsDuplicatePasswordChecks),
            ("preserves new password check when old rejection arrives", oldRejectionPreservesNewPasswordCheck),
            ("clears resolved biometric errors after recovery", clearsResolvedBiometricError),
            ("preserves password errors across biometric recovery", biometricRecoveryPreservesWrongPasswordError),
        ]
        var failed = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failed += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
            GuardController.shared.disarm()
        }
        print("\(tests.count - failed)/\(tests.count) controller authentication integration tests passed")
        if failed > 0 { exit(1) }
    }
}
