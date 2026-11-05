import Foundation

/// PhotoKit may deliver synchronously, deliver more than once, or deliver a late
/// callback after cancellation. Own and resume the continuation exactly once.
final class PhotoPreviewRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancellation: (@Sendable () -> Void)?
    private var completed = false
    private var cancelled = false

    func attach(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if completed { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func setCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelNow = cancelled
        if !completed { cancellation = action }
        lock.unlock()
        if cancelNow { action() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation; self.continuation = nil; cancellation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        cancelled = true; completed = true
        let action = cancellation; cancellation = nil
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        action?()
    }
}
