// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import OSLog

enum AppLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case error = "ERROR"
}

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.podbridge.app"
    private static let appLogger = Logger(subsystem: subsystem, category: "App")
    private static let scanLogger = Logger(subsystem: subsystem, category: "Scan")
    private static let deviceLogger = Logger(subsystem: subsystem, category: "Device")
    private static let syncLogger = Logger(subsystem: subsystem, category: "Sync")
    private static let databaseLogger = Logger(subsystem: subsystem, category: "Database")
    private static let artworkLogger = Logger(subsystem: subsystem, category: "Artwork")
    private static let userInterfaceLogger = Logger(subsystem: subsystem, category: "UI")

    static func app(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "App", logger: appLogger, level: level)
    }

    static func scan(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "Scan", logger: scanLogger, level: level)
    }

    static func device(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "Device", logger: deviceLogger, level: level)
    }

    static func sync(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "Sync", logger: syncLogger, level: level)
    }

    static func database(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "Database", logger: databaseLogger, level: level)
    }

    static func artwork(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "Artwork", logger: artworkLogger, level: level)
    }

    static func ui(_ message: String, level: AppLogLevel = .debug) {
        write(message, category: "UI", logger: userInterfaceLogger, level: level)
    }

    private static func write(
        _ message: String,
        category: String,
        logger: Logger,
        level: AppLogLevel
    ) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        PersistentLogStore.shared.append(category: category, level: level, message: message)
    }
}
