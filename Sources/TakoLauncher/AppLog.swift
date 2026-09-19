import Darwin
import Foundation

enum AppLog {
    #if DEBUG
    private static let queue = DispatchQueue(label: "Tendon.AppLog")
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static var fileURL: URL?

    static func start() {
        let logDirectoryURL = defaultLogDirectoryURL()
        let startedAt = Date()
        let logURL = logDirectoryURL
            .appendingPathComponent("\(fileNameFormatter.string(from: startedAt)).jsonl")

        do {
            try FileManager.default.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            fileURL = logURL
        } catch {
            fputs("Failed to create log file: \(error.localizedDescription)\n", stderr)
            return
        }

        write("app_start", [
            "log_path": logURL.path,
            "current_directory": FileManager.default.currentDirectoryPath,
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "bundle_path": Bundle.main.bundleURL.path,
            "executable_path": Bundle.main.executableURL?.path ?? "unknown"
        ])
    }

    static func write(_ event: String, _ fields: @autoclosure () -> [String: Any] = [:]) {
        guard let fileURL else {
            return
        }

        var payload = fields()
        payload["event"] = event
        payload["timestamp"] = dateFormatter.string(from: Date())

        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            fputs("Failed to encode log event: \(event)\n", stderr)
            return
        }

        queue.async {
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                if let lineData = "\(line)\n".data(using: .utf8) {
                    try handle.write(contentsOf: lineData)
                }
                try handle.close()
            } catch {
                fputs("Failed to write log event: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func defaultLogDirectoryURL() -> URL {
        let bundleURL = Bundle.main.bundleURL

        if
            bundleURL.pathExtension == "app",
            bundleURL.deletingLastPathComponent().lastPathComponent == "dist" {
            return bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("logs", isDirectory: true)
        }

        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent("logs", isDirectory: true)
    }
    #else
    static func start() {}

    static func write(_ event: String, _ fields: @autoclosure () -> [String: Any] = [:]) {}
    #endif
}
