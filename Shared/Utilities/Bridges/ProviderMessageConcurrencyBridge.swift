import Foundation
import NetworkExtension
import Synchronization

nonisolated enum ProviderMessageConcurrencyBridge {
    /// Cancellation, timeout, synchronous errors and late callbacks all share one completion gate.
    private final class Reply: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Data?, Never>?
            var completed = false
            var result: Data?
            var timeout: Task<Void, Never>?
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<Data?, Never>) {
            let completed: (Bool, Data?) = state.withLock {
                if $0.completed { return (true, $0.result) }
                $0.continuation = continuation
                return (false, nil)
            }
            if completed.0 { continuation.resume(returning: completed.1) }
        }

        func finish(_ result: Data?) {
            let pending = state.withLock { state -> (CheckedContinuation<Data?, Never>?, Task<Void, Never>?) in
                guard !state.completed else { return (nil, nil) }
                state.completed = true
                state.result = result
                defer { state.continuation = nil; state.timeout = nil }
                return (state.continuation, state.timeout)
            }
            pending.1?.cancel()
            pending.0?.resume(returning: result)
        }

        func arm(_ timeout: Duration) {
            let task = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                finish(nil)
            }
            let finished = state.withLock {
                if $0.completed { return true }
                $0.timeout = task
                return false
            }
            if finished { task.cancel() }
        }
    }

    static func send(_ messageData: Data, over session: NETunnelProviderSession,
                     timeout: Duration? = nil) async -> Data? {
        await send(timeout: timeout) { reply in
            try session.sendProviderMessage(messageData, responseHandler: reply)
        }
    }

    static func send(timeout: Duration? = .seconds(3),
                     operation: (@escaping @Sendable (Data?) -> Void) throws -> Void) async -> Data? {
        let reply = Reply()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(nil); return }
                if let timeout { reply.arm(timeout) }
                do { try operation { reply.finish($0) } }
                catch { reply.finish(nil) }
            }
        } onCancel: {
            reply.finish(nil)
        }
    }
}
