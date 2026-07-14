//
//  OfflineRequestQueue.swift
//  Networking
//
//  Created by AnhPT on 14/07/2026.
//

import Foundation

/// A persisted request, safe to store to disk (`URLRequest` isn't `Codable`).
public struct QueuedRequest: Codable, Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }

    public init?(_ request: URLRequest) {
        guard let url = request.url else { return nil }
        self.url = url
        self.method = request.httpMethod ?? "GET"
        self.headers = request.allHTTPHeaderFields ?? [:]
        self.body = request.httpBody
    }

    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = body
        return request
    }
}

/// A durable FIFO queue for requests made while offline: enqueue them, and later
/// ``flush(_:)`` replays them in order once connectivity returns. Persisted to
/// disk so it survives relaunches; stops flushing at the first failure (still
/// offline) and keeps the rest.
public actor OfflineRequestQueue {
    private let fileURL: URL
    private var items: [QueuedRequest]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anvyx.offline-requests.json")
        self.items = (try? Data(contentsOf: self.fileURL))
            .flatMap { try? JSONDecoder().decode([QueuedRequest].self, from: $0) } ?? []
    }

    public var pending: [QueuedRequest] { items }
    public var count: Int { items.count }

    public func enqueue(_ request: URLRequest) {
        guard let queued = QueuedRequest(request) else { return }
        items.append(queued)
        persist()
    }

    public func enqueue(_ request: QueuedRequest) {
        items.append(request)
        persist()
    }

    /// Send queued requests in order, removing each on success. Stops at the first
    /// failure (assumed still offline) and keeps it + the remainder for next time.
    /// - Returns: how many were sent.
    @discardableResult
    public func flush(_ send: @Sendable (URLRequest) async throws -> Void) async -> Int {
        var sent = 0
        while let next = items.first {
            do {
                try await send(next.urlRequest)
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
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
