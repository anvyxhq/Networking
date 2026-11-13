//
//  APIErrorTests.swift
//  Networking
//

import XCTest
@testable import AnvyxNetworkKit

private struct FixedTransport: HTTPTransport {
    var status = 200
    var body = Data()
    var nonHTTP = false
    var failure: (any Error & Sendable)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let failure { throw failure }
        if nonHTTP {
            return (body, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct List: Decodable, Sendable {
    struct Item: Decodable, Sendable { let name: String }
    let items: [Item]
}

private struct Envelope: Decodable { let success: Bool; let code: String? }
private enum SessionError: Error, Equatable { case expired }

private struct EnvelopeValidator: ResponseValidator {
    func validate(data: Data, response: HTTPURLResponse) throws {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        if envelope.code == "SESSION_EXPIRED" { throw SessionError.expired }
        if !envelope.success { throw APIError.server(status: response.statusCode, body: data) }
    }
}

final class APIErrorTests: XCTestCase {
    private let base = URL(string: "https://example.com")!

    private func failure<R>(_ transport: FixedTransport, _ endpoint: Endpoint<R>,
                            validator: (any ResponseValidator)? = nil) async -> (any Error)? {
        let client = APIClient(baseURL: base, transport: transport, validator: validator)
        do {
            _ = try await client.send(endpoint)
            return nil
        } catch {
            return error
        }
    }

    func testTransportKeepsURLErrorCode() async {
        let error = await failure(FixedTransport(failure: URLError(.notConnectedToInternet)), Endpoint<EmptyResponse>(path: "x")) as? APIError
        guard case .transport(let urlError) = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(urlError.code, .notConnectedToInternet)
        XCTAssertEqual(error?.isConnectionLoss, true)
        XCTAssertEqual(error?.isFailureBeforeSending, true)
        XCTAssertEqual(error?.isRetryable, true)
    }

    func testNonURLErrorIsWrappedAsUnknownTransport() async {
        struct Boom: Error {}
        let error = await failure(FixedTransport(failure: Boom()), Endpoint<EmptyResponse>(path: "x")) as? APIError
        XCTAssertEqual(error?.urlError?.code, .unknown)
        XCTAssertNotNil(error?.urlError?.userInfo[NSUnderlyingErrorKey])
    }

    func testClassificationFlags() {
        let timeout = APIError.transport(URLError(.timedOut))
        XCTAssertFalse(timeout.isConnectionLoss)
        XCTAssertFalse(timeout.isFailureBeforeSending)
        XCTAssertTrue(timeout.isRetryable)

        let tls = APIError.transport(URLError(.secureConnectionFailed))
        XCTAssertTrue(tls.isFailureBeforeSending)
        XCTAssertFalse(tls.isConnectionLoss)

        XCTAssertTrue(APIError.transport(URLError(.networkConnectionLost)).isConnectionLoss)
        XCTAssertFalse(APIError.transport(URLError(.networkConnectionLost)).isFailureBeforeSending)

        XCTAssertTrue(APIError.server(status: 503, body: Data()).isRetryable)
        XCTAssertFalse(APIError.server(status: 400, body: Data()).isRetryable)
        XCTAssertFalse(APIError.cancelled.isRetryable)
        XCTAssertFalse(APIError.nonHTTPResponse.isRetryable)
        XCTAssertFalse(APIError.decoding(type: "T", path: "", underlying: "").isRetryable)
    }

    func testServerErrorKeepsBody() async {
        let body = Data(#"{"message":"nope"}"#.utf8)
        let error = await failure(FixedTransport(status: 422, body: body), Endpoint<EmptyResponse>(path: "x")) as? APIError
        guard case .server(let status, let received) = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(status, 422)
        XCTAssertEqual(received, body)
    }

    func testNonHTTPResponseIsAnError() async {
        let error = await failure(FixedTransport(nonHTTP: true), Endpoint<EmptyResponse>(path: "x")) as? APIError
        guard case .nonHTTPResponse = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testDecodingErrorKeepsTypeAndPath() async {
        let body = Data(#"{"items":[{"name":"a"},{"name":7}]}"#.utf8)
        let error = await failure(FixedTransport(body: body), Endpoint<List>(path: "x")) as? APIError
        guard case .decoding(let type, let path, let underlying) = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(type, "List")
        XCTAssertEqual(path, "items[1].name")
        XCTAssertFalse(underlying.isEmpty)
    }

    func testDecodingErrorPathIncludesMissingKey() async {
        let error = await failure(FixedTransport(body: Data(#"{"items":[{}]}"#.utf8)), Endpoint<List>(path: "x")) as? APIError
        guard case .decoding(_, let path, _) = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(path, "items[0].name")
    }

    // MARK: ResponseValidator

    func testValidatorMapsSuccessStatusWithErrorBody() async {
        let body = Data(#"{"success":false,"code":"LIMIT"}"#.utf8)
        let error = await failure(FixedTransport(body: body), Endpoint<EmptyResponse>(path: "x"),
                                  validator: EnvelopeValidator()) as? APIError
        guard case .server(200, let received) = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(received, body)
    }

    func testValidatorCustomErrorReachesCallerUnchanged() async {
        let body = Data(#"{"success":false,"code":"SESSION_EXPIRED"}"#.utf8)
        let error = await failure(FixedTransport(status: 401, body: body), Endpoint<EmptyResponse>(path: "x"),
                                  validator: EnvelopeValidator())
        XCTAssertEqual(error as? SessionError, .expired)
    }

    func testValidatorAcceptingResponseLeavesItUntouched() async {
        let error = await failure(FixedTransport(body: Data(#"{"success":true}"#.utf8)), Endpoint<EmptyResponse>(path: "x"),
                                  validator: EnvelopeValidator())
        XCTAssertNil(error)
    }
}
