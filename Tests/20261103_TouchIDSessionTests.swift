import Foundation
import LocalAuthentication

private func authenticationError(_ code: LAError.Code) -> Error {
    NSError(domain: LAErrorDomain, code: code.rawValue)
}

private final class FakeContext: TouchIDAuthenticating {
    let preflightError: Error?
    private(set) var evaluations = 0
    private(set) var invalidations = 0
    private var reply: ((Bool, Error?) -> Void)?

    init(error: Error?) { preflightError = error }
    func availabilityError() -> Error? { preflightError }
    func evaluate(_ reply: @escaping (Bool, Error?) -> Void) {
        evaluations += 1
        self.reply = reply
    }
    func invalidate() { invalidations += 1 }
    func complete(_ success: Bool, error: LAError.Code? = nil) {
        reply?(success, error.map(authenticationError))
    }
}

private final class Harness {
    struct Scheduled {
        let delay: TimeInterval
        let work: DispatchWorkItem
    }

    var preflightErrors: [Error?]
    private(set) var contexts: [FakeContext] = []
    private(set) var scheduled: [Scheduled] = []
    private(set) var published: [FakeContext?] = []
    private(set) var authentications = 0
    private(set) var passwordReasons: [LAError.Code] = []
    private(set) var unavailableNotifications = 0
    var retryFromUnavailable = false
    var deferReplies = false
    private(set) var replies: [() -> Void] = []

    lazy var session = TouchIDSession<FakeContext>(
        makeContext: { [unowned self] in
            let error = self.preflightErrors.isEmpty ? nil : self.preflightErrors.removeFirst()
            let context = FakeContext(error: error)
            self.contexts.append(context)
            return context
        },
        schedule: { [unowned self] delay, work in
            self.scheduled.append(Scheduled(delay: delay, work: work))
        },
        deliver: { [unowned self] reply in
            if self.deferReplies { self.replies.append(reply) } else { reply() }
        }
    )

    init(errors: [Error?] = []) {
        preflightErrors = errors
        session.onContextChanged = { [unowned self] in self.published.append($0) }
        session.onAuthenticated = { [unowned self] in self.authentications += 1 }
        session.onPasswordRequired = { [unowned self] in self.passwordReasons.append($0) }
        session.onUnavailable = { [unowned self] in
            self.unavailableNotifications += 1
            if self.retryFromUnavailable { self.session.retryIfNeeded() }
        }
    }

    var pending: [Scheduled] { scheduled.filter { !$0.work.isCancelled } }

    @discardableResult
    func runNext() -> TimeInterval? {
        while !scheduled.isEmpty {
            let next = scheduled.removeFirst()
            if next.work.isCancelled { continue }
            next.work.perform()
            return next.delay
        }
        return nil
    }

    func deliverReplies() {
        let queued = replies
        replies.removeAll()
        queued.forEach { $0() }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    line: UInt = #line) throws {
    if !condition() { throw Failure(description: "Line \(line): \(message)") }
}

private func waitsForAttachedView() throws {
    let h = Harness()
    h.session.start()
    let context = h.contexts[0]
    try expect(h.session.context === context, "A usable context must be published")
    try expect(h.published.last! === context, "Observers must receive the current context")
    try expect(context.evaluations == 0, "Evaluation must wait for the embedded view")
    h.session.retryIfNeeded()
    try expect(h.contexts.count == 1, "Recovery must preserve an active context")
    h.session.viewDidAttach(context)
    h.session.viewDidAttach(context)
    try expect(context.evaluations == 1, "Repeated attachment must not duplicate evaluation")
    context.complete(true)
    try expect(h.authentications == 1, "A successful current evaluation must authenticate")
    h.session.stop()
    try expect(h.unavailableNotifications == 0, "Success and intentional stop must not report unavailability")
}

private func retriesTransientPreflightFailure() throws {
    let h = Harness(errors: [authenticationError(.biometryNotAvailable), nil])
    h.session.start()
    try expect(h.session.context == nil, "Unavailable contexts must not be published")
    try expect(h.pending.count == 1, "A transient preflight failure must schedule recovery")
    try expect(h.unavailableNotifications == 1, "Transient unavailability must open the password fallback")
    h.session.retryIfNeeded()
    h.session.retryIfNeeded()
    try expect(h.pending.count == 1, "Recovery requests must share a pending retry")
    try expect(h.runNext() == 1, "The first retry should wait one second")
    try expect(h.contexts.count == 2, "Recovery must create a fresh context")
    let context = h.contexts[1]
    try expect(h.session.context === context, "Recovery must publish the fresh context")
    try expect(context.evaluations == 0, "Recovered contexts also wait for their view")
    h.session.viewDidAttach(context)
    context.complete(true)
    try expect(h.authentications == 1, "Touch ID must work after transient unavailability")
    try expect(h.unavailableNotifications == 1, "Successful recovery must not report another failure")
    h.session.stop()
}

private func capsRetryBackoff() throws {
    let h = Harness(errors: Array(repeating: authenticationError(.biometryNotAvailable), count: 6))
    h.session.start()
    for delay: TimeInterval in [1, 2, 4, 8, 8] {
        try expect(h.pending.count == 1, "Only one recovery attempt may be pending")
        try expect(h.runNext() == delay, "Recovery must use capped exponential backoff")
    }
    h.session.stop()
}

private func recoversAfterInterruptedEvaluation() throws {
    let h = Harness(errors: [nil, authenticationError(.biometryNotAvailable), nil])
    h.session.start()
    let interrupted = h.contexts[0]
    h.session.viewDidAttach(interrupted)
    interrupted.complete(false, error: .systemCancel)
    try expect(h.session.context == nil, "An interrupted context must be removed")
    try expect(h.pending.count == 1, "System cancellation must schedule recovery")
    try expect(h.unavailableNotifications == 1, "Interrupted evaluation must report unavailability")
    h.runNext()
    try expect(h.pending.count == 1, "Temporary wake unavailability must keep recovery alive")
    try expect(h.unavailableNotifications == 2, "Failed recovery must preserve the password fallback")
    h.runNext()
    let recovered = h.contexts[2]
    h.session.viewDidAttach(recovered)
    recovered.complete(true)
    try expect(h.authentications == 1, "An interrupted evaluation must recover")
    h.session.stop()
}

private func passwordRequirementsStopPolling() throws {
    for code: LAError.Code in [.biometryLockout, .biometryNotEnrolled, .passcodeNotSet] {
        let h = Harness(errors: [authenticationError(code), nil])
        h.session.start()
        try expect(h.passwordReasons == [code], "Preflight restrictions must request a password")
        try expect(h.unavailableNotifications == 1, "Password restrictions must report unavailability")
        try expect(h.pending.isEmpty, "Password-required restrictions must not poll")
        h.session.retryIfNeeded()
        try expect(h.contexts.count == 1, "Passive recovery must preserve a password requirement")
        h.session.start()
        try expect(h.contexts.count == 2, "Explicit restart must check changed availability")
        try expect(h.session.context === h.contexts[1], "Explicit restart must clear the blocked state")
        h.session.stop()
    }
}

private func evaluationLockoutRequestsPassword() throws {
    let h = Harness()
    h.session.start()
    let context = h.contexts[0]
    h.session.viewDidAttach(context)
    context.complete(false, error: .biometryLockout)
    try expect(h.passwordReasons == [.biometryLockout], "Evaluation lockout must request a password")
    try expect(h.unavailableNotifications == 1, "Evaluation lockout must report unavailability")
    try expect(h.session.context == nil, "Locked biometrics must remove the listening context")
    try expect(h.pending.isEmpty, "Evaluation lockout must not poll")
    h.session.retryIfNeeded()
    try expect(h.contexts.count == 1, "Passive recovery must not bypass lockout")
    h.session.stop()
}

private func passwordFallbackKeepsTouchIDRecoverable() throws {
    let h = Harness()
    h.session.start()
    let context = h.contexts[0]
    h.session.viewDidAttach(context)
    context.complete(false, error: .userFallback)
    try expect(h.passwordReasons == [.userFallback], "Explicit fallback must request the password panel")
    try expect(h.pending.count == 1, "Choosing password must leave Touch ID recoverable")
    h.runNext()
    try expect(h.contexts.count == 2, "Touch ID must restart after explicit password fallback")
    h.session.stop()
}

private func ignoresCallbacksFromPreviousSession() throws {
    let h = Harness()
    h.session.start()
    let previous = h.contexts[0]
    h.session.viewDidAttach(previous)
    h.session.start()
    let current = h.contexts[1]
    try expect(previous.invalidations > 0, "Restart must invalidate the old context")
    previous.complete(true)
    previous.complete(false, error: .biometryLockout)
    h.session.viewDidAttach(previous)
    try expect(h.authentications == 0, "A previous session must never authenticate the current session")
    try expect(h.passwordReasons.isEmpty, "Previous errors must not affect the current session")
    try expect(h.unavailableNotifications == 0, "Previous errors must not open the password fallback")
    try expect(h.session.context === current, "Stale callbacks must preserve the current context")
    try expect(previous.evaluations == 1, "Stale attachment must not start another evaluation")
    h.session.viewDidAttach(current)
    current.complete(true)
    try expect(h.authentications == 1, "The current context must still authenticate")
    h.session.stop()
}

private func stopCancelsPendingRecovery() throws {
    let h = Harness(errors: [authenticationError(.notInteractive)])
    h.session.start()
    let queued = h.pending[0].work
    h.session.stop()
    try expect(queued.isCancelled, "Stopping must cancel queued recovery")
    queued.perform()
    h.session.retryIfNeeded()
    try expect(h.contexts.count == 1, "Stopped sessions must not be revived by queued work or passive recovery")
    try expect(h.session.context == nil, "Stopping must clear the context")
    try expect(h.authentications == 0, "Stopping must never authenticate")
}

private func restartCancelsPreviousRecovery() throws {
    let h = Harness(errors: [authenticationError(.biometryNotAvailable), nil])
    h.session.start()
    let queued = h.pending[0].work
    h.session.start()
    let current = h.contexts[1]
    try expect(queued.isCancelled, "Restarting must cancel previous recovery")
    queued.perform()
    try expect(h.contexts.count == 2, "Stale queued recovery must not create another context")
    try expect(h.session.context === current, "Stale queued recovery must preserve the current context")
    h.session.stop()
}

private func stopInvalidatesCurrentEvaluation() throws {
    let h = Harness()
    h.session.start()
    let context = h.contexts[0]
    h.session.viewDidAttach(context)
    h.session.stop()
    try expect(context.invalidations > 0, "Stopping must invalidate a live authentication context")
    context.complete(true)
    context.complete(false, error: .systemCancel)
    try expect(h.authentications == 0, "A late success after stop must be ignored")
    try expect(h.pending.isEmpty, "A late error after stop must not restart authentication")
    try expect(h.unavailableNotifications == 0, "Intentional stop and stale errors must not open the fallback")
}

private func unavailableCallbackCannotRecursivelyRetry() throws {
    for code: LAError.Code in [.biometryNotAvailable, .biometryLockout, .biometryNotEnrolled, .passcodeNotSet] {
        let h = Harness(errors: [authenticationError(code), nil])
        h.retryFromUnavailable = true
        h.session.start()
        try expect(h.unavailableNotifications == 1, "Failure must notify the fallback once")
        try expect(h.contexts.count == 1, "Fallback notification must not recursively retry")
        try expect(h.pending.count == (code == .biometryNotAvailable ? 1 : 0),
                   "Retry or password-required state must be established before notifying the fallback")
        h.session.stop()
    }

    let h = Harness()
    h.retryFromUnavailable = true
    h.session.start()
    let context = h.contexts[0]
    h.session.viewDidAttach(context)
    context.complete(false, error: .systemCancel)
    try expect(h.unavailableNotifications == 1, "Interrupted evaluation must notify the fallback once")
    try expect(h.contexts.count == 1, "Evaluation fallback must not recursively retry")
    try expect(h.pending.count == 1, "Evaluation fallback must preserve one queued retry")
    h.session.stop()
}

private func ignoresReplyQueuedBeforeRestart() throws {
    let h = Harness()
    h.deferReplies = true
    h.session.start()
    let previous = h.contexts[0]
    h.session.viewDidAttach(previous)
    previous.complete(true)
    try expect(h.replies.count == 1, "Framework replies must pass through the delivery queue")
    try expect(h.authentications == 0, "Queued replies must not authenticate before delivery")
    h.session.start()
    let current = h.contexts[1]
    h.deliverReplies()
    try expect(h.authentications == 0, "A success queued before restart must be ignored")
    try expect(h.session.context === current, "Queued previous success must preserve the current context")
    h.session.viewDidAttach(current)
    current.complete(true)
    h.deliverReplies()
    try expect(h.authentications == 1, "Current queued success must still authenticate")
    h.session.stop()
}

@main
private enum TouchIDSessionTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("waits for the embedded view", waitsForAttachedView),
            ("recovers from transient preflight failure", retriesTransientPreflightFailure),
            ("caps retry backoff", capsRetryBackoff),
            ("recovers from interrupted evaluation", recoversAfterInterruptedEvaluation),
            ("preserves password requirements", passwordRequirementsStopPolling),
            ("handles evaluation lockout", evaluationLockoutRequestsPassword),
            ("keeps Touch ID recoverable after password fallback", passwordFallbackKeepsTouchIDRecoverable),
            ("ignores previous session callbacks", ignoresCallbacksFromPreviousSession),
            ("cancels recovery on stop", stopCancelsPendingRecovery),
            ("cancels previous recovery on restart", restartCancelsPreviousRecovery),
            ("invalidates evaluation on stop", stopInvalidatesCurrentEvaluation),
            ("ignores success queued before restart", ignoresReplyQueuedBeforeRestart),
            ("prevents recursive retry from fallback notification", unavailableCallbackCannotRecursivelyRetry),
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                fputs("FAIL: \(name): \(error)\n", stderr)
            }
        }
        print("\(tests.count - failures)/\(tests.count) Touch ID lifecycle tests passed")
        if failures > 0 { exit(1) }
    }
}
