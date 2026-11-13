//
//  RequestHardeningTests.swift
//  Networking
//

import XCTest
@testable import AnvyxNetworkKit

/// Records the last request it was asked to send.
private actor RecordingTransport: HTTPTransport {
    private(set) var last: URLRequest?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        last = request
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class RequestHardeningTests: XCTestCase {
    private let base = URL(string: "https://example.com")!

    // MARK: Header injection

    func testControlCharactersAreStrippedFromHeaders() async throws {
        let transport = RecordingTransport()
        let client = APIClient(
            baseURL: base, transport: transport,
            defaultHeaders: ["X-Default": "a\r\nX-Injected: 1"],
            adapters: [BearerTokenAdapter { "tok\n" }])
        await client.setHeader("b\r\nX-Injected: 2", for: "X-Set\r\n")
        try await client.send(Endpoint<EmptyResponse>(path: "x", headers: ["X-Endpoint": "c\u{0}\rd\te"]))

        let sent = await transport.last
        let headers = try XCTUnwrap(sent?.allHTTPHeaderFields)
        XCTAssertEqual(headers["X-Default"], "aX-Injected: 1")
        XCTAssertEqual(headers["X-Set"], "bX-Injected: 2")
        XCTAssertEqual(headers["X-Endpoint"], "cd\te")
        XCTAssertEqual(headers["Authorization"], "Bearer tok")
        XCTAssertNil(headers["X-Injected"])
        for (name, value) in headers {
            XCTAssertNil((name + value).rangeOfCharacter(from: .newlines), "\(name)")
        }
    }

    func testHeaderSanitizer() {
        XCTAssertEqual(HeaderSanitizer.name("X-Na me:\r\n"), "X-Name")
        XCTAssertEqual(HeaderSanitizer.name("\r\n"), "")
        XCTAssertEqual(HeaderSanitizer.value("plain value; q=0.5"), "plain value; q=0.5")
        XCTAssertEqual(HeaderSanitizer.value("a\u{7F}b\u{2028}c"), "abc")
    }

    // MARK: Timeout / session

    func testEndpointTimeoutSetsRequestTimeout() async throws {
        let transport = RecordingTransport()
        let client = APIClient(baseURL: base, transport: transport)
        try await client.send(Endpoint<EmptyResponse>(path: "x").timeout(7))
        let custom = await transport.last?.timeoutInterval
        XCTAssertEqual(custom, 7)

        try await client.send(Endpoint<EmptyResponse>(path: "x"))
        let standard = await transport.last?.timeoutInterval
        XCTAssertEqual(standard, URLRequest(url: base).timeoutInterval)
    }

    func testSessionConfigurationFactory() {
        let standard = URLSessionConfiguration.api()
        XCTAssertEqual(standard.timeoutIntervalForRequest, 30)
        XCTAssertEqual(standard.timeoutIntervalForResource, 120)
        XCTAssertTrue(standard.waitsForConnectivity)

        let custom = URLSessionConfiguration.api(requestTimeout: 5, resourceTimeout: 9, waitsForConnectivity: false)
        XCTAssertEqual(custom.timeoutIntervalForRequest, 5)
        XCTAssertEqual(custom.timeoutIntervalForResource, 9)
        XCTAssertFalse(custom.waitsForConnectivity)
    }

    // MARK: Log redaction

    private func sampleRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://user:pw@example.com/v1/items?page=2&access_token=abc123&Sig=xyz")!)
        request.httpMethod = "POST"
        request.setValue("Bearer s3cret", forHTTPHeaderField: "Authorization")
        request.setValue("sid=42", forHTTPHeaderField: "Cookie")
        request.setValue("k-1", forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"password":"hunter2"}"#.utf8)
        return request
    }

    func testCurlStringIsRedactedByDefault() {
        let request = sampleRequest()
        for curl in [request.curlString, request.curlString(redacting: .default)] {
            for secret in ["s3cret", "sid=42", "k-1", "abc123", "xyz", "hunter2", "pw@"] {
                XCTAssertFalse(curl.contains(secret), "\(secret) leaked in \(curl)")
            }
            XCTAssertTrue(curl.contains("-H 'Authorization: REDACTED'"))
            XCTAssertTrue(curl.contains("-H 'Content-Type: application/json'"))
            XCTAssertTrue(curl.contains("page=2"))
            XCTAssertTrue(curl.contains("access_token=REDACTED"))
            XCTAssertTrue(curl.contains("-d '<22 bytes>'"))
        }
    }

    func testCurlStringWithoutRedactionIsComplete() {
        let curl = sampleRequest().curlString(redacting: .none)
        XCTAssertTrue(curl.contains("-H 'Authorization: Bearer s3cret'"))
        XCTAssertTrue(curl.contains(#"-d '{"password":"hunter2"}'"#))
        XCTAssertTrue(curl.contains("access_token=abc123"))
    }

    func testCustomRedactionAndQuoting() {
        var request = URLRequest(url: URL(string: "https://example.com/a?session=1")!)
        request.setValue("it's", forHTTPHeaderField: "X-Note")
        request.setValue("v", forHTTPHeaderField: "X-Tenant")
        let redaction = LogRedaction(headerNames: ["X-TENANT"], queryItemNames: ["Session"], redactsBody: true)
        let curl = request.curlString(redacting: redaction)
        XCTAssertTrue(curl.contains("-H 'X-Tenant: REDACTED'"))
        XCTAssertTrue(curl.contains(#"-H 'X-Note: it'\''s'"#))
        XCTAssertTrue(curl.contains("session=REDACTED"))
    }
}
