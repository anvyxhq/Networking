//
//  OfflineRequestQueueTests.swift
//  Networking
//
//  Created by AnhPT on 14/07/2026.
//

import XCTest
@testable import AnvyxNetworkKit

final class OfflineRequestQueueTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
    }

    func testQueuedRequestRoundTrip() {
        var request = URLRequest(url: URL(string: "https://example.com/upload")!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("hi".utf8)
        let queued = QueuedRequest(request)!
        let back = queued.urlRequest
        XCTAssertEqual(back.httpMethod, "PUT")
        XCTAssertEqual(back.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(back.httpBody, Data("hi".utf8))
    }

    func testFlushSendsAllOnSuccess() async {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let queue = OfflineRequestQueue(fileURL: file)
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/1")!))
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/2")!))

        let sentBox = Box()
        let sent = await queue.flush { _ in await sentBox.increment() }
        XCTAssertEqual(sent, 2)
        let pending = await queue.count
        XCTAssertEqual(pending, 0)
        let calls = await sentBox.value
        XCTAssertEqual(calls, 2)
    }

    func testFlushStopsOnFailureAndKeepsRemainder() async {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let queue = OfflineRequestQueue(fileURL: file)
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/1")!))
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/2")!))

        struct Offline: Error {}
        let sent = await queue.flush { _ in throw Offline() }
        XCTAssertEqual(sent, 0)
        let pending = await queue.count
        XCTAssertEqual(pending, 2)   // both kept for next time
    }

    func testPersistsAcrossInstances() async {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let first = OfflineRequestQueue(fileURL: file)
        await first.enqueue(URLRequest(url: URL(string: "https://a.com/persist")!))

        let second = OfflineRequestQueue(fileURL: file)   // loads from disk
        let pending = await second.count
        XCTAssertEqual(pending, 1)
    }

    func testCredentialHeadersAreNotWrittenToDisk() async throws {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let queue = OfflineRequestQueue(fileURL: file)
        var request = URLRequest(url: URL(string: "https://a.com/1")!)
        request.httpMethod = "POST"
        request.setValue("Bearer s3cret", forHTTPHeaderField: "Authorization")
        request.setValue("sid=s3cret", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await queue.enqueue(request)
        await queue.enqueue(QueuedRequest(url: URL(string: "https://a.com/2")!, headers: ["X-API-Key": "s3cret"]))

        let stored = try String(decoding: Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(stored.contains("s3cret"), stored)
        XCTAssertTrue(stored.contains("application"))
        let pending = await queue.pending
        XCTAssertEqual(pending.first?.headers, ["Content-Type": "application/json"])
        XCTAssertEqual(pending.last?.headers, [:])
    }

    func testOldFileWithCredentialHeadersIsCleanedOnLoad() async throws {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let legacy = [QueuedRequest(url: URL(string: "https://a.com/1")!, headers: ["Authorization": "Bearer s3cret"])]
        try JSONEncoder().encode(legacy).write(to: file)

        let queue = OfflineRequestQueue(fileURL: file)
        let pending = await queue.pending
        XCTAssertEqual(pending.first?.headers, [:])
        let stored = try String(decoding: Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(stored.contains("s3cret"))
    }

    func testFlushAppliesAdapters() async {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let queue = OfflineRequestQueue(fileURL: file)
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/1")!))

        let seen = HeaderBox()
        let sent = await queue.flush(adapters: [BearerTokenAdapter { "fresh" }]) { request in
            await seen.set(request.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertEqual(sent, 1)
        let header = await seen.value
        XCTAssertEqual(header, "Bearer fresh")
    }

    func testFileIsExcludedFromBackup() async throws {
        let file = tempFile(); defer { try? FileManager.default.removeItem(at: file) }
        let queue = OfflineRequestQueue(fileURL: file)
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/1")!))
        await queue.enqueue(URLRequest(url: URL(string: "https://a.com/2")!))   // survives the atomic rewrite
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    private actor HeaderBox {
        private(set) var value: String?
        func set(_ value: String?) { self.value = value }
    }

    private actor Box {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
