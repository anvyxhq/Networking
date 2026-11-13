//
//  Interceptor.swift
//  Networking
//
//  Created by AnhPT on 02/07/2026.
//

import Foundation

/// Mutates every outgoing request — the place to inject auth tokens, common
/// headers, signing, etc.
public protocol RequestAdapter: Sendable {
    func adapt(_ request: URLRequest) async throws -> URLRequest
}

/// Decides whether a failed request should be retried.
public protocol RequestRetrier: Sendable {
    func shouldRetry(
        _ request: URLRequest,
        dueTo error: APIError,
        attempt: Int
    ) async -> RetryDecision

    /// As above, plus the HTTP response that produced `error` (when there was
    /// one) so a policy can read headers such as `Retry-After`. ``APIClient``
    /// calls this variant; the default implementation ignores `response`.
    func shouldRetry(
        _ request: URLRequest,
        dueTo error: APIError,
        attempt: Int,
        response: HTTPURLResponse?
    ) async -> RetryDecision
}

public extension RequestRetrier {
    func shouldRetry(
        _ request: URLRequest,
        dueTo error: APIError,
        attempt: Int,
        response: HTTPURLResponse?
    ) async -> RetryDecision {
        await shouldRetry(request, dueTo: error, attempt: attempt)
    }
}

public enum RetryDecision: Sendable, Equatable {
    case doNotRetry
    case retry(afterDelay: TimeInterval)
}

/// Injects a bearer token (resolved lazily each request, so token refresh works).
public struct BearerTokenAdapter: RequestAdapter {
    private let token: @Sendable () async -> String?
    public init(token: @escaping @Sendable () async -> String?) {
        self.token = token
    }
    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        guard let token = await token() else { return request }
        var copy = request
        // `URLRequest` silently drops a value that contains a line break (a token
        // read from a file often ends with one), so clean it first.
        copy.setValue(HeaderSanitizer.value("Bearer \(token)"), forHTTPHeaderField: "Authorization")
        return copy
    }
}

/// Retries with exponential backoff, only when repeating the request is safe.
///
/// - `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS`, `TRACE` (idempotent): retried on
///   any transport error and on every status in `retryableStatuses`.
/// - `POST`, `PATCH` and anything else: retried only when the request provably
///   did not reach the server — a transport error for which
///   ``APIError/isFailureBeforeSending`` is `true`, or a `408` / `429` / `503`
///   status that is also in `retryableStatuses`. A timeout or a dropped
///   connection is **not** retried, because the server may already have
///   processed the request.
/// - ``APIError/cancelled``, decoding and URL errors are never retried.
///
/// The delay is `baseDelay * 2^attempt`, capped at `maxDelay`, then reduced by a
/// random fraction of up to `jitter` so that clients do not retry in step. On
/// `429` / `503` a `Retry-After` header (seconds or HTTP date) replaces the
/// computed delay, still capped at `maxDelay`.
public struct ExponentialBackoffRetrier: RequestRetrier {
    private static let idempotentMethods: Set<String> = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE"]
    private static let statusesSafeToRepeat: Set<Int> = [408, 429, 503]

    private let maxAttempts: Int
    private let baseDelay: TimeInterval
    private let retryableStatuses: Set<Int>
    private let maxDelay: TimeInterval
    private let jitter: Double

    /// - Parameters:
    ///   - maxAttempts: total number of tries, including the first.
    ///   - baseDelay: delay before the first retry.
    ///   - retryableStatuses: HTTP statuses worth retrying.
    ///   - maxDelay: upper bound for any single delay, `Retry-After` included.
    ///   - jitter: fraction (`0...1`) of the delay that may be randomly removed;
    ///     `0` gives deterministic delays.
    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504],
        maxDelay: TimeInterval = 30,
        jitter: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.retryableStatuses = retryableStatuses
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(1, max(0, jitter))
    }

    public func shouldRetry(_ request: URLRequest, dueTo error: APIError, attempt: Int) async -> RetryDecision {
        await shouldRetry(request, dueTo: error, attempt: attempt, response: nil)
    }

    public func shouldRetry(
        _ request: URLRequest,
        dueTo error: APIError,
        attempt: Int,
        response: HTTPURLResponse?
    ) async -> RetryDecision {
        guard attempt < maxAttempts - 1 else { return .doNotRetry }
        let isIdempotent = Self.idempotentMethods.contains((request.httpMethod ?? "GET").uppercased())
        let retryable: Bool
        switch error {
        case .transport:
            retryable = isIdempotent || error.isFailureBeforeSending
        case .server(let status, _):
            retryable = retryableStatuses.contains(status)
                && (isIdempotent || Self.statusesSafeToRepeat.contains(status))
        case .invalidURL, .decoding, .cancelled, .nonHTTPResponse:
            retryable = false
        }
        guard retryable else { return .doNotRetry }

        if let status = error.statusCode, status == 429 || status == 503,
           let retryAfter = Self.retryAfter(from: response) {
            return .retry(afterDelay: min(retryAfter, maxDelay))
        }
        let backoff = min(maxDelay, baseDelay * pow(2, Double(attempt)))
        let delay = jitter > 0 ? backoff * (1 - Double.random(in: 0...jitter)) : backoff
        return .retry(afterDelay: delay)
    }

    /// Parse `Retry-After` as delta-seconds or an HTTP date.
    static func retryAfter(from response: HTTPURLResponse?, now: Date = Date()) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds.isFinite ? max(0, seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
