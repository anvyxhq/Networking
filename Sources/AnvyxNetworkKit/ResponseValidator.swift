//
//  ResponseValidator.swift
//  Networking
//

import Foundation

/// A hook ``APIClient`` runs on every HTTP response before its own status check.
/// Use it to map responses the status code alone cannot classify — a
/// `200 OK` whose body carries an error envelope, or an envelope that means the
/// session has ended.
///
/// Throw to fail the request; return normally to accept the response. An
/// ``APIError`` goes through the retry policy like any other failure; any other
/// error type is rethrown to the caller unchanged and is never retried.
///
/// ```swift
/// struct EnvelopeValidator: ResponseValidator {
///     func validate(data: Data, response: HTTPURLResponse) throws {
///         guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
///         if envelope.code == "SESSION_EXPIRED" { throw SessionError.expired }
///         if !envelope.success { throw APIError.server(status: response.statusCode, body: data) }
///     }
/// }
/// ```
///
/// A `304` answered from the response cache is not validated again.
public protocol ResponseValidator: Sendable {
    func validate(data: Data, response: HTTPURLResponse) throws
}
