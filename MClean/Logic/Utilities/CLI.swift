import Darwin
import Foundation

struct CLI {
    private static let knownCommands: Set<String> = [
        "scan", "disk-info", "list",
        "help", "--help", "-h",
        "version", "--version", "-v",
    ]

    static func isKnownCommand(_ arg: String) -> Bool {
        knownCommands.contains(arg)
    }

    static func run() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let command = args.first else {
            printUsage()
            exit(0)
        }

        switch command {
        case "scan":
            handleScan(args: Array(args.dropFirst()))
        case "disk-info":
            handleDiskInfo()
        case "list":
            handleList()
        case "help", "--help", "-h":
            printUsage()
        case "version", "--version", "-v":
            printVersion()
        default:
            printError("Unknown command: \(command)")
            printUsage()
            exit(1)
        }
        exit(0)
    }

    // MARK: - Commands

    struct ScanOptions: Equatable {
        let json: Bool
        let category: CleaningCategory?
    }

    enum ArgumentError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func scanOptions(_ args: [String]) throws -> ScanOptions {
        var json = false
        var category: CleaningCategory?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json" where !json:
                json = true
            case "--category" where category == nil:
                index += 1
                guard index < args.count, !args[index].hasPrefix("--") else {
                    throw ArgumentError.invalid("--category requires a category name")
                }
                let value = args[index].lowercased().replacingOccurrences(of: " ", with: "")
                guard let matched = CleaningCategory.scannable.first(where: {
                    $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == value
                }) else { throw ArgumentError.invalid("Unknown category: \(args[index])") }
                category = matched
            default:
                throw ArgumentError.invalid("Unknown or repeated option: \(args[index])")
            }
            index += 1
        }
        return ScanOptions(json: json, category: category)
    }

    private static func handleScan(args: [String]) {
        let options: ScanOptions
        do { options = try scanOptions(args) }
        catch { printError(error.localizedDescription); exit(2) }
        let engine = ScanEngine()
        let categories = options.category.map { [$0] } ?? CleaningCategory.scannable

        var allResults: [(String, Int, Int64)] = []

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "cli.scan")

        for category in categories {
            group.enter()
            Task.detached {
                let result = await engine.scanCategory(category)
                queue.sync {
                    allResults.append((category.rawValue, result.itemCount, result.totalSize))
                }
                group.leave()
            }
        }
        group.wait()
        allResults.sort { left, right in
            (categories.firstIndex { $0.rawValue == left.0 } ?? 0)
                < (categories.firstIndex { $0.rawValue == right.0 } ?? 0)
        }

        if options.json {
            printJSON(allResults)
        } else {
            printTable(allResults)
        }
    }

    private static func handleDiskInfo() {
        let engine = ScanEngine()
        var info = DiskInfo()
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            info = await engine.getDiskInfo()
            group.leave()
        }
        group.wait()

        print("Disk Usage:")
        print("  Total:     \(info.formattedTotal)")
        print("  Used:      \(info.formattedUsed)")
        print("  Free:      \(info.formattedFree)")
        if info.purgeableSpace > 0 {
            print("  Purgeable: \(info.formattedPurgeable)")
        }
    }

    private static func handleList() {
        let apps = AppInfoFetcher.shared.fetchInstalledApps()
        print("Installed Apps (\(apps.count)):")
        for app in apps {
            let size = ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file)
            print("  \(app.appName.padding(toLength: 35, withPad: " ", startingAt: 0)) \(size.padding(toLength: 12, withPad: " ", startingAt: 0)) \(app.bundleIdentifier)")
        }
    }

    // MARK: - Output

    private static func printTable(_ results: [(String, Int, Int64)]) {
        var totalSize: Int64 = 0
        var totalItems = 0

        print("Category                Items     Size")
        print("----------------------  -----     --------")
        for (name, count, size) in results {
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0))  \(String(count).padding(toLength: 5, withPad: " ", startingAt: 0))     \(sizeStr)")
            totalSize += size
            totalItems += count
        }
        print("----------------------  -----     --------")
        let totalStr = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        print("Total                   \(String(totalItems).padding(toLength: 5, withPad: " ", startingAt: 0))     \(totalStr)")
    }

    private static func printJSON(_ results: [(String, Int, Int64)]) {
        let entries: [[String: Any]] = results.map { ["category": $0.0, "items": $0.1, "bytes": $0.2] }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { printError("Cannot encode scan results"); exit(1) }
        print(json)
    }

    private static func printUsage() {
        print("""
        MClean CLI

        Usage: mclean <command> [options]

        Commands:
          scan                    Scan all categories
          scan --category <name>  Scan a specific category
          scan --json             Output as JSON
          disk-info               Show disk usage
          list                    List installed apps
          version                 Show version
          help                    Show this help

        Categories:
          \(CleaningCategory.scannable.map(\.rawValue).joined(separator: ", "))
        """)
    }

    private static func printVersion() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.5"
        print("MClean \(version)")
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }

    private static func extractValue(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// Runs short-lived system/CLI probes without allowing a wedged daemon to hold
/// an entire scan forever. Output pipes are drained concurrently so a verbose
/// child cannot block while the parent waits for termination.
enum CommandRunner {
    struct Output {
        let stdout: Data
        let stderr: Data
        let terminationStatus: Int32
        let timedOut: Bool
        let outputTruncated: Bool

        var succeeded: Bool { !timedOut && !outputTruncated && terminationStatus == 0 }
        var stdoutString: String? { String(data: stdout, encoding: .utf8) }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var finishing = false
        private var exceededLimit = false
        private static let limit = 4 * 1024 * 1024

        func append(_ bytes: [UInt8], count: Int) {
            lock.lock()
            defer { lock.unlock() }
            let available = max(0, Self.limit - storage.count)
            storage.append(contentsOf: bytes.prefix(min(available, count)))
            if count > available { exceededLimit = true }
        }

        func finish() { lock.lock(); finishing = true; lock.unlock() }
        var shouldFinish: Bool { lock.lock(); defer { lock.unlock() }; return finishing }
        var truncated: Bool { lock.lock(); defer { lock.unlock() }; return exceededLimit }
        var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private static func drain(_ handle: FileHandle, into box: DataBox, readers: DispatchGroup) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? handle.close(); readers.leave() }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var finalReads = 0
            while true {
                // Drain queued bytes after the child exits, with a bound for
                // descendants that inherited the pipe and continue writing.
                if box.shouldFinish {
                    finalReads += 1
                    if finalReads > 16 { break }
                }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { box.append(buffer, count: count); continue }
                if count == 0 { break }
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { break }
                if box.shouldFinish { break }
                usleep(5_000)
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readers = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdoutBox, readers: readers)
        drain(stderrPipe.fileHandleForReading, into: stderrBox, readers: readers)

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            stdoutBox.finish()
            stderrBox.finish()
            readers.wait()
            throw error
        }

        let pid = process.processIdentifier
        let ownGroup = getpgid(pid) == pid && pid != getpgrp() ? pid : nil
        var timedOut = false
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            let graceEnd = Date().addingTimeInterval(1)
            if let ownGroup { kill(-ownGroup, SIGTERM) }
            else if process.isRunning { process.terminate() }
            _ = terminated.wait(timeout: .now() + 1)
            if let ownGroup {
                // A child can ignore TERM even after its parent exits.
                Thread.sleep(until: graceEnd)
                kill(-ownGroup, SIGKILL)
            } else if process.isRunning {
                kill(pid, SIGKILL)
            }
            if process.isRunning {
                _ = terminated.wait(timeout: .now() + 1)
            }
        }

        stdoutBox.finish()
        stderrBox.finish()
        readers.wait()
        return Output(
            stdout: stdoutBox.value,
            stderr: stderrBox.value,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut,
            outputTruncated: stdoutBox.truncated || stderrBox.truncated
        )
    }
}
