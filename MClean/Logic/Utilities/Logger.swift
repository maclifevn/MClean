import Foundation
import os

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let level: LogLevel
    let source: String
}

enum LogLevel: String, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// Thread-safe process logger. No current view observes log entries, so keeping
/// this service off the main actor avoids one task hop for every warning emitted
/// by scanner actors and remains compatible with Swift 6 strict concurrency.
final class Logger: @unchecked Sendable {

    static let shared = Logger()

    private static let maxEntries = 1000
    private let osLogger: os.Logger
    private let lock = NSLock()
    private var entryStorage: [LogEntry] = []
    private var nextReplacementIndex = 0

    var entries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard entryStorage.count == Self.maxEntries,
              nextReplacementIndex > 0 else {
            return entryStorage
        }
        return Array(entryStorage[nextReplacementIndex...])
            + Array(entryStorage[..<nextReplacementIndex])
    }

    private init() {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.maclife.mclean"
        self.osLogger = os.Logger(subsystem: subsystem, category: "general")
    }

    func log(_ message: String, level: LogLevel = .info, source: String = #function) {
        osLogger.log(level: level.osLogType, "\(message, privacy: .public)")

        // High-frequency per-item logs stay in Console.app without filling the
        // in-memory diagnostics ring.
        guard level != .debug else { return }
        append(LogEntry(message: message, level: level, source: source))
    }

    private func append(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        if entryStorage.count < Self.maxEntries {
            entryStorage.append(entry)
        } else {
            entryStorage[nextReplacementIndex] = entry
            nextReplacementIndex = (nextReplacementIndex + 1) % Self.maxEntries
        }
    }
}
