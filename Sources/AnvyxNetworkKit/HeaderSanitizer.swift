//
//  HeaderSanitizer.swift
//  Networking
//

import Foundation

/// Removes characters that could split or forge a header line.
enum HeaderSanitizer {
    private static let tokenCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")

    /// Keeps only the characters allowed in a field name; may return an empty string.
    static func name(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { tokenCharacters.contains($0) }))
    }

    /// Drops CR, LF and every other control character (horizontal tab is kept).
    static func value(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.filter { scalar in
            if scalar.value == 0x09 { return true }
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return false }
            return scalar.value != 0x2028 && scalar.value != 0x2029
        }))
    }

    /// Rewrite every header of `request` through ``name(_:)`` / ``value(_:)``.
    static func sanitize(_ request: inout URLRequest) {
        guard let fields = request.allHTTPHeaderFields else { return }
        for (rawName, rawValue) in fields {
            let cleanName = name(rawName)
            let cleanValue = value(rawValue)
            guard cleanName != rawName || cleanValue != rawValue else { continue }
            request.setValue(nil, forHTTPHeaderField: rawName)
            if !cleanName.isEmpty { request.setValue(cleanValue, forHTTPHeaderField: cleanName) }
        }
    }
}
