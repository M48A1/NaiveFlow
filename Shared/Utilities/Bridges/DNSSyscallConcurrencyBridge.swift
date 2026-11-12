//
//  DNSSyscallConcurrencyBridge.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/17/26.
//

import Foundation
import Synchronization
import dnssd

nonisolated final class DNSSyscallConcurrencyBridge: Sendable {
    static let shared = DNSSyscallConcurrencyBridge()
    private static let sharedSlots = TransientMemoryBudget(limit: 16)
    private let slots: TransientMemoryBudget

    init(maxConcurrentCalls: Int? = nil) {
        slots = maxConcurrentCalls.map { TransientMemoryBudget(limit: $0) } ?? Self.sharedSlots
    }

    private let queue: DispatchQueue = DispatchQueue(
        label: "com.argsment.NaiveFlow.DNSSyscallConcurrencyBridge",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // Shared by every resolver instance. No waiting queue: overload fails fast.

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        guard !Task.isCancelled else { return nil }
        guard slots.reserve(1) else { return nil }
        // A blocking libc call cannot be cancelled safely. Its slot remains held
        // until it really returns, even if the async caller has timed out.
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = body()
                self.slots.release(1)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Address lookup

    func resolveAddresses(_ host: String, family: DNSAddressFamily) async -> [String] {
        await run { Self.resolveAddressesBlocking(host, family: family) } ?? []
    }

    private static func resolveAddressesBlocking(_ host: String, family: DNSAddressFamily) -> [String] {
        var hints = addrinfo()
        guard IPv4Only.supportsHost(host) else { return [] }
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let res = result else { return [] }
        defer { freeaddrinfo(res) }

        var ipv4: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = res
        while let info = current {
            if info.pointee.ai_family == AF_INET {
                var address = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(nulTerminated: buffer)
                    if !ipv4.contains(ip) { ipv4.append(ip) }
                }
            }
            current = info.pointee.ai_next
        }
        return ipv4
    }

    // MARK: - Record query

    func queryFirstRecord(
        host: String,
        rrtype: UInt16,
        timeout: TimeInterval,
        accept: @escaping @Sendable (Data) -> Data?
    ) async -> (payload: Data, ttl: UInt32)? {
        await run { Self.queryFirstRecordBlocking(host: host, rrtype: rrtype, timeout: timeout, accept: accept) } ?? nil
    }
    
    private final class QueryResult {
        let rrtype: UInt16
        let accept: (Data) -> Data?
        var payload: Data?
        var ttl: UInt32 = 0
        var sawFinal = false
        var answered = false
        init(rrtype: UInt16, accept: @escaping (Data) -> Data?) {
            self.rrtype = rrtype
            self.accept = accept
        }
    }

    private static func queryFirstRecordBlocking(
        host: String,
        rrtype: UInt16,
        timeout: TimeInterval,
        accept: @escaping @Sendable (Data) -> Data?
    ) -> (payload: Data, ttl: UInt32)? {
        let result = QueryResult(rrtype: rrtype, accept: accept)
        
        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, rrtype, _, rdlen, rdata, ttl, context in
            guard let context else { return }
            let result = BridgeContext.unretained(context, as: QueryResult.self)
            if rrtype == result.rrtype || errorCode != kDNSServiceErr_NoError { result.sawFinal = true }
            if result.sawFinal, (flags & kDNSServiceFlagsMoreComing) == 0 { result.answered = true }
            guard errorCode == kDNSServiceErr_NoError,
                  rrtype == result.rrtype, let rdata, rdlen > 0
            else { return }
            guard result.payload == nil else { return }
            if let payload = result.accept(Data(bytes: rdata, count: Int(rdlen))) {
                result.payload = payload
                result.ttl = ttl
            }
        }

        var serviceRef: DNSServiceRef?
        let context = BridgeContext.passUnretained(result)
        let queryError = host.withCString { cHost in
            DNSServiceQueryRecord(
                &serviceRef,
                DNSServiceFlags(kDNSServiceFlagsReturnIntermediates),
                0,
                cHost,
                rrtype, UInt16(kDNSServiceClass_IN),
                callback,
                context
            )
        }
        guard queryError == kDNSServiceErr_NoError, let serviceRef else { return nil }
        defer { DNSServiceRefDeallocate(serviceRef) }

        let fd = DNSServiceRefSockFD(serviceRef)
        guard fd >= 0 else { return nil }

        let deadline = MonotonicClock.now + timeout
        while result.payload == nil, !result.answered {
            let remaining = deadline - MonotonicClock.now
            if remaining <= 0 { break }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(min(remaining * 1000, 60_000)))
            guard ready > 0, (pollDescriptor.revents & Int16(POLLIN)) != 0 else { break }
            if DNSServiceProcessResult(serviceRef) != kDNSServiceErr_NoError { break }
        }
        guard let payload = result.payload else { return nil }
        return (payload, result.ttl)
    }
}
