// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import XCTest
@testable import PodBridge

final class PersistentLogStoreTests: XCTestCase {
    func testLogPersistsAcrossStoreInstancesAndExportsDiagnostics() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }

        let first = PersistentLogStore(directoryURL: root)
        first.append(category: "Tests", level: .info, message: "persist-me")
        XCTAssertTrue(first.text().contains("[INFO] [Tests] persist-me"))

        let reopened = PersistentLogStore(directoryURL: root)
        XCTAssertTrue(reopened.text().contains("persist-me"))
        let export = try reopened.makeExportFile()
        let exported = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(exported.contains("PODBRIDGE DIAGNOSTICS"))
        XCTAssertTrue(exported.contains("persist-me"))
    }

    func testLogRotatesAndCanBeCleared() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let store = PersistentLogStore(directoryURL: root, maximumFileSize: 256, retainedFileSize: 128)

        for index in 0..<12 {
            store.append(category: "Tests", level: .debug, message: "line-\(index)-\(String(repeating: "x", count: 40))")
        }
        XCTAssertLessThan(store.fileSize(), 700)
        try store.clear()
        XCTAssertEqual(store.text(), "")
    }
}
