//
//  URLRequest+cURL.swift
//  Networking
//
//  Created by AnhPT on 02/07/2026.
//

import Foundation

public extension URLRequest {
    /// A `curl` command for this request with credentials hidden
    /// (``LogRedaction/default``) — safe to log or share.
    var curlString: String { curlString(redacting: .default) }

    /// A `curl` command for this request — invaluable when debugging or sharing
    /// a failing call. Header values, query values and the body are hidden as
    /// described by `redaction`; pass ``LogRedaction/none`` for a command that
    /// can be pasted and run as is (it then contains credentials).
    func curlString(redacting redaction: LogRedaction = .default) -> String {
        var parts = ["curl"]
        if let method = httpMethod, method != "GET" {
            parts.append("-X \(method)")
        }
        allHTTPHeaderFields?
            .sorted { $0.key < $1.key }
            .forEach { parts.append("-H \(Self.quoted("\($0): \(redaction.headerValue($1, for: $0))"))") }
        if let body = httpBody, !body.isEmpty {
            if redaction.redactsBody {
                parts.append("-d '<\(body.count) bytes>'")
            } else if let string = String(data: body, encoding: .utf8) {
                parts.append("-d \(Self.quoted(string))")
            }
        }
        if let url { parts.append(Self.quoted(redaction.string(for: url))) }
        return parts.joined(separator: " ")
    }

    private static func quoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
