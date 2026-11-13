//
//  RetryPolicyTests.swift
//  Networking
//

import XCTest
@testable import AnvyxNetworkKit

/// Replays a scripted list of outcomes (the last one repeats) and counts calls.
private actor ScriptedTransport: HTTPTransport {
    enum Outcome: Sendable {
        case failure(URLError.Code)
        case cancellation
        case status(Int, headers: [String: String] = [:])
    }

    private var script: [Outcome]
    private(set) var callCount = 0

    init(_ script: [Outcome]) { self.script = script }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let outcome = script.count > 1 ? script.removeFirst() : script[0]
        switch outcome {
        case .failure(let code):
            throw URLError(code)
        case .cancellation:
            throw CancellationError()
        case .status(let status, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data("{}".utf8), response)
        }
    }
}

final class RetryPolicyTests: XCTestCase {
    private let base = URL(string: "https://example.com")!

    private func client(_ transport: ScriptedTransport, baseDelay: TimeInterval = 0.001,
                        maxAttempts: Int = 4) -> APIClient {
        APIClient(baseURL: base, transport: transport,
                  retrier: ExponentialBackoffRetrier(maxAttempts: maxAttempts, baseDelay: baseDelay))
    }

    private func sendExpectingError(_ client: APIClient, _ endpoint: Endpoint<EmptyResponse>) async -> APIError? {
        do {
            try await client.send(endpoint)
            return nil
        } catch {
            return error as? APIError
        }
    }

    // MARK: Cancellation

    func testCancellingDuringBackoffStopsRetrying() async throws {
        let transport = ScriptedTransport([.failure(.timedOut)])
        let client = client(transport, baseDelay: 30, maxAttempts: 5)

        let task = Task { try await client.send(Endpoint<EmptyResponse>(path: "slow")) }
        for _ in 0..<200 where await transport.callCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let the client enter its backoff sleep
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as APIError {
            XCTAssertTrue(error.isCancelled, "got \(error)")
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "no attempt after cancellation")
    }

    func testCancelledURLErrorIsNotRetried() async {
        let transport = ScriptedTransport([.failure(.cancelled)])
        let error = await sendExpectingError(client(transport), Endpoint(path: "x"))
        XCTAssertEqual(error?.isCancelled, true)
        XCTAssertEqual(error?.isRetryable, false)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    func testCancellationErrorIsNotRetried() async {
        let transport = ScriptedTransport([.cancellation])
        let error = await sendExpectingError(client(transport), Endpoint(path: "x"))
        XCTAssertEqual(error?.isCancelled, true)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    // MARK: Idempotency

    func testPostTimeoutIsNotRetried() async {
        let transport = ScriptedTransport([.failure(.timedOut)])
        let error = await sendExpectingError(client(transport), Endpoint(path: "orders", method: .post))
        XCTAssertEqual(error?.urlError?.code, .timedOut)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "the server may have processed the POST")
    }

    func testPostCannotConnectIsRetried() async throws {
        let transport = ScriptedTransport([.failure(.cannotConnectToHost), .failure(.notConnectedToInternet), .status(200)])
        try await client(transport).send(Endpoint<EmptyResponse>(path: "orders", method: .post))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 3)
    }

    func testGetTimeoutIsRetried() async throws {
        let transport = ScriptedTransport([.failure(.timedOut), .failure(.networkConnectionLost), .status(200)])
        try await client(transport).send(Endpoint<EmptyResponse>(path: "items"))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 3)
    }

    func testPostRetriesOnlyStatusesThatMeanNotProcessed() async {
        let retrier = ExponentialBackoffRetrier(maxAttempts: 3, baseDelay: 0.1, jitter: 0)
        var post = URLRequest(url: base)
        post.httpMethod = "POST"
        let unavailable = await retrier.shouldRetry(post, dueTo: .server(status: 503, body: Data()), attempt: 0)
        XCTAssertEqual(unavailable, .retry(afterDelay: 0.1))
        let gatewayTimeout = await retrier.shouldRetry(post, dueTo: .server(status: 504, body: Data()), attempt: 0)
        XCTAssertEqual(gatewayTimeout, .doNotRetry)
        let getGatewayTimeout = await retrier.shouldRetry(URLRequest(url: base), dueTo: .server(status: 504, body: Data()), attempt: 0)
        XCTAssertEqual(getGatewayTimeout, .retry(afterDelay: 0.1))
    }

    // MARK: Delay

    func testDelayIsCappedAndJitterOnlyShortensIt() async {
        let capped = ExponentialBackoffRetrier(maxAttempts: 20, baseDelay: 1, maxDelay: 5, jitter: 0)
        let decision = await capped.shouldRetry(URLRequest(url: base), dueTo: .transport(URLError(.timedOut)), attempt: 10)
        XCTAssertEqual(decision, .retry(afterDelay: 5))

        let jittered = ExponentialBackoffRetrier(maxAttempts: 20, baseDelay: 1, maxDelay: 5, jitter: 0.5)
        for _ in 0..<50 {
            guard case .retry(let delay) = await jittered.shouldRetry(
                URLRequest(url: base), dueTo: .transport(URLError(.timedOut)), attempt: 1) else { return XCTFail("expected retry") }
            XCTAssertGreaterThanOrEqual(delay, 1)
            XCTAssertLessThanOrEqual(delay, 2)
        }
    }

    func testRetryAfterHeaderReplacesBackoffAndIsCapped() async {
        let retrier = ExponentialBackoffRetrier(maxAttempts: 3, baseDelay: 0.1, maxDelay: 10)
        func response(_ status: Int, _ retryAfter: String) -> HTTPURLResponse {
            HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": retryAfter])!
        }
        let seconds = await retrier.shouldRetry(URLRequest(url: base), dueTo: .server(status: 429, body: Data()),
                                                attempt: 0, response: response(429, "7"))
        XCTAssertEqual(seconds, .retry(afterDelay: 7))
        let capped = await retrier.shouldRetry(URLRequest(url: base), dueTo: .server(status: 503, body: Data()),
                                               attempt: 0, response: response(503, "3600"))
        XCTAssertEqual(capped, .retry(afterDelay: 10))
    }

    func testRetryAfterParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // Tue, 14 Nov 2023 22:13:20 GMT
        let response = HTTPURLResponse(url: base, statusCode: 503, httpVersion: nil,
                                       headerFields: ["Retry-After": "Tue, 14 Nov 2023 22:13:50 GMT"])!
        XCTAssertEqual(ExponentialBackoffRetrier.retryAfter(from: response, now: now), 30)
        XCTAssertNil(ExponentialBackoffRetrier.retryAfter(from: nil))
    }

    func testClientPassesResponseToRetrier() async throws {
        let transport = ScriptedTransport([.status(429, headers: ["Retry-After": "0"]), .status(200)])
        // A 60 s base delay would time the test out unless Retry-After: 0 is honoured.
        let client = APIClient(baseURL: base, transport: transport,
                               retrier: ExponentialBackoffRetrier(maxAttempts: 2, baseDelay: 60))
        try await client.send(Endpoint<EmptyResponse>(path: "x"))
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
    }
}
