import Foundation
import LocalAuthentication

private func localError(_ code: LAError.Code) -> Error {
    NSError(domain: LAErrorDomain, code: code.rawValue)
}

private final class StressContext: TouchIDAuthenticating {
    let error: Error?
    private(set) var evaluations = 0
    private(set) var invalidations = 0
    var reply: ((Bool, Error?) -> Void)?

    init(error: Error?) { self.error = error }
    func availabilityError() -> Error? { error }
    func evaluate(_ reply: @escaping (Bool, Error?) -> Void) {
        evaluations += 1
        self.reply = reply
    }
    func invalidate() { invalidations += 1 }
}

private final class StressHarness {
    struct Delivery {
        let context: StressContext
        let success: Bool
        let action: () -> Void
    }

    var nextError: Error?
    var contexts: [StressContext] = []
    var work: [DispatchWorkItem] = []
    var deliveries: [Delivery] = []
    var authentications = 0
    var unavailable = 0
    var passwords = 0
    private var completingContext: StressContext?
    private var completingSuccess = false

    lazy var session = TouchIDSession<StressContext>(
        makeContext: { [unowned self] in
            let context = StressContext(error: self.nextError)
            self.nextError = nil
            self.contexts.append(context)
            return context
        },
        schedule: { [unowned self] _, work in self.work.append(work) },
        deliver: { [unowned self] action in
            self.deliveries.append(Delivery(context: self.completingContext!,
                                            success: self.completingSuccess, action: action))
        }
    )

    init() {
        session.onAuthenticated = { [unowned self] in self.authentications += 1 }
        session.onUnavailable = { [unowned self] in self.unavailable += 1 }
        session.onPasswordRequired = { [unowned self] _ in self.passwords += 1 }
    }

    var pending: [DispatchWorkItem] { work.filter { !$0.isCancelled } }

    func complete(_ context: StressContext, success: Bool, error: Error? = nil) {
        completingContext = context
        completingSuccess = success
        context.reply?(success, error)
        completingContext = nil
    }

    func flushOne(_ index: Int = 0) throws {
        let delivery = deliveries.remove(at: index)
        let wasCurrent = session.context === delivery.context
        let beforeContext = session.context
        let beforeAuth = authentications
        let beforeUnavailable = unavailable
        let beforePasswords = passwords
        delivery.action()
        try check(authentications == beforeAuth + (wasCurrent && delivery.success ? 1 : 0),
                  "Only a current success may authenticate")
        if !wasCurrent {
            try check(session.context === beforeContext, "Stale delivery changed the live context")
            try check(unavailable == beforeUnavailable && passwords == beforePasswords,
                      "Stale delivery changed the password fallback")
        }
    }

    func flushAllReversed() throws {
        while !deliveries.isEmpty { try flushOne(deliveries.count - 1) }
    }

    func runNextWork() {
        while !work.isEmpty {
            let next = work.removeFirst()
            if next.isCancelled { continue }
            next.perform()
            return
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String,
                   line: UInt = #line) throws {
    if !condition() { throw CheckFailure(description: "Line \(line): \(message)") }
}

private func stressOutOfOrderCompletions() throws {
    let h = StressHarness()
    var previous: StressContext?
    for iteration in 0..<1_000 {
        h.session.start()
        let first = h.session.context!
        h.session.viewDidAttach(first)
        h.session.viewDidAttach(first)
        try check(first.evaluations == 1, "Repeated attachment duplicated authentication")
        if let previous {
            h.complete(previous, success: true)
            h.complete(previous, success: false, error: localError(.biometryLockout))
        }
        h.complete(first, success: false, error: localError(.systemCancel))
        if iteration % 2 == 0 {
            // Interrupt before LocalAuthentication's queued reply reaches main.
            h.session.stop()
            h.session.start()
        } else {
            try h.flushOne(h.deliveries.count - 1)
            try check(h.pending.count == 1, "An interruption must leave one recovery attempt")
            h.session.stop()
            h.work.forEach { $0.perform() }
            h.session.start()
        }
        let current = h.session.context!
        h.session.viewDidAttach(current)
        h.complete(current, success: true)
        h.complete(current, success: true)
        try h.flushAllReversed()
        try check(h.authentications == iteration + 1, "A session accepted a duplicate or stale success")
        try check(h.session.context == nil, "Accepted authentication must stop listening")
        try check(h.pending.isEmpty, "Completed session left a recovery request behind")
        previous = current
    }
    h.session.stop()
}

private func unknownAndMissingErrorsRecover() throws {
    for error: Error? in [NSError(domain: "StayPut.Test", code: 987), nil] {
        let h = StressHarness()
        h.session.start()
        let context = h.session.context!
        h.session.viewDidAttach(context)
        h.complete(context, success: false, error: error)
        try h.flushOne()
        try check(h.unavailable == 1 && h.authentications == 0,
                  "An undocumented failure must retain the password fallback")
        try check(h.pending.count == 1, "An undocumented failure must be recoverable")
        h.runNextWork()
        let recovered = h.session.context!
        h.session.viewDidAttach(recovered)
        h.complete(recovered, success: true)
        try h.flushOne()
        try check(h.authentications == 1, "Recovery after an undocumented failure did not authenticate")
        h.session.stop()
    }
}

private func unavailableCallbackCanStopSession() throws {
    let h = StressHarness()
    h.nextError = localError(.biometryNotAvailable)
    h.session.onUnavailable = { [unowned h] in
        h.unavailable += 1
        h.session.stop()
    }
    h.session.start()
    h.work.forEach { $0.perform() }
    try check(h.contexts.count == 1 && h.session.context == nil,
              "Stopping from fallback notification must prevent recovery")
    try check(h.pending.isEmpty, "Fallback cancellation left recovery scheduled")
}

private func unavailableCallbackCanRestartSession() throws {
    let h = StressHarness()
    h.nextError = localError(.biometryNotAvailable)
    h.session.onUnavailable = { [unowned h] in
        h.unavailable += 1
        h.session.start()
    }
    h.session.start()
    let replacement = h.session.context
    h.work.forEach { $0.perform() }
    try check(h.contexts.count == 2 && h.session.context === replacement,
              "Restarting from fallback notification must preserve the new session")
    try check(h.pending.isEmpty, "Restart left a previous recovery request active")
    h.session.stop()
}

private func passwordCallbackStopMustSuppressOldUnavailable() throws {
    let h = StressHarness()
    h.nextError = localError(.biometryLockout)
    h.session.onPasswordRequired = { [unowned h] _ in
        h.passwords += 1
        h.session.stop()
    }
    h.session.start()
    try check(h.passwords == 1, "Expected the system password requirement")
    try check(h.unavailable == 0,
              "Failure continued notifying after its password callback stopped the session")
}

private func passwordCallbackRestartMustSuppressOldUnavailable() throws {
    let h = StressHarness()
    h.nextError = localError(.biometryLockout)
    h.session.onPasswordRequired = { [unowned h] _ in
        h.passwords += 1
        h.session.start()
    }
    h.session.start()
    try check(h.session.context != nil, "The replacement session should be available")
    try check(h.unavailable == 0,
              "Old lockout delivered an unavailable notification into the replacement session")
    h.session.stop()
}

@main
private enum TouchIDStressTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("1,000 sessions reject stale and duplicate queued replies", stressOutOfOrderCompletions),
            ("unknown and missing errors recover", unknownAndMissingErrorsRecover),
            ("fallback callback can stop the session", unavailableCallbackCanStopSession),
            ("fallback callback can restart the session", unavailableCallbackCanRestartSession),
            ("password callback stop suppresses obsolete fallback", passwordCallbackStopMustSuppressOldUnavailable),
            ("password callback restart suppresses obsolete fallback", passwordCallbackRestartMustSuppressOldUnavailable),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) Touch ID stress tests passed")
        if failures > 0 { exit(1) }
    }
}
