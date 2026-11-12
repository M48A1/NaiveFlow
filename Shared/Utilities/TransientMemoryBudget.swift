import Synchronization

/// Payload/workspace accounting, not a cap on allocator or JavaScript heap size.
nonisolated final class TransientMemoryBudget: Sendable {
    static let mitm = TransientMemoryBudget(limit: 24 * 1024 * 1024)
    let limit: Int
    private let used = Mutex(0)

    init(limit: Int) { self.limit = max(0, limit) }
    var reservedBytes: Int { used.withLock { $0 } }

    func reserve(_ bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        return used.withLock { used in
            guard bytes <= limit - used else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        guard bytes > 0 else { return }
        used.withLock { $0 -= bytes }
    }
}

/// Owns a reservation through cancellation, early returns and object teardown.
nonisolated final class TransientMemoryReservation: Sendable {
    private let budget: TransientMemoryBudget
    private let bytes = Mutex(0)
    init(budget: TransientMemoryBudget = .mitm) { self.budget = budget }

    @discardableResult
    func resize(_ size: Int) -> Bool {
        guard size >= 0 else { return false }
        return bytes.withLock { current in
            if size > current {
                guard budget.reserve(size - current) else { return false }
            } else {
                budget.release(current - size)
            }
            current = size
            return true
        }
    }

    func add(_ additional: Int) -> Bool {
        guard additional >= 0 else { return false }
        return bytes.withLock { current in
            guard budget.reserve(additional) else { return false }
            current += additional
            return true
        }
    }

    deinit { budget.release(bytes.withLock { $0 }) }
}

/// Bounds both payload bytes and per-packet object overhead before retaining data.
nonisolated struct BoundedPacketQueue<Element> {
    private var packets: [Element] = []
    private(set) var queuedBytes = 0
    private(set) var droppedPackets: UInt64 = 0
    let byteLimit: Int
    let packetLimit: Int
    var count: Int { packets.count }
    var isEmpty: Bool { packets.isEmpty }

    mutating func append(_ packet: Element, byteCount: Int) {
        guard byteCount > 0, byteCount <= byteLimit - queuedBytes,
              packets.count < packetLimit else {
            droppedPackets &+= 1
            return
        }
        packets.append(packet)
        queuedBytes += byteCount
    }

    mutating func drain(into output: inout [Element]) {
        precondition(output.isEmpty)
        swap(&output, &packets)
        queuedBytes = 0
    }

    mutating func clear() {
        packets = []
        queuedBytes = 0
    }
}
