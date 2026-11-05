import DictationCore
import Foundation

/// A delivery ends once, independently of whether its worker or history write has returned.
@MainActor final class DeliveryLifecycle {
    enum Outcome: Equatable {
        case inserted(application: String, method: InjectionMethod, profile: String)
        case parked(DictationMiss)
        case refused(String)

        var message: String? {
            switch self {
            case .inserted: return nil
            case .parked(let reason): return reason.completionMessage
            case .refused(let reason): return reason
            }
        }

        var logMessage: String {
            switch self {
            case .inserted(let application, let method, let profile):
                return "inserted into \(application) by \(method.rawValue) with profile \(profile)"
            case .parked, .refused: return "completed: \(message!)"
            }
        }
    }

    static let transcriptionTimeout: Duration = .seconds(120)
    static let insertionTimeout: Duration = .seconds(10)
    private(set) var outcome: Outcome?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var deadline: Task<Void, Never>?
    private var deadlineIdentifier = UUID()
    private let predecessor: DeliveryLifecycle?
    private let log: (String) -> Void

    init(predecessor: DeliveryLifecycle? = nil, log: @escaping (String) -> Void = { dictationLog.notice($0) }) {
        self.predecessor = predecessor
        self.log = log
    }

    func armDeadline(after delay: Duration, expired: @escaping @MainActor () -> Void) {
        guard outcome == nil else { return }
        deadline?.cancel()
        let identifier = UUID()
        deadlineIdentifier = identifier
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.outcome == nil, self.deadlineIdentifier == identifier else { return }
            expired()
        }
    }

    @discardableResult func finish(_ result: Outcome) -> Bool {
        guard outcome == nil else { return false }
        outcome = result
        deadline?.cancel()
        deadline = nil
        log(result.logMessage)
        let waiting = waiters.values
        waiters.removeAll()
        for continuation in waiting { continuation.resume() }
        return true
    }

    func waitUntilFinished() async {
        guard !Task.isCancelled else { return }
        // A successor may time out before its predecessor. Later deliveries must still respect that older work.
        await predecessor?.waitUntilFinished()
        guard outcome == nil, !Task.isCancelled else { return }
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if outcome != nil || Task.isCancelled { continuation.resume() }
                else { waiters[identifier] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: identifier)?.resume() }
        }
    }
}
