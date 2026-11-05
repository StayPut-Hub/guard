import Foundation
import LocalAuthentication

/// The session can be exercised without a sensor or an authentication prompt.
protocol TouchIDAuthenticating: AnyObject {
    func availabilityError() -> Error?
    func evaluate(_ reply: @escaping (Bool, Error?) -> Void)
    func invalidate()
}

extension LAContext: TouchIDAuthenticating {
    func availabilityError() -> Error? {
        var error: NSError?
        guard canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return error ?? LAError(.biometryNotAvailable)
        }
        return nil
    }

    func evaluate(_ reply: @escaping (Bool, Error?) -> Void) {
        evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                       localizedReason: "turn off theft protection", reply: reply)
    }
}

/// Owns one embedded authentication attempt and at most one pending retry.
/// All state and callbacks are confined to the main queue.
final class TouchIDSession<Context: TouchIDAuthenticating> {
    var onContextChanged: ((Context?) -> Void)?
    var onAuthenticated: (() -> Void)?
    var onPasswordRequired: ((LAError.Code) -> Void)?
    var onUnavailable: (() -> Void)?

    private(set) var context: Context? {
        didSet { onContextChanged?(context) }
    }
    private let makeContext: () -> Context
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private var retry: DispatchWorkItem?
    private var generation = 0
    private var running = false
    private var evaluating = false
    private var requiresPassword = false
    private var retryDelay: TimeInterval = 1

    init(makeContext: @escaping () -> Context,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.makeContext = makeContext
        self.schedule = schedule
        self.deliver = deliver
    }

    func start() {
        stop()
        running = true
        requiresPassword = false
        retryDelay = 1
        attempt()
    }

    func stop() {
        running = false
        generation += 1
        retry?.cancel()
        retry = nil
        clearContext()
    }

    func retryIfNeeded() {
        guard running, context == nil, retry == nil, !requiresPassword else { return }
        attempt()
    }

    /// Called by the AppKit view once it is attached to a window. A time delay
    /// cannot guarantee this, especially while waking or rebuilding displays.
    func viewDidAttach(_ attachedContext: Context) {
        guard running, context === attachedContext, !evaluating else { return }
        evaluating = true
        let attemptGeneration = generation
        attachedContext.evaluate { [weak self, weak attachedContext] success, error in
            guard let self else { return }
            // LocalAuthentication replies on a private queue. Never run the
            // next preflight check directly inside that reply (it can deadlock).
            self.deliver { [weak self, weak attachedContext] in
                guard let self, let attachedContext, self.running,
                      self.generation == attemptGeneration,
                      self.context === attachedContext else { return }
                if success {
                    self.stop()
                    self.onAuthenticated?()
                } else {
                    self.clearContext()
                    guard self.running, self.generation == attemptGeneration else { return }
                    self.handleFailure(error)
                }
            }
        }
    }

    private func attempt() {
        guard running, context == nil else { return }
        let next = makeContext()
        if let error = next.availabilityError() {
            next.invalidate()
            handleFailure(error)
            return
        }
        context = next
        NSLog("Guard Touch ID ready for embedded view")
    }

    private func clearContext() {
        let previous = context
        context = nil
        evaluating = false
        previous?.invalidate()
    }

    private func handleFailure(_ error: Error?) {
        let failureGeneration = generation
        NSLog("Guard Touch ID unavailable: %@", String(describing: error))
        let code = (error as? LAError)?.code
        switch code {
        case .biometryLockout?, .biometryNotEnrolled?, .passcodeNotSet?:
            // Repeated requests cannot remove a system security requirement.
            requiresPassword = true
            onPasswordRequired?(code!)
        default:
            // Availability can fail temporarily during wake, session changes,
            // or while another app owns the sensor. Keep trying with backoff.
            scheduleRetry()
            if code == .userFallback { onPasswordRequired?(.userFallback) }
        }
        // Showing the password panel may synchronously resume/stop the app's
        // authentication lifecycle. Do not notify that new session of this error.
        guard running, generation == failureGeneration else { return }
        onUnavailable?()
    }

    private func scheduleRetry() {
        guard running, retry == nil else { return }
        let attemptGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == attemptGeneration else { return }
            self.retry = nil
            self.attempt()
        }
        retry = work
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        schedule(delay, work)
    }
}
