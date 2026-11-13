//
//  LogRedaction.swift
//  Networking
//

import Foundation

/// What to hide when a request is written to a log or rendered as a `curl`
/// command. Names are matched case-insensitively.
public struct LogRedaction: Sendable, Equatable {
    /// Text that replaces a hidden value.
    public static let placeholder = "REDACTED"

    /// Header fields whose value is replaced.
    public var headerNames: Set<String>
    /// Query items whose value is replaced.
    public var queryItemNames: Set<String>
    /// When `true` the body is replaced by its byte count.
    public var redactsBody: Bool

    public init(headerNames: Set<String>, queryItemNames: Set<String>, redactsBody: Bool) {
        self.headerNames = Set(headerNames.map { $0.lowercased() })
        self.queryItemNames = Set(queryItemNames.map { $0.lowercased() })
        self.redactsBody = redactsBody
    }

    /// Hides credential headers, common credential query items and the body.
    public static let `default` = LogRedaction(
        headerNames: ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"],
        queryItemNames: ["access_token", "refresh_token", "id_token", "token", "api_key", "apikey", "key",
                         "password", "secret", "client_secret", "signature", "sig", "code"],
        redactsBody: true
    )

    /// Hides nothing. Only for local debugging — the output contains credentials.
    public static let none = LogRedaction(headerNames: [], queryItemNames: [], redactsBody: false)

    /// The header value to print for `field`.
    public func headerValue(_ value: String, for field: String) -> String {
        headerNames.contains(field.lowercased()) ? Self.placeholder : value
    }

    /// `url` with listed query values and any user-info replaced.
    public func string(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return Self.placeholder
        }
        if components.user != nil { components.user = Self.placeholder }
        if components.password != nil { components.password = Self.placeholder }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                guard item.value != nil, queryItemNames.contains(item.name.lowercased()) else { return item }
                return URLQueryItem(name: item.name, value: Self.placeholder)
            }
        }
        return components.string ?? Self.placeholder
    }
}
