//
//  PerEndpointRetryTests.swift
//  Networking
//
//  Created by AnhPT on 10/07/2026.
//

import XCTest
@testable import AnvyxNetworkKit

/// Fails with 503 a fixed number of times, then succeeds — and counts calls.
private actor FlakyTransport: HTTPTransport {
    private var failuresRemaining: Int
    private let body: Data
    private(set) var callCount = 0

    init(failures: Int, body: Data) {
        self.failuresRemaining = failures
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let status: Int
        if failuresRemaining > 0 { failuresRemaining -= 1; status = 503 } else { status = 200 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private struct Item: Decodable, Equatable { let id: Int; let name: String }

final class PerEndpointRetryTests: XCTestCase {

    private let base = URL(string: "https://example.com")!
    private let json = #"{"id":1,"name":"ok"}"#.data(using: .utf8)!

    func testEndpointRetrierAppliesWhenClientHasNoDefault() async throws {
        let transport = FlakyTransport(failures: 2, body: json)
        let client = APIClient(baseURL: base, transport: transport)   // no default retrier

        let endpoint = Endpoint<Item>(path: "items/1")
            .retrying(ExponentialBackoffRetrier(maxAttempts: 4, baseDelay: 0.001, retryableStatuses: [503]))

        let item: Item = try await client.send(endpoint)
        XCTAssertEqual(item, Item(id: 1, name: "ok"))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 3, "2 failures + 1 success")
    }

    func testEndpointRetrierCanDisableTheClientDefault() async {
        let transport = FlakyTransport(failures: 5, body: json)
        // Client default would happily retry 503…
        let client = APIClient(
            baseURL: base, transport: transport,
            retrier: ExponentialBackoffRetrier(maxAttempts: 6, baseDelay: 0.001, retryableStatuses: [503]))

        // …but this endpoint opts out (maxAttempts 1 => never retries).
        let endpoint = Endpoint<Item>(path: "x").retrying(ExponentialBackoffRetrier(maxAttempts: 1))

        do {
            let _: Item = try await client.send(endpoint)
            XCTFail("expected failure")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 503)
        } catch {
            XCTFail("unexpected error type")
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "endpoint-level policy disabled retries")
    }
}
