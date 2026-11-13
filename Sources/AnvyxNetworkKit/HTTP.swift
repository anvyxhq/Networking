//
//  HTTP.swift
//  Networking
//
//  Created by AnhPT on 02/07/2026.
//

import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// A typed description of a single request. Generic over the `Response` it decodes to.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public var path: String
    public var method: HTTPMethod
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data?
    /// Per-endpoint retry policy; when set it overrides the client's default
    /// retrier for this request only (e.g. no retries on a non-idempotent POST).
    public var retrier: (any RequestRetrier)?
    /// Per-request timeout in seconds (sets `URLRequest.timeoutInterval`).
    /// `nil` keeps the session configuration's request timeout.
    public var timeout: TimeInterval?

    public init(
        path: String,
        method: HTTPMethod = .get,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        retrier: (any RequestRetrier)? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.headers = headers
        self.body = body
        self.retrier = retrier
        self.timeout = timeout
    }

    /// Convenience for a JSON-encoded body.
    public func body<T: Encodable>(json value: T, encoder: JSONEncoder = JSONEncoder()) -> Endpoint {
        var copy = self
        copy.body = try? encoder.encode(value)
        copy.headers["Content-Type"] = "application/json"
        return copy
    }

    /// A copy that uses `retrier` instead of the client's default retry policy.
    public func retrying(_ retrier: any RequestRetrier) -> Endpoint {
        var copy = self
        copy.retrier = retrier
        return copy
    }

    /// A copy that times out after `seconds` instead of the session default.
    public func timeout(_ seconds: TimeInterval) -> Endpoint {
        var copy = self
        copy.timeout = seconds
        return copy
    }
}

/// Everything ``APIClient`` can fail with. Each case keeps the payload needed
/// to react precisely (the `URLError` code, the response body, the coding path).
///
/// Use the computed flags in preference to matching codes by hand:
/// ``isRetryable``, ``isConnectionLoss``, ``isFailureBeforeSending``,
/// ``isCancelled`` and the status helpers (``statusCode``, ``isUnauthorized``…).
public enum APIError: Error, Sendable {
    /// The endpoint could not be turned into a valid URL.
    case invalidURL
    /// The request failed below HTTP (no connectivity, timeout, TLS…). An error
    /// that is not a `URLError` is wrapped as `URLError(.unknown)` with the
    /// original under `NSUnderlyingErrorKey`.
    case transport(URLError)
    /// The server answered with a status outside `200..<300`.
    case server(status: Int, body: Data)
    /// The body could not be decoded. `type` is the expected type, `path` the
    /// coding path of the offending value (e.g. `items[2].name`, empty at the
    /// root) and `underlying` the decoder's description.
    case decoding(type: String, path: String, underlying: String)
    /// The task was cancelled, or the load was cancelled by the system (this is
    /// also how a rejected authentication challenge surfaces). Never retried.
    case cancelled
    /// The transport returned something other than an `HTTPURLResponse`.
    case nonHTTPResponse
}

extension APIError {
    /// Classify any error thrown while loading a request.
    static func wrapping(_ error: any Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transport(urlError)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return code == .cancelled ? .cancelled : .transport(URLError(code, userInfo: nsError.userInfo))
        }
        return .transport(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: nsError]))
    }

    /// Describe a decoding failure, keeping the coding path.
    static func decoding(_ error: any Error, type: Any.Type) -> APIError {
        let typeName = String(describing: type)
        guard let decodingError = error as? DecodingError else {
            return .decoding(type: typeName, path: "", underlying: error.localizedDescription)
        }
        let context: DecodingError.Context
        var missingKey: (any CodingKey)?
        switch decodingError {
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            context = ctx
        case .keyNotFound(let key, let ctx):
            context = ctx
            missingKey = key
        @unknown default:
            return .decoding(type: typeName, path: "", underlying: error.localizedDescription)
        }
        var path = ""
        for key in context.codingPath + (missingKey.map { [$0] } ?? []) {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return .decoding(type: typeName, path: path, underlying: context.debugDescription)
    }

    /// A short description without URLs, headers or bodies — safe to log publicly.
    var logSummary: String {
        switch self {
        case .invalidURL: return "invalidURL"
        case .transport(let error): return "transport(\(error.code.rawValue))"
        case .server(let status, let body): return "server(\(status), \(body.count) bytes)"
        case .decoding(let type, let path, _): return "decoding(\(type) at \(path.isEmpty ? "<root>" : path))"
        case .cancelled: return "cancelled"
        case .nonHTTPResponse: return "nonHTTPResponse"
        }
    }
}
