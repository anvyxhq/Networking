//
//  OfflineRequestQueue.swift
//  Networking
//
//  Created by AnhPT on 14/07/2026.
//

import Foundation

/// A persisted request, safe to store to disk (`URLRequest` isn't `Codable`).
///
/// Only allow-listed headers are kept, so credentials never reach the disk.
/// Authentication is added again when the queue is flushed — see
/// ``OfflineRequestQueue/flush(adapters:_:)``.
public struct QueuedRequest: Codable, Sendable, Equatable {
    /// Headers kept by default (matched case-insensitively).
    public static let defaultPersistedHeaders: Set<String> = [
        "accept", "accept-language", "content-type", "content-encoding", "idempotency-key",
    ]

    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }

    /// - Parameter persistedHeaders: names of the headers to keep; every other
    ///   header of `request` is dropped.
    public init?(_ request: URLRequest, persistedHeaders: Set<String> = QueuedRequest.defaultPersistedHeaders) {
        guard let url = request.url else { return nil }
        self.url = url
        self.method = request.httpMethod ?? "GET"
        self.headers = request.allHTTPHeaderFields ?? [:]
        self.body = request.httpBody
        self = keepingHeaders(persistedHeaders)
    }

    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = body
        return request
    }

    /// A copy with every header outside `allowed` removed.
    public func keepingHeaders(_ allowed: Set<String>) -> QueuedRequest {
        let names = Set(allowed.map { $0.lowercased() })
        var copy = self
        copy.headers = headers.filter { names.contains($0.key.lowercased()) }
        return copy
    }
}

/// A durable FIFO queue for requests made while offline: enqueue them, and later
/// ``flush(adapters:_:)`` replays them in order once connectivity returns.
/// Persisted to disk so it survives relaunches; stops flushing at the first
/// failure (still offline) and keeps the rest.
///
/// The file holds only allow-listed headers, is written with file protection
/// (readable after the first unlock, so a background flush still works) and is
/// excluded from backups. Request bodies are stored as given.
public actor OfflineRequestQueue {
    private let fileURL: URL
    private let persistedHeaders: Set<String>
    private var items: [QueuedRequest]

    /// - Parameters:
    ///   - fileURL: where the queue is stored; defaults to a file in Caches.
    ///   - persistedHeaders: names of the headers that may be written to disk.
    public init(fileURL: URL? = nil, persistedHeaders: Set<String> = QueuedRequest.defaultPersistedHeaders) {
        let fileURL = fileURL ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anvyx.offline-requests.json")
        let stored = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([QueuedRequest].self, from: $0) } ?? []
        let items = stored.map { $0.keepingHeaders(persistedHeaders) }
        self.fileURL = fileURL
        self.persistedHeaders = persistedHeaders
        self.items = items
        // A file written by an earlier version may hold headers that are no longer allowed.
        if items != stored { Self.write(items, to: fileURL) }
    }

    public var pending: [QueuedRequest] { items }
    public var count: Int { items.count }

    public func enqueue(_ request: URLRequest) {
        guard let queued = QueuedRequest(request, persistedHeaders: persistedHeaders) else { return }
        items.append(queued)
        persist()
    }

    public func enqueue(_ request: QueuedRequest) {
        items.append(request.keepingHeaders(persistedHeaders))
        persist()
    }

    /// Send queued requests in order, removing each on success. Stops at the first
    /// failure (assumed still offline) and keeps it + the remainder for next time.
    /// - Parameter adapters: applied to each request just before it is sent —
    ///   pass the client's adapters so that current credentials are attached
    ///   (they are not stored with the request).
    /// - Returns: how many were sent.
    @discardableResult
    public func flush(
        adapters: [any RequestAdapter] = [],
        _ send: @Sendable (URLRequest) async throws -> Void
    ) async -> Int {
        var sent = 0
        while let next = items.first {
            do {
                var request = next.urlRequest
                for adapter in adapters {
                    request = try await adapter.adapt(request)
                }
                try await send(request)
                items.removeFirst()
                sent += 1
                persist()
            } catch {
                break   // still failing — keep this one and the rest
            }
        }
        return sent
    }

    public func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        Self.write(items, to: fileURL)
    }

    private static func write(_ items: [QueuedRequest], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
        // An atomic write replaces the file, so the flag is set after every write.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }
}
