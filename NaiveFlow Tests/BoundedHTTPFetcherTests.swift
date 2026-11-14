//
//  BoundedHTTPFetcherTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

private func makeHTTPResponse(
    _ url: String,
    status: Int = 200,
    contentLength: Int64? = nil
) -> HTTPURLResponse {
    var headers: [String: String] = ["Content-Type": "text/plain"]
    if let contentLength { headers["Content-Length"] = String(contentLength) }
    return HTTPURLResponse(
        url: URL(string: url)!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

@Suite(.serialized)
struct BoundedHTTPFetcherTests {
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let url = URL(string: "https://example.com/set")!

    @Test func subscriptionHWIDHeadersAreExplicitAndIgnoreTheLegacyGlobalSwitch() async throws {
        let preferences = try #require(UserDefaults(suiteName: AWCore.Identifier.appGroupSuite))
        let key = "remnawaveHWIDEnabled"
        let original = preferences.object(forKey: key)
        preferences.set(true, forKey: key)
        defer {
            if let original { preferences.set(original, forKey: key) }
            else { preferences.removeObject(forKey: key) }
        }
        for enabled in [false, true, false] {
            let request = SubscriptionFetcher.request(url: url, remnawaveHWIDEnabled: enabled, hwid: "test-device")
            StubProtocol.handler = { request in
                #expect(request.value(forHTTPHeaderField: "x-hwid") == (enabled ? "test-device" : nil))
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "NaiveFlow")
                #expect(request.value(forHTTPHeaderField: "X-NaiveFlow-Format") == AJSONParser.formatHeaderValue)
                return (makeHTTPResponse("https://example.com/set"), Data("hello".utf8))
            }
            _ = try await BoundedHTTPFetcher.fetch(request, maxBytes: 64, session: session())
        }
        #expect(SubscriptionFetcher.request(url: url).value(forHTTPHeaderField: "x-hwid") == nil)
        StubProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "x-hwid") == nil)
            return (makeHTTPResponse("https://example.com/set"), Data("hello".utf8))
        }
        _ = try await BoundedHTTPFetcher.fetch(url, maxBytes: 64, session: session())
    }

    @Test func deviceHWIDIsPersistedWithoutAGlobalEnableSwitch() throws {
        let preferences = try #require(UserDefaults(suiteName: AWCore.Identifier.appGroupSuite))
        let key = "remnawaveHWID"
        let original = preferences.persistentDomain(forName: AWCore.Identifier.appGroupSuite)?[key]
        defer {
            if let original { preferences.set(original, forKey: key) }
            else { preferences.removeObject(forKey: key) }
        }
        preferences.removeObject(forKey: key)
        let first = AWCore.getRemnawaveHWID()
        #expect(!first.isEmpty)
        #expect(preferences.persistentDomain(forName: AWCore.Identifier.appGroupSuite)?[key] as? String == first)
        #expect(AWCore.getRemnawaveHWID() == first)
    }

    @Test func fetchesBodyUnderLimit() async throws {
        StubProtocol.handler = { _ in (makeHTTPResponse("https://example.com/set"), Data("hello".utf8)) }
        let (data, http) = try await BoundedHTTPFetcher.fetch(url, maxBytes: 64, session: session())
        #expect(http.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func streamingCapRejectsOversizedBodyWithoutContentLength() async throws {
        // No Content-Length header: the only protection is the running byte cap.
        StubProtocol.handler = { _ in (makeHTTPResponse("https://example.com/set"), Data(repeating: 0x61, count: 40)) }
        await #expect(throws: BoundedHTTPFetcher.Failure.self) {
            _ = try await BoundedHTTPFetcher.fetch(url, maxBytes: 16, session: session())
        }
    }

    @Test func declaredOverLimitContentLengthIsRejected() async throws {
        // A large declared length plus an over-limit body must be rejected.
        StubProtocol.handler = { _ in
            (makeHTTPResponse("https://example.com/set", contentLength: 1_000_000),
             Data(repeating: 0x62, count: 64))
        }
        await #expect(throws: BoundedHTTPFetcher.Failure.self) {
            _ = try await BoundedHTTPFetcher.fetch(url, maxBytes: 16, session: session())
        }
    }

    @Test func nonSuccessStatusIsPassedThroughToCaller() async throws {
        StubProtocol.handler = { _ in (makeHTTPResponse("https://example.com/set", status: 500), Data("err".utf8)) }
        let (_, http) = try await BoundedHTTPFetcher.fetch(url, maxBytes: 64, session: session())
        #expect(http.statusCode == 500)
    }
}
