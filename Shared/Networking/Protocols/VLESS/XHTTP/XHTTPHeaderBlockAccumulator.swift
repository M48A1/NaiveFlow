//
//  XHTTPHeaderBlockAccumulator.swift
//  NaiveFlow
//

import Foundation

/// Strips HEADERS-frame padding and the optional PRIORITY field so the block
/// reaches HPACK intact. Mirrors `GRPCConnection.headersPayload`, kept local to
/// XHTTP so the error wire stays `.xhttp`.
nonisolated func xhttpHeadersPayload(strippingPaddingFrom payload: Data, flags: UInt8) throws -> Data {
    var start = payload.startIndex
    var end = payload.endIndex

    if (flags & XHTTPConnection.h2FlagPadded) != 0 {
        guard let padLengthByte = payload.first else {
            throw NaiveFlowError.proxy(.xhttp, .protocolViolation(detail: "PADDED HEADERS frame with no pad length"))
        }
        start += 1
        end -= Int(padLengthByte)
    }

    if (flags & XHTTPConnection.h2FlagPriority) != 0 {
        // Exclusive flag + 31-bit stream dependency + 1-byte weight.
        start += 5
    }

    guard start <= end else {
        throw NaiveFlowError.proxy(.xhttp, .protocolViolation(detail: "HEADERS frame with malformed padding or priority field"))
    }
    return payload[start..<end]
}

/// Reassembles a HEADERS + CONTINUATION header block for XHTTP's H2 download
/// stream. The PADDED and PRIORITY flags are handled independently, and the
/// cumulative block is capped so a peer cannot grow it without bound.
nonisolated struct XHTTPHeaderBlockAccumulator: Sendable {
    private(set) var buffer = Data()
    private(set) var endStream = false

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
        if type == XHTTPConnection.h2FrameHeaders {
            let fragment = try xhttpHeadersPayload(strippingPaddingFrom: payload, flags: flags)
            guard fragment.count <= maxBlockSize else {
                throw NaiveFlowError.proxy(.xhttp, .protocolViolation(detail: "H2 header block exceeds \(maxBlockSize) bytes"))
            }
            buffer = fragment
            endStream = (flags & XHTTPConnection.h2FlagEndStream) != 0
        } else {
            guard buffer.count + payload.count <= maxBlockSize else {
                throw NaiveFlowError.proxy(.xhttp, .protocolViolation(detail: "H2 header block exceeds \(maxBlockSize) bytes"))
            }
            buffer.append(payload)
        }
        guard (flags & XHTTPConnection.h2FlagEndHeaders) != 0 else { return nil }
        let assembled = buffer
        let streamEnded = endStream
        buffer.removeAll(keepingCapacity: true)
        endStream = false
        return (assembled, streamEnded)
    }
}
