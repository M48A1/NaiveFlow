//
//  AsyncInbox.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/18/26.
//

import Foundation
import Synchronization

nonisolated final class AsyncInbox<Element: Sendable>: Sendable {
    private struct State {
        var buffer: [Element?] = []
        var head = 0
        var finished = false
        var failure: Error?
        var waiter: CheckedContinuation<Void, Never>?

        var count: Int { buffer.count - head }

        mutating func popFirst() -> Element {
            let element = buffer[head]!
            // Release consumed payloads immediately, even while the queue stays busy.
            buffer[head] = nil
            head += 1
            if head == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64 && head >= count {
                // Compact only after enough reads to amortize moving the live suffix.
                buffer.removeFirst(head)
                head = 0
            }
            return element
        }

        mutating func drain() -> [Element] {
            let batch = buffer[head...].map { $0! }
            buffer.removeAll(keepingCapacity: true)
            head = 0
            return batch
        }
    }

    private enum Step {
        case element(Element)
        case batch([Element])
        case end
        case failure(Error)
        case wait
    }

    private let state = Mutex(State())
    
    private let capacity: Int?
    
    init(capacity: Int? = nil) {
        self.capacity = capacity
    }
    
    func yield(_ element: Element) {
        yield(element, compactingAbove: .max) { $0 }
    }

    func yield(_ element: Element, compactingAbove depth: Int, _ compact: (Element) -> Element) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            guard !s.finished else { return nil }
            if let capacity, s.count >= capacity { return nil }
            s.buffer.append(s.count >= depth ? compact(element) : element)
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    
    func finish() {
        finish(error: nil)
    }
    
    func finish(throwing error: Error) {
        finish(error: error)
    }

    private func finish(error: Error?) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            guard !s.finished else { return nil }
            s.finished = true
            s.failure = error
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    
    func next() async throws -> Element? {
        while true {
            let step: Step = state.withLock { s in
                if s.count > 0 {
                    return .element(s.popFirst())
                }
                if let failure = s.failure {
                    s.failure = nil   // surface once, then behave as a clean end
                    return .failure(failure)
                }
                if s.finished {
                    return .end
                }
                return .wait
            }
            switch step {
            case .element(let element):
                return element
            case .batch:
                fatalError("next() never produces a batch step")
            case .end:
                return nil
            case .failure(let error):
                throw error
            case .wait:
                await park()
                try Task.checkCancellation()
            }
        }
    }
    
    func nextBatch() async throws -> [Element]? {
        while true {
            let step: Step = state.withLock { s in
                if s.count > 0 {
                    return .batch(s.drain())
                }
                if let failure = s.failure {
                    s.failure = nil
                    return .failure(failure)
                }
                if s.finished {
                    return .end
                }
                return .wait
            }
            switch step {
            case .element:
                fatalError("nextBatch() never produces an element step")
            case .batch(let batch):
                return batch
            case .end:
                return nil
            case .failure(let error):
                throw error
            case .wait:
                await park()
                try Task.checkCancellation()
            }
        }
    }
    
    private func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready: Bool = state.withLock { s in
                    if s.count > 0 || s.failure != nil || s.finished || Task.isCancelled { return true }
                    s.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume()
        }
    }
}
