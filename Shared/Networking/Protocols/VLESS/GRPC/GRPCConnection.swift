//
//  GRPCConnection.swift
//  NaiveFlow
//
//  Created by NodePassProject on 4/23/26.
//

import Foundation
import Synchronization

nonisolated final class GRPCConnection: Sendable {

    // MARK: Transport

    private let transport: any ByteTransport

    // MARK: Configuration

    private let configuration: GRPCConfiguration
    private let authority: String

    // MARK: State

    enum Phase: PhaseTransitionable {
        case live
        case halfClosed
        case cancelled

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.live, .halfClosed):
                return true
            case (_, .cancelled):
                return old != .cancelled
            default:
                return false
            }
        }
    }

    private struct State: PhaseHolding {
        var phase: Phase = .live

        var h2ReadBuffer = Data()
        var grpcFrameBuffer = Data()
        var decodedBuffer = Data()

        var h2ResponseReceived = false

        var h2HeaderBlock = H2HeaderBlockAccumulator(maxBlockSize: GRPCConnection.maxH2HeaderBlockSize)
        var hpackDecoder = HPACKDecoder()

        var h2PeerConnectionWindow: Int = 65535
        var h2PeerStreamSendWindow: Int = 65535
        var h2PeerInitialWindowSize: Int = 65535

        var h2LocalWindowSize: Int = 4_194_304

        var h2MaxFrameSize: Int = 16384

        var h2ConnectionReceiveConsumed: Int = 0
        var h2StreamReceiveConsumed: Int = 0

        var h2FlowGate = H2FlowGate()

        var keepaliveDeadline: DeadlineToken?
        var pendingPingPayload: Data?
        var healthCheckDeadline: DeadlineToken?
        var nextPingSequence: UInt64 = 0
    }

    private let state: Mutex<State>

    private static let streamId: UInt32 = 1

    private static let maxH2ReadBufferSize = 2_097_152
    private static let maxGRPCFrameBufferSize = 16_777_216
    private static let maxH2HeaderBlockSize = 1_048_576

    var isConnected: Bool {
        state.withLock { $0.phase != .cancelled }
    }

    // MARK: - Initializers

    init(transport: any ByteTransport, configuration: GRPCConfiguration, authority: String) {
        self.configuration = configuration
        self.authority = authority
        self.transport = transport

        var initialState = State()
        if configuration.initialWindowsSize > 0 {
            initialState.h2LocalWindowSize = min(configuration.initialWindowsSize, 0x7FFF_FFFF)
        }
        self.state = Mutex(initialState)
    }

    convenience init(tlsConnection: TLSRecordConnection, configuration: GRPCConfiguration, authority: String) {
        self.init(transport: TLSByteTransport(tlsConnection), configuration: configuration, authority: authority)
    }

    convenience init(tunnel: ProxyConnection, configuration: GRPCConfiguration, authority: String) {
        self.init(transport: TunneledTransport(tunnel: tunnel), configuration: configuration, authority: authority)
    }

    // MARK: - Setup

    func performSetup() async throws {
        var initData = Data()

        initData.append(Self.h2Preface)

        var settingsPayload = Data()
        settingsPayload.append(contentsOf: [0x00, 0x02, 0x00, 0x00, 0x00, 0x00])
        let windowSize = UInt32(state.withLock { $0.h2LocalWindowSize })
        settingsPayload.append(contentsOf: [
            0x00, 0x04,
            UInt8((windowSize >> 24) & 0xFF), UInt8((windowSize >> 16) & 0xFF),
            UInt8((windowSize >> 8) & 0xFF), UInt8(windowSize & 0xFF),
        ])
        settingsPayload.append(contentsOf: [0x00, 0x06, 0x00, 0xA0, 0x00, 0x00])
        initData.append(buildH2Frame(type: Self.h2FrameSettings, flags: 0, streamId: 0, payload: settingsPayload))

        let connWindowInc = Self.h2ConnectionWindowSize
        var windowUpdatePayload = Data(count: 4)
        windowUpdatePayload[0] = UInt8((connWindowInc >> 24) & 0xFF)
        windowUpdatePayload[1] = UInt8((connWindowInc >> 16) & 0xFF)
        windowUpdatePayload[2] = UInt8((connWindowInc >> 8) & 0xFF)
        windowUpdatePayload[3] = UInt8(connWindowInc & 0xFF)
        initData.append(buildH2Frame(type: Self.h2FrameWindowUpdate, flags: 0, streamId: 0, payload: windowUpdatePayload))

        let headerBlock = try encodeGRPCRequestHeaders()
        initData.append(buildH2Frame(
            type: Self.h2FrameHeaders,
            flags: Self.h2FlagEndHeaders,
            streamId: Self.streamId,
            payload: headerBlock
        ))

        do {
            try await transport.send(initData)
        } catch {
            throw NaiveFlowError.capture(error, context: "gRPC preface/HEADERS write")
        }
        try await processInitialServerFrames()
    }

    private func processInitialServerFrames() async throws {
        while true {
            let frame: (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data)
            do {
                frame = try await readH2Frame()
            } catch {
                throw NaiveFlowError.capture(error, context: "gRPC SETTINGS read")
            }

            switch frame.type {
            case Self.h2FrameSettings:
                if frame.flags & Self.h2FlagAck == 0 {
                    parseH2Settings(frame.payload)
                    let ack = buildH2Frame(type: Self.h2FrameSettings, flags: Self.h2FlagAck, streamId: 0, payload: Data())
                    try? await transport.send(ack)
                    startKeepaliveIfNeeded()
                    return
                }
                continue

            case Self.h2FrameHeaders, Self.h2FrameContinuation:
                if frame.streamId == Self.streamId {
                    // Reassemble the full header block across HEADERS + any
                    // CONTINUATION frames before decoding :status / trailers.
                    let assembled = try assembleHeaderBlock(frame)
                    if let assembled {
                        if let rejection = checkH2ResponseStatus(assembled.block) {
                            throw NaiveFlowError.proxy(.grpc, .handshakeFailed(detail: "gRPC response rejected: \(rejection)"))
                        }
                        if assembled.endStream {
                            if let grpcError = parseGRPCTrailer(assembled.block) {
                                markClosed()
                                throw NaiveFlowError.proxy(.grpc, .handshakeFailed(detail: grpcError.localizedDescription))
                            }
                        }
                        state.withLock { $0.h2ResponseReceived = true }
                        startKeepaliveIfNeeded()
                        return
                    }
                    // HEADERS without END_HEADERS: wait for CONTINUATION.
                    continue
                }
                continue

            case Self.h2FrameWindowUpdate:
                handleWindowUpdate(frame: frame)
                continue

            case Self.h2FramePing:
                if frame.flags & Self.h2FlagAck != 0 {
                    acknowledgePing(frame.payload)
                } else {
                    let pong = buildH2Frame(type: Self.h2FramePing, flags: Self.h2FlagAck, streamId: 0, payload: frame.payload)
                    try? await transport.send(pong)
                }
                continue

            case Self.h2FrameGoaway:
                let reason = Self.describeGoawayPayload(frame.payload)
                throw NaiveFlowError.proxy(.grpc, .handshakeFailed(detail: "Server sent GOAWAY during setup (\(reason))"))

            case Self.h2FrameRstStream:
                if frame.streamId == Self.streamId {
                    let reason = Self.describeRstStreamPayload(frame.payload)
                    throw NaiveFlowError.proxy(.grpc, .handshakeFailed(detail: "Server reset the stream during setup (\(reason))"))
                }
                continue

            default:
                continue
            }
        }
    }

    /// Reassembles a HEADERS/CONTINUATION sequence into a complete header block.
    /// Marks the connection closed and rethrows when the block is malformed or
    /// exceeds the size cap, so a hostile peer cannot grow it without bound.
    private func assembleHeaderBlock(
        _ frame: (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data)
    ) throws -> (block: Data, endStream: Bool)? {
        do {
            return try state.withLock {
                try $0.h2HeaderBlock.ingest(type: frame.type, flags: frame.flags, payload: frame.payload)
            }
        } catch {
            markClosed()
            throw error
        }
    }

    // MARK: - Public send / receive

    func send(_ data: Data) async throws {
        let message = Self.encodeHunk(data)
        let framed = Self.wrapGRPCMessage(message)
        try await sendH2Data(framed)
    }

    func receive() async throws -> Data? {
        enum Ready { case data(Data); case eof; case read }
        let ready: Ready = state.withLock { state in
            if !state.decodedBuffer.isEmpty {
                let out = state.decodedBuffer
                state.decodedBuffer.removeAll(keepingCapacity: true)
                return .data(out)
            }
            if state.phase != .live { return .eof }
            return .read
        }
        switch ready {
        case .data(let out): return out
        case .eof: return nil
        case .read: return try await readAndDecode()
        }
    }

    // MARK: - Cancel

    func cancel() {
        let pending: (keepalive: DeadlineToken?, healthCheck: DeadlineToken?) = state.withLock { state in
            state.transition(to: .cancelled)
            state.h2ReadBuffer.removeAll()
            state.grpcFrameBuffer.removeAll()
            state.decodedBuffer.removeAll()
            let keepalive = state.keepaliveDeadline
            let healthCheck = state.healthCheckDeadline
            state.keepaliveDeadline = nil
            state.healthCheckDeadline = nil
            state.pendingPingPayload = nil
            state.h2FlowGate.wakeAll()
            return (keepalive, healthCheck)
        }
        pending.keepalive?.cancel()
        pending.healthCheck?.cancel()
        transport.cancel()
    }

    deinit {
        state.withLock {
            $0.keepaliveDeadline?.cancel()
            $0.healthCheckDeadline?.cancel()
        }
    }
}

// MARK: - HTTP/2 constants

nonisolated extension GRPCConnection {
    static let h2Preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    static let h2FrameHeaderSize = 9

    static let h2FrameData: UInt8 = 0x00
    static let h2FrameHeaders: UInt8 = 0x01
    static let h2FrameRstStream: UInt8 = 0x03
    static let h2FrameSettings: UInt8 = 0x04
    static let h2FramePing: UInt8 = 0x06
    static let h2FrameGoaway: UInt8 = 0x07
    static let h2FrameWindowUpdate: UInt8 = 0x08
    static let h2FrameContinuation: UInt8 = 0x09

    static let h2FlagEndStream: UInt8 = 0x01
    static let h2FlagEndHeaders: UInt8 = 0x04
    static let h2FlagAck: UInt8 = 0x01
    static let h2FlagPadded: UInt8 = 0x08
    static let h2FlagPriority: UInt8 = 0x20

    static let h2ConnectionWindowSize: UInt32 = 1_073_741_824 // 1 GB
}

/// Accumulates the header-block fragments of a single HTTP/2 stream until
/// END_HEADERS, so a HEADERS + CONTINUATION sequence is decoded as one block
/// instead of treating the first fragment as complete and dropping the rest.
nonisolated struct H2HeaderBlockAccumulator: Sendable {
    private(set) var buffer = Data()
    private(set) var endStream = false

    /// Cumulative cap on the reassembled header block. A single frame is already
    /// bounded by the read buffer, but CONTINUATION keeps appending across
    /// frames; without this the block would grow without bound and exhaust the
    /// network extension's memory.
    let maxBlockSize: Int

    init(maxBlockSize: Int) {
        self.maxBlockSize = maxBlockSize
    }

    /// Feeds one HEADERS or CONTINUATION frame. Returns the assembled block and
    /// the stream's END_STREAM flag once END_HEADERS is seen, otherwise `nil`.
    /// Throws when the reassembled block would exceed `maxBlockSize`.
    mutating func ingest(
        type: UInt8,
        flags: UInt8,
        payload: Data
    ) throws -> (block: Data, endStream: Bool)? {
        if type == GRPCConnection.h2FrameHeaders {
            // A HEADERS frame starts a new block (padding/priority stripped).
            let fragment = try GRPCConnection.headersPayload(strippingPaddingFrom: payload, flags: flags)
            guard fragment.count <= maxBlockSize else {
                throw NaiveFlowError.proxy(.grpc, .protocolViolation(
                    detail: "gRPC header block exceeds \(maxBlockSize) bytes"
                ))
            }
            buffer = fragment
            endStream = (flags & GRPCConnection.h2FlagEndStream) != 0
        } else {
            // CONTINUATION carries a raw fragment, no padding or priority.
            guard buffer.count + payload.count <= maxBlockSize else {
                throw NaiveFlowError.proxy(.grpc, .protocolViolation(
                    detail: "gRPC header block exceeds \(maxBlockSize) bytes"
                ))
            }
            buffer.append(payload)
        }
        guard (flags & GRPCConnection.h2FlagEndHeaders) != 0 else { return nil }
        let assembled = buffer
        let streamEnded = endStream
        buffer.removeAll(keepingCapacity: true)
        endStream = false
        return (assembled, streamEnded)
    }
}

// MARK: - Frame I/O

nonisolated extension GRPCConnection {
    fileprivate func buildH2Frame(type: UInt8, flags: UInt8, streamId: UInt32, payload: Data) -> Data {
        var frame = Data(capacity: Self.h2FrameHeaderSize + payload.count)
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(type)
        frame.append(flags)
        let sid = streamId & 0x7FFFFFFF
        frame.append(UInt8((sid >> 24) & 0xFF))
        frame.append(UInt8((sid >> 16) & 0xFF))
        frame.append(UInt8((sid >> 8) & 0xFF))
        frame.append(UInt8(sid & 0xFF))
        frame.append(payload)
        return frame
    }

    private func parseH2Frame(_ state: inout State) -> (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data)? {
        guard state.h2ReadBuffer.count >= Self.h2FrameHeaderSize else { return nil }

        let buffer = state.h2ReadBuffer
        let length = (UInt32(buffer[buffer.startIndex]) << 16)
            | (UInt32(buffer[buffer.startIndex + 1]) << 8)
            | UInt32(buffer[buffer.startIndex + 2])
        let type = buffer[buffer.startIndex + 3]
        let flags = buffer[buffer.startIndex + 4]
        let streamId = (UInt32(buffer[buffer.startIndex + 5]) << 24)
            | (UInt32(buffer[buffer.startIndex + 6]) << 16)
            | (UInt32(buffer[buffer.startIndex + 7]) << 8)
            | UInt32(buffer[buffer.startIndex + 8])
        let sid = streamId & 0x7FFFFFFF

        let totalSize = Self.h2FrameHeaderSize + Int(length)
        guard state.h2ReadBuffer.count >= totalSize else { return nil }

        let payload = state.h2ReadBuffer.subdata(
            in: state.h2ReadBuffer.startIndex + Self.h2FrameHeaderSize ..< state.h2ReadBuffer.startIndex + totalSize
        )
        state.h2ReadBuffer.removeFirst(totalSize)
        if state.h2ReadBuffer.isEmpty {
            state.h2ReadBuffer = Data()
        } else {
            state.h2ReadBuffer = Data(state.h2ReadBuffer)
        }

        return (type, flags, sid, payload)
    }

    fileprivate func readH2Frame() async throws -> (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data) {
        while true {
            if let frame = state.withLock({ parseH2Frame(&$0) }) {
                return frame
            }

            let chunk = try await transport.receive()
            guard case .bytes(let data) = chunk, !data.isEmpty else {
                throw NaiveFlowError.proxy(.grpc, .streamClosed)
            }

            let overflow: Bool = state.withLock { state in
                state.h2ReadBuffer.append(data)
                if state.h2ReadBuffer.count > Self.maxH2ReadBufferSize {
                    state.h2ReadBuffer.removeAll()
                    return true
                }
                return false
            }
            if overflow {
                throw NaiveFlowError.proxy(.grpc, .connectionClosed(detail: nil))
            }
        }
    }

    fileprivate func parseH2Settings(_ payload: Data) {
        var offset = payload.startIndex
        while offset + 6 <= payload.endIndex {
            let id = (UInt16(payload[offset]) << 8) | UInt16(payload[offset + 1])
            let value = (UInt32(payload[offset + 2]) << 24)
                | (UInt32(payload[offset + 3]) << 16)
                | (UInt32(payload[offset + 4]) << 8)
                | UInt32(payload[offset + 5])
            offset += 6

            switch id {
            case 0x04:
                state.withLock { state in
                    let delta = Int(value) - state.h2PeerInitialWindowSize
                    state.h2PeerInitialWindowSize = Int(value)
                    state.h2PeerStreamSendWindow += delta
                }
            case 0x05:
                state.withLock { $0.h2MaxFrameSize = min(max(Int(value), 16_384), 16_777_215) }
            default:
                break
            }
        }
    }

    fileprivate func handleWindowUpdate(frame: (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data)) {
        state.withLock { state in
            if frame.payload.count >= 4 {
                let raw = H2Framing.readUInt32(frame.payload)
                let increment = Int(raw & 0x7FFFFFFF)
                if frame.streamId == 0 {
                    state.h2PeerConnectionWindow += increment
                } else if frame.streamId == Self.streamId {
                    state.h2PeerStreamSendWindow += increment
                }
            }
            state.h2FlowGate.wakeAll()
        }
    }
}

// MARK: - HPACK encoding for request HEADERS

nonisolated extension GRPCConnection {
    fileprivate func encodeGRPCRequestHeaders() throws -> Data {
        var block = Data()

        var authBytes = Self.hpackEncodeInteger(1, prefixBits: 6)
        authBytes[0] |= 0x40
        block.append(contentsOf: authBytes)
        block.append(contentsOf: Self.hpackEncodeString(authority))

        block.append(0x83)

        let path = try configuration.resolvedPath()
        var pathBytes = Self.hpackEncodeInteger(4, prefixBits: 6)
        pathBytes[0] |= 0x40
        block.append(contentsOf: pathBytes)
        block.append(contentsOf: Self.hpackEncodeString(path))

        block.append(0x87)

        var ctBytes = Self.hpackEncodeInteger(31, prefixBits: 6)
        ctBytes[0] |= 0x40
        block.append(contentsOf: ctBytes)
        block.append(contentsOf: Self.hpackEncodeString("application/grpc"))

        block.append(0x40)
        block.append(contentsOf: Self.hpackEncodeString("te"))
        block.append(contentsOf: Self.hpackEncodeString("trailers"))

        block.append(0x40)
        block.append(contentsOf: Self.hpackEncodeString("grpc-encoding"))
        block.append(contentsOf: Self.hpackEncodeString("identity"))

        block.append(0x40)
        block.append(contentsOf: Self.hpackEncodeString("grpc-accept-encoding"))
        block.append(contentsOf: Self.hpackEncodeString("identity"))

        let ua = configuration.userAgent.isEmpty ? ProxyUserAgent.default : configuration.userAgent
        var uaBytes = Self.hpackEncodeInteger(58, prefixBits: 6)
        uaBytes[0] |= 0x40
        block.append(contentsOf: uaBytes)
        block.append(contentsOf: Self.hpackEncodeString(ua))

        return block
    }

    fileprivate static func hpackEncodeInteger(_ value: Int, prefixBits: Int) -> [UInt8] {
        let maxPrefix = (1 << prefixBits) - 1
        if value < maxPrefix {
            return [UInt8(value)]
        }
        var bytes: [UInt8] = [UInt8(maxPrefix)]
        var remaining = value - maxPrefix
        while remaining >= 128 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    fileprivate static func hpackEncodeString(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        var result = hpackEncodeInteger(bytes.count, prefixBits: 7)
        result[0] &= 0x7F
        result.append(contentsOf: bytes)
        return result
    }
}

// MARK: - HPACK decoding for response :status

nonisolated extension GRPCConnection {
    /// Decodes the response header block with the connection-level HPACK decoder
    /// and returns `nil` for a 200 status, otherwise a human-readable reason.
    /// Using `HPACKDecoder` accepts every legal HPACK representation of `:status`
    /// (indexed, literal name/value, Huffman), not just static-table name indices.
    fileprivate func checkH2ResponseStatus(_ headerBlock: Data) -> String? {
        guard let decoded = state.withLock({ $0.hpackDecoder.decodeHeaders(from: headerBlock) }) else {
            return "undecodable HPACK header block"
        }
        guard let status = decoded.fields.first(where: { $0.name == ":status" })?.value else {
            return "missing :status header"
        }
        return status == "200" ? nil : "status \(status)"
    }
}

// MARK: - gRPC / protobuf framing

nonisolated extension GRPCConnection {
    fileprivate static func encodeHunk(_ data: Data) -> Data {
        var out = Data(capacity: 1 + 10 + data.count)
        out.append(0x0A) // (field 1 << 3) | wire type 2 (length-delimited)
        out.append(varintEncode(UInt64(data.count)))
        out.append(data)
        return out
    }

    fileprivate static func wrapGRPCMessage(_ message: Data) -> Data {
        var out = Data(capacity: 5 + message.count)
        out.append(0x00)
        let length = UInt32(message.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(message)
        return out
    }

    private static func varintEncode(_ value: UInt64) -> Data {
        var out = Data()
        var v = value
        while v >= 0x80 {
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    fileprivate static func varintDecode(_ data: Data, at startOffset: Int) -> (value: UInt64, consumed: Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var offset = startOffset
        while offset < data.count {
            let b = data[data.startIndex + offset]
            value |= UInt64(b & 0x7F) << shift
            offset += 1
            if b & 0x80 == 0 {
                return (value, offset - startOffset)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    fileprivate static func decodeHunkPayload(_ message: Data) throws -> Data {
        var out = Data()
        var offset = 0
        while offset < message.count {
            guard let (tag, tagConsumed) = varintDecode(message, at: offset) else {
                throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "truncated protobuf tag"))
            }
            offset += tagConsumed
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch wireType {
            case 2:
                guard let (length, lenConsumed) = varintDecode(message, at: offset) else {
                    throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "truncated protobuf length"))
                }
                offset += lenConsumed
                guard length <= UInt64(message.count - offset) else {
                    throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "truncated protobuf value"))
                }
                let lenInt = Int(length)
                if fieldNumber == 1 {
                    out.append(message.subdata(in: message.startIndex + offset ..< message.startIndex + offset + lenInt))
                }
                offset += lenInt
            case 0:
                guard let (_, vConsumed) = varintDecode(message, at: offset) else {
                    throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "truncated varint field"))
                }
                offset += vConsumed
            case 5:
                guard offset + 4 <= message.count else {
                    throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "truncated fixed32 field"))
                }
                offset += 4
            case 1:
                guard offset + 8 <= message.count else {
                    throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "truncated fixed64 field"))
                }
                offset += 8
            default:
                throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "unknown protobuf wire type \(wireType)"))
            }
        }
        return out
    }
}

// MARK: - HTTP/2 DATA send

nonisolated extension GRPCConnection {
    fileprivate func sendH2Data(_ data: Data) async throws {
        enum BuildStep {
            case closed
            case park
            case built(frames: Data, nextOffset: Int)
        }

        var offset = 0
        while offset < data.count {
            let step: BuildStep = state.withLock { state in
                if state.phase != .live { return .closed }
                let maxSize = state.h2MaxFrameSize
                let window = min(state.h2PeerConnectionWindow, state.h2PeerStreamSendWindow)
                guard window > 0 else { return .park }

                var frames = Data()
                var currentOffset = offset
                var windowRemaining = window
                while currentOffset < data.count {
                    let remaining = data.count - currentOffset
                    let chunkSize = min(remaining, min(maxSize, windowRemaining))
                    guard chunkSize > 0 else { break }

                    let chunk = Data(data[data.startIndex + currentOffset ..< data.startIndex + currentOffset + chunkSize])
                    frames.append(buildH2Frame(type: Self.h2FrameData, flags: 0, streamId: Self.streamId, payload: chunk))
                    currentOffset += chunkSize
                    windowRemaining -= chunkSize
                }
                let totalSent = window - windowRemaining
                state.h2PeerConnectionWindow -= totalSent
                state.h2PeerStreamSendWindow -= totalSent
                return .built(frames: frames, nextOffset: currentOffset)
            }

            switch step {
            case .closed:
                throw NaiveFlowError.proxy(.grpc, .connectionClosed(detail: nil))
            case .park:
                await parkForFlowWindow()
                try Task.checkCancellation()
            case .built(let frames, let nextOffset):
                do {
                    try await transport.send(frames)
                } catch {
                    markClosed()
                    throw error
                }
                offset = nextOffset
            }
        }
    }

    private func parkForFlowWindow() async {
        await H2FlowGate.park {
            state.withLock { state -> AsyncStream<Never>? in
                if state.phase != .live { return nil }
                if min(state.h2PeerConnectionWindow, state.h2PeerStreamSendWindow) > 0 { return nil }
                return state.h2FlowGate.enroll()
            }
        }
    }

    private func markClosed() {
        state.withLock { state in
            state.transition(to: .halfClosed)
            state.h2FlowGate.wakeAll()
        }
    }

    private func drainFlowResumptions() {
        state.withLock { $0.h2FlowGate.wakeAll() }
    }
}

// MARK: - Receive pipeline

nonisolated extension GRPCConnection {
    private enum FrameOutcome {
        case deliver(Data?)
        case keepReading
    }

    fileprivate func readAndDecode() async throws -> Data? {
        while true {
            let frame: (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data)
            do {
                frame = try await readH2Frame()
            } catch {
                if case NaiveFlowError.proxy(.grpc, .streamClosed) = error {
                    let leftover: Data = state.withLock { state in
                        state.transition(to: .halfClosed)
                        let leftover = state.decodedBuffer
                        state.decodedBuffer.removeAll(keepingCapacity: true)
                        return leftover
                    }
                    drainFlowResumptions()
                    return leftover.isEmpty ? nil : leftover
                }
                throw error
            }

            let isOurStream = frame.streamId == Self.streamId
            let outcome: FrameOutcome

            switch frame.type {
            case Self.h2FrameData:
                outcome = try await handleDataFrame(frame: frame, isOurStream: isOurStream)

            case Self.h2FrameHeaders, Self.h2FrameContinuation:
                if isOurStream {
                    // Reassemble across HEADERS + CONTINUATION before decoding.
                    let assembled = try assembleHeaderBlock(frame)
                    if let assembled {
                        try markResponseReceivedIfNeeded(assembled.block)
                        outcome = assembled.endStream
                            ? try finishStreamAfterTrailer(assembled.block)
                            : .keepReading
                    } else {
                        outcome = .keepReading
                    }
                } else {
                    outcome = .keepReading
                }

            case Self.h2FrameSettings:
                if frame.flags & Self.h2FlagAck == 0 {
                    parseH2Settings(frame.payload)
                    let ack = buildH2Frame(type: Self.h2FrameSettings, flags: Self.h2FlagAck, streamId: 0, payload: Data())
                    try? await transport.send(ack)
                }
                outcome = .keepReading

            case Self.h2FrameWindowUpdate:
                handleWindowUpdate(frame: frame)
                outcome = .keepReading

            case Self.h2FramePing:
                if frame.flags & Self.h2FlagAck != 0 {
                    acknowledgePing(frame.payload)
                } else {
                    let pong = buildH2Frame(type: Self.h2FramePing, flags: Self.h2FlagAck, streamId: 0, payload: frame.payload)
                    try? await transport.send(pong)
                }
                outcome = .keepReading

            case Self.h2FrameGoaway:
                let leftover: Data = state.withLock { state in
                    state.transition(to: .halfClosed)
                    let leftover = state.decodedBuffer
                    state.decodedBuffer.removeAll(keepingCapacity: true)
                    return leftover
                }
                drainFlowResumptions()
                outcome = .deliver(leftover.isEmpty ? nil : leftover)

            case Self.h2FrameRstStream:
                if isOurStream {
                    let leftover: Data = state.withLock { state in
                        state.transition(to: .halfClosed)
                        let leftover = state.decodedBuffer
                        state.decodedBuffer.removeAll(keepingCapacity: true)
                        return leftover
                    }
                    drainFlowResumptions()
                    outcome = .deliver(leftover.isEmpty ? nil : leftover)
                } else {
                    outcome = .keepReading
                }

            default:
                outcome = .keepReading
            }

            switch outcome {
            case .deliver(let payload): return payload
            case .keepReading: continue
            }
        }
    }

    private func markResponseReceivedIfNeeded(_ payload: Data) throws {
        if state.withLock({ $0.h2ResponseReceived }) { return }

        if let rejection = checkH2ResponseStatus(payload) {
            markClosed()
            throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "gRPC response rejected: \(rejection)"))
        }
        state.withLock { $0.h2ResponseReceived = true }
    }

    /// Finalizes the stream once a trailers block arrives: parses grpc-status,
    /// transitions to half-closed, and returns any buffered decoded data (or a
    /// `nil` delivery when the stream is empty).
    private func finishStreamAfterTrailer(_ block: Data) throws -> FrameOutcome {
        let grpcError = parseGRPCTrailer(block)
        let leftover: Data = state.withLock { state in
            state.transition(to: .halfClosed)
            let leftover = state.decodedBuffer
            state.decodedBuffer.removeAll(keepingCapacity: true)
            return leftover
        }
        drainFlowResumptions()
        if let grpcError { throw grpcError }
        return .deliver(leftover.isEmpty ? nil : leftover)
    }

    /// Removes DATA-frame padding (PADDED flag: 1-byte pad length, then data,
    /// then pad bytes). Flow control still counts the raw frame elsewhere.
    static func dataPayload(strippingPaddingFrom payload: Data, flags: UInt8) throws -> Data {
        guard (flags & h2FlagPadded) != 0 else { return payload }
        guard let padLengthByte = payload.first, payload.count >= 1 + Int(padLengthByte) else {
            throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "PADDED DATA frame with malformed padding"))
        }
        return payload.dropFirst(1).dropLast(Int(padLengthByte))
    }

    /// Removes the HEADERS-frame prefix fields so the header block reaches HPACK
    /// decoding intact. A HEADERS payload is:
    /// `[1-byte pad length][optional 5-byte priority field][header block][pad bytes]`.
    ///
    /// The PADDED and PRIORITY flags are independent: either can appear alone. An
    /// early return on `!PADDED` would leave the 5-byte priority field in front of
    /// the block, so a legal `:status 200` would be misread as an unknown
    /// `:status` header.
    static func headersPayload(strippingPaddingFrom payload: Data, flags: UInt8) throws -> Data {
        var start = payload.startIndex
        var end = payload.endIndex

        if (flags & h2FlagPadded) != 0 {
            guard let padLengthByte = payload.first else {
                throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "PADDED HEADERS frame with no pad length"))
            }
            start += 1
            end -= Int(padLengthByte)
        }

        if (flags & h2FlagPriority) != 0 {
            // Exclusive flag + 31-bit stream dependency + 1-byte weight.
            start += 5
        }

        guard start <= end else {
            throw NaiveFlowError.proxy(.grpc, .protocolViolation(
                detail: "HEADERS frame with malformed padding or priority field"
            ))
        }
        return payload[start..<end]
    }

    private func handleDataFrame(
        frame: (type: UInt8, flags: UInt8, streamId: UInt32, payload: Data),
        isOurStream: Bool
    ) async throws -> FrameOutcome {
        let endOfStream = (frame.flags & Self.h2FlagEndStream) != 0

        await emitWindowUpdatesIfNeeded(receivedBytes: frame.payload.count, onOurStream: isOurStream)

        guard isOurStream else { return .keepReading }

        let dataPayload = try Self.dataPayload(strippingPaddingFrom: frame.payload, flags: frame.flags)

        enum DecodeResult {
            case overflow
            case parsed(decoded: Data, streamClosed: Bool, decodeError: Error?)
        }

        let result: DecodeResult = state.withLock { state in
            if !dataPayload.isEmpty {
                state.grpcFrameBuffer.append(dataPayload)
                if state.grpcFrameBuffer.count > Self.maxGRPCFrameBufferSize {
                    state.grpcFrameBuffer.removeAll()
                    return .overflow
                }
            }

            var decoded = Data()
            var decodeError: Error?

            while state.grpcFrameBuffer.count >= 5 {
                let compressed = state.grpcFrameBuffer[state.grpcFrameBuffer.startIndex]
                let length = (UInt32(state.grpcFrameBuffer[state.grpcFrameBuffer.startIndex + 1]) << 24)
                    | (UInt32(state.grpcFrameBuffer[state.grpcFrameBuffer.startIndex + 2]) << 16)
                    | (UInt32(state.grpcFrameBuffer[state.grpcFrameBuffer.startIndex + 3]) << 8)
                    | UInt32(state.grpcFrameBuffer[state.grpcFrameBuffer.startIndex + 4])
                let total = 5 + Int(length)
                guard state.grpcFrameBuffer.count >= total else { break }

                let messageData = state.grpcFrameBuffer.subdata(
                    in: state.grpcFrameBuffer.startIndex + 5 ..< state.grpcFrameBuffer.startIndex + total
                )
                state.grpcFrameBuffer.removeFirst(total)
                if state.grpcFrameBuffer.isEmpty {
                    state.grpcFrameBuffer = Data()
                } else {
                    state.grpcFrameBuffer = Data(state.grpcFrameBuffer)
                }

                if compressed != 0 {
                    decodeError = NaiveFlowError.proxy(.grpc, .unsupported(feature: "compressed messages"))
                    break
                }
                do {
                    let payload = try Self.decodeHunkPayload(messageData)
                    if !payload.isEmpty {
                        decoded.append(payload)
                    }
                } catch {
                    decodeError = error
                    break
                }
            }

            var streamClosed = false
            if endOfStream {
                state.transition(to: .halfClosed)
                streamClosed = true
            }
            return .parsed(decoded: decoded, streamClosed: streamClosed, decodeError: decodeError)
        }
        if endOfStream { drainFlowResumptions() }

        switch result {
        case .overflow:
            throw NaiveFlowError.proxy(.grpc, .protocolViolation(detail: "gRPC frame buffer overflow"))
        case .parsed(let decoded, let streamClosed, let decodeError):
            if let decodeError { throw decodeError }
            if decoded.isEmpty {
                return streamClosed ? .deliver(nil) : .keepReading
            }
            return .deliver(decoded)
        }
    }

    private func emitWindowUpdatesIfNeeded(receivedBytes: Int, onOurStream: Bool) async {
        guard receivedBytes > 0 else { return }

        let updates: Data? = state.withLock { state in
            state.h2ConnectionReceiveConsumed += receivedBytes
            if onOurStream {
                state.h2StreamReceiveConsumed += receivedBytes
            }
            let windowSize = state.h2LocalWindowSize
            let threshold = windowSize / 2
            let connConsumed = state.h2ConnectionReceiveConsumed
            let streamConsumed = state.h2StreamReceiveConsumed
            if connConsumed >= threshold { state.h2ConnectionReceiveConsumed = 0 }
            if onOurStream, streamConsumed >= threshold { state.h2StreamReceiveConsumed = 0 }

            var updates = Data()
            if connConsumed >= threshold {
                let increment = UInt32(connConsumed)
                var payload = Data(count: 4)
                payload[0] = UInt8((increment >> 24) & 0xFF); payload[1] = UInt8((increment >> 16) & 0xFF)
                payload[2] = UInt8((increment >> 8) & 0xFF); payload[3] = UInt8(increment & 0xFF)
                updates.append(buildH2Frame(type: Self.h2FrameWindowUpdate, flags: 0, streamId: 0, payload: payload))
            }
            if onOurStream, streamConsumed >= threshold {
                let increment = UInt32(streamConsumed)
                var payload = Data(count: 4)
                payload[0] = UInt8((increment >> 24) & 0xFF); payload[1] = UInt8((increment >> 16) & 0xFF)
                payload[2] = UInt8((increment >> 8) & 0xFF); payload[3] = UInt8(increment & 0xFF)
                updates.append(buildH2Frame(type: Self.h2FrameWindowUpdate, flags: 0, streamId: Self.streamId, payload: payload))
            }
            return updates.isEmpty ? nil : updates
        }

        if let updates {
            try? await transport.send(updates)
        }
    }
}

// MARK: - Keepalive

nonisolated extension GRPCConnection {
    /// Keepalive ping ACK timeout in seconds when `healthCheckTimeout` is unset.
    private static let defaultHealthCheckTimeout = 20

    fileprivate func startKeepaliveIfNeeded() {
        let interval = configuration.idleTimeout
        guard interval > 0 else { return }

        state.withLock { state in
            guard state.phase == .live, state.keepaliveDeadline == nil else { return }
            state.keepaliveDeadline = scheduleKeepalive(after: interval)
        }
    }

    private func scheduleKeepalive(after interval: Int) -> DeadlineToken {
        TickScheduler.shared.schedule(in: .seconds(interval), precision: .relaxed) { [weak self] in
            guard let self else { return }
            Task { await self.keepaliveFired(interval: interval) }
        }
    }

    private func keepaliveFired(interval: Int) async {
        guard state.withLock({ $0.phase == .live }) else { return }
        await sendKeepalivePing()
        state.withLock { state in
            guard state.phase == .live, state.keepaliveDeadline != nil else { return }
            state.keepaliveDeadline = scheduleKeepalive(after: interval)
        }
    }

    private func sendKeepalivePing() async {
        if state.withLock({ $0.phase != .live }) { return }
        // A unique payload per ping disambiguates ACKs and health-check rounds:
        // a stale timer from a previous round can no longer match a new round's
        // pending ping (they all used to share the same 8 zero bytes).
        let payload = state.withLock { state -> Data in
            let sequence = state.nextPingSequence
            state.nextPingSequence &+= 1
            var value = sequence.bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        let ping = buildH2Frame(type: Self.h2FramePing, flags: 0, streamId: 0, payload: payload)

        // Register the pending ping *before* sending: a fast ACK can arrive while
        // `transport.send` is in flight, and it would be dropped if the pending
        // payload were not yet recorded, later tearing down a healthy connection.
        armHealthCheck(payload)

        do {
            try await transport.send(ping)
        } catch {
            disarmHealthCheck(payload)
            return // the read path will surface the failure
        }
    }

    /// Clears a pending keepalive ping whose send failed, so its armed deadline
    /// does not later fire and close the connection.
    private func disarmHealthCheck(_ payload: Data) {
        state.withLock { state in
            guard state.pendingPingPayload == payload else { return }
            state.pendingPingPayload = nil
            state.healthCheckDeadline?.cancel()
            state.healthCheckDeadline = nil
        }
    }

    /// Arms the ACK timeout for a just-sent keepalive ping. If the peer does not
    /// PING-ACK within `healthCheckTimeout` (default 20s), the connection is
    /// treated as dead and torn down.
    ///
    /// Only the first unacknowledged ping arms the deadline; subsequent pings
    /// must not reset it, otherwise an interval shorter than the timeout would
    /// keep postponing the health check forever (a dead peer would never be
    /// detected).
    private func armHealthCheck(_ payload: Data) {
        let firstOutstanding = state.withLock { state -> Bool in
            if state.pendingPingPayload != nil { return false }
            state.pendingPingPayload = payload
            return true
        }
        guard firstOutstanding else { return }

        let configured = configuration.healthCheckTimeout
        let timeout = configured > 0 ? configured : Self.defaultHealthCheckTimeout
        let deadline = TickScheduler.shared.schedule(in: .seconds(timeout), precision: .relaxed) { [weak self] in
            guard let self else { return }
            Task { await self.healthCheckFired(payload: payload) }
        }
        let adopted = state.withLock { state -> Bool in
            if state.pendingPingPayload == payload {
                state.healthCheckDeadline = deadline
                return true
            }
            return false
        }
        if !adopted {
            // An ACK raced in and cleared the pending ping before we stored the
            // deadline; cancel the now-orphaned timer so it cannot fire and hit a
            // later round's pending state.
            deadline.cancel()
        }
    }

    /// Clears the outstanding keepalive ping when the peer ACKs it, proving the
    /// connection is alive.
    private func acknowledgePing(_ payload: Data) {
        state.withLock { state in
            guard state.pendingPingPayload == payload else { return }
            state.pendingPingPayload = nil
            state.healthCheckDeadline?.cancel()
            state.healthCheckDeadline = nil
        }
    }

    /// Fires when a keepalive ping was never ACKed: the peer is unresponsive, so
    /// close the stream and tear down the transport.
    private func healthCheckFired(payload: Data) async {
        let stale: Bool = state.withLock { state in
            guard state.phase == .live else { return false }
            guard state.pendingPingPayload == payload else { return false }
            state.pendingPingPayload = nil
            state.healthCheckDeadline = nil
            return true
        }
        guard stale else { return }
        markClosed()
        transport.cancel()
    }
}

// MARK: - Error-code descriptions

nonisolated extension GRPCConnection {
    fileprivate static func h2ErrorCodeName(_ code: UInt32) -> String {
        switch code {
        case 0x00: return "NO_ERROR"
        case 0x01: return "PROTOCOL_ERROR"
        case 0x02: return "INTERNAL_ERROR"
        case 0x03: return "FLOW_CONTROL_ERROR"
        case 0x04: return "SETTINGS_TIMEOUT"
        case 0x05: return "STREAM_CLOSED"
        case 0x06: return "FRAME_SIZE_ERROR"
        case 0x07: return "REFUSED_STREAM"
        case 0x08: return "CANCEL"
        case 0x09: return "COMPRESSION_ERROR"
        case 0x0A: return "CONNECT_ERROR"
        case 0x0B: return "ENHANCE_YOUR_CALM"
        case 0x0C: return "INADEQUATE_SECURITY"
        case 0x0D: return "HTTP_1_1_REQUIRED"
        default:   return "UNKNOWN(\(code))"
        }
    }

    fileprivate static func describeGoawayPayload(_ payload: Data) -> String {
        guard payload.count >= 8 else { return "truncated GOAWAY payload" }
        let base = payload.startIndex
        let lastStreamId = (UInt32(payload[base]) << 24)
            | (UInt32(payload[base + 1]) << 16)
            | (UInt32(payload[base + 2]) << 8)
            | UInt32(payload[base + 3])
        let errorCode = (UInt32(payload[base + 4]) << 24)
            | (UInt32(payload[base + 5]) << 16)
            | (UInt32(payload[base + 6]) << 8)
            | UInt32(payload[base + 7])
        let name = h2ErrorCodeName(errorCode)
        let debug: String
        if payload.count > 8, let ascii = String(data: payload.subdata(in: base + 8 ..< payload.endIndex), encoding: .utf8) {
            debug = ", debug=\(ascii)"
        } else {
            debug = ""
        }
        return "\(name), lastStreamId=\(lastStreamId & 0x7FFFFFFF)\(debug)"
    }

    fileprivate static func describeRstStreamPayload(_ payload: Data) -> String {
        guard payload.count >= 4 else { return "truncated RST_STREAM payload" }
        let base = payload.startIndex
        let errorCode = (UInt32(payload[base]) << 24)
            | (UInt32(payload[base + 1]) << 16)
            | (UInt32(payload[base + 2]) << 8)
            | UInt32(payload[base + 3])
        return h2ErrorCodeName(errorCode)
    }
}

// MARK: - gRPC trailer parsing

nonisolated extension GRPCConnection {
    fileprivate func parseGRPCTrailer(_ payload: Data) -> NaiveFlowError? {
        guard let decoded = state.withLock({ $0.hpackDecoder.decodeHeaders(from: payload) }) else {
            return nil
        }
        var headers: [String: String] = [:]
        for field in decoded.fields {
            headers[field.name.lowercased()] = field.value
        }
        guard let statusStr = headers["grpc-status"], let status = Int(statusStr), status != 0 else {
            return nil
        }
        let message = headers["grpc-message"]
        return .proxy(.grpc, .rpcFailed(status: status, method: Self.grpcStatusName(status), message: message))
    }

    fileprivate static func grpcStatusName(_ code: Int) -> String {
        switch code {
        case 0:  return "OK"
        case 1:  return "CANCELLED"
        case 2:  return "UNKNOWN"
        case 3:  return "INVALID_ARGUMENT"
        case 4:  return "DEADLINE_EXCEEDED"
        case 5:  return "NOT_FOUND"
        case 6:  return "ALREADY_EXISTS"
        case 7:  return "PERMISSION_DENIED"
        case 8:  return "RESOURCE_EXHAUSTED"
        case 9:  return "FAILED_PRECONDITION"
        case 10: return "ABORTED"
        case 11: return "OUT_OF_RANGE"
        case 12: return "UNIMPLEMENTED"
        case 13: return "INTERNAL"
        case 14: return "UNAVAILABLE"
        case 15: return "DATA_LOSS"
        case 16: return "UNAUTHENTICATED"
        default: return "UNKNOWN(\(code))"
        }
    }

}
