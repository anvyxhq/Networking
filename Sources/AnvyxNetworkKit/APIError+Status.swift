//
//  APIError+Status.swift
//  Networking
//
//  Created by AnhPT on 02/07/2026.
//

import Foundation

public extension APIError {
    /// The HTTP status code, if this error came from an unacceptable response.
    var statusCode: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }

    /// The response body that accompanied an unacceptable status.
    var responseData: Data? {
        if case .server(_, let body) = self { return body }
        return nil
    }

    var isUnauthorized: Bool { statusCode == 401 || statusCode == 403 }
    var isNotFound: Bool { statusCode == 404 }
    var isRateLimited: Bool { statusCode == 429 }
    var isServerError: Bool { (statusCode ?? 0) >= 500 }

    /// The underlying `URLError`, if the request failed below HTTP.
    var urlError: URLError? {
        if case .transport(let error) = self { return error }
        return nil
    }

    /// The request was cancelled (by the task or by the system).
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// The device has no usable route to the server (offline, DNS failure, host
    /// unreachable, connection dropped). A plain timeout is not included — a
    /// slow server is not a lost connection.
    var isConnectionLoss: Bool {
        guard let code = urlError?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// The failure means the request never left the device, so repeating it
    /// cannot duplicate a side effect — even for `POST` / `PATCH`.
    var isFailureBeforeSending: Bool {
        guard let code = urlError?.code else { return false }
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Trying again may succeed: any transport failure, or a status that signals
    /// a temporary condition (408, 429, 500, 502, 503, 504). This ignores the
    /// HTTP method; ``ExponentialBackoffRetrier`` additionally checks that
    /// repeating the request is safe.
    var isRetryable: Bool {
        switch self {
        case .transport:
            return true
        case .server(let status, _):
            return [408, 429, 500, 502, 503, 504].contains(status)
        case .invalidURL, .decoding, .cancelled, .nonHTTPResponse:
            return false
        }
    }
}
