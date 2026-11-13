//
//  URLSessionConfiguration+API.swift
//  Networking
//

import Foundation

public extension URLSessionConfiguration {
    /// A default configuration with explicit timeouts for API traffic.
    ///
    /// - Parameters:
    ///   - requestTimeout: seconds without receiving data before a request fails
    ///     (`timeoutIntervalForRequest`). ``Endpoint/timeout`` overrides it per request.
    ///   - resourceTimeout: upper bound for a whole request including retries by
    ///     the system and time spent waiting for connectivity
    ///     (`timeoutIntervalForResource`).
    ///   - waitsForConnectivity: when `true` a request made while offline waits
    ///     (up to `resourceTimeout`) for a connection instead of failing at once.
    ///
    /// ```swift
    /// let session = URLSession(configuration: .api(requestTimeout: 15))
    /// let client = APIClient(baseURL: url, transport: session)
    /// ```
    ///
    /// - Important: A `URLSession` created with a delegate keeps a strong
    ///   reference to it until the session is invalidated. Call
    ///   `finishTasksAndInvalidate()` (or `invalidateAndCancel()`) when you are
    ///   done with such a session, otherwise the session and its delegate leak.
    static func api(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        waitsForConnectivity: Bool = true
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        return configuration
    }
}
