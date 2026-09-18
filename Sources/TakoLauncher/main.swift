import AppKit
import ApplicationServices
import Carbon
import Darwin
import ScreenCaptureKit

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

enum LaunchTargetKind: Hashable {
    case application
    case window
}

struct WindowFrame: Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct LaunchableApp: Hashable {
    let name: String
    let applicationName: String?
    let url: URL?
    let bundleIdentifier: String?
    let searchText: String
    let identityKey: String
    let historyKey: String
    let processIdentifier: pid_t?
    let isRunning: Bool
    let targetKind: LaunchTargetKind
    let windowTitle: String?
    let windowFrame: WindowFrame?
    let windowIdentifier: UInt32?

    var subtitle: String {
        switch targetKind {
        case .application:
            let detail = bundleIdentifier ?? url?.path ?? processIdentifier.map { "pid \($0)" } ?? "Unknown source"
            return isRunning ? "Running - \(detail)" : detail
        case .window:
            let owner = applicationName ?? bundleIdentifier ?? processIdentifier.map { "pid \($0)" } ?? "Unknown app"
            return "Window - \(owner)"
        }
    }

    var resolvedPath: String? {
        url?.resolvingSymlinksInPath().path
    }

    func matches(_ query: String) -> Bool {
        let tokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return true
        }

        return tokens.allSatisfy { token in
            searchText.range(
                of: token,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    func markedRunning(processIdentifier: pid_t?) -> LaunchableApp {
        let runningSearchText = [searchText, "running"]
            .joined(separator: " ")

        return LaunchableApp(
            name: name,
            applicationName: applicationName,
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: runningSearchText,
            identityKey: identityKey,
            historyKey: historyKey,
            processIdentifier: processIdentifier,
            isRunning: true,
            targetKind: targetKind,
            windowTitle: windowTitle,
            windowFrame: windowFrame,
            windowIdentifier: windowIdentifier
        )
    }
}

private struct CoreGraphicsWindowInfo {
    let identifier: UInt32?
    let ownerProcessIdentifier: pid_t
    let ownerName: String?
    let title: String?
    let frame: WindowFrame?

    var hasTitle: Bool {
        title?.isEmpty == false
    }

    var isLargeEnoughForCandidate: Bool {
        guard let frame else {
            return true
        }

        return frame.width >= 80 && frame.height >= 40
    }
}

private enum CoreGraphicsWindowReader {
    static func layerZeroWindows() -> [CoreGraphicsWindowInfo] {
        guard
            let windowInfoList = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        return windowInfoList.compactMap { info in
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let ownerProcessIdentifier = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else {
                return nil
            }

            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let frame = windowFrame(from: bounds)
            let identifier = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value

            return CoreGraphicsWindowInfo(
                identifier: identifier,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerName: trimmedString(info[kCGWindowOwnerName as String]),
                title: trimmedString(info[kCGWindowName as String]),
                frame: frame
            )
        }
    }

    static func candidateWindows() -> [CoreGraphicsWindowInfo] {
        layerZeroWindows().filter(\.isLargeEnoughForCandidate)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func windowFrame(from bounds: [String: Any]?) -> WindowFrame? {
        guard
            let x = (bounds?["X"] as? NSNumber)?.doubleValue,
            let y = (bounds?["Y"] as? NSNumber)?.doubleValue,
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue,
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        return WindowFrame(x: x, y: y, width: width, height: height)
    }
}

private enum AccessibilityWindowGeometry {
    static func frame(of window: AXUIElement) -> WindowFrame? {
        guard
            let origin = pointAttribute(kAXPositionAttribute as CFString, of: window),
            let size = sizeAttribute(kAXSizeAttribute as CFString, of: window)
        else {
            return nil
        }

        return WindowFrame(
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height
        )
    }

    private static func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success, let value else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private static func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success, let value else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else {
            return nil
        }

        return size
    }
}

private struct AccessibilityWindowIdentifierLookup {
    let identifier: UInt32?
    let error: AXError?
    let symbolName: String?
}

private enum AccessibilityWindowIdentity {
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let resolvedFunction: (name: String, function: GetWindowFunction)? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }

        for symbolName in ["_AXUIElementGetWindow", "AXUIElementGetWindow"] {
            guard let symbol = dlsym(handle, symbolName) else {
                continue
            }

            let function = unsafeBitCast(symbol, to: GetWindowFunction.self)
            return (symbolName, function)
        }

        return nil
    }()

    static var availabilityDescription: String {
        resolvedFunction.map { "\($0.name) available" } ?? "unavailable"
    }

    static func identifier(of window: AXUIElement) -> UInt32? {
        lookup(of: window).identifier
    }

    static func lookup(of window: AXUIElement) -> AccessibilityWindowIdentifierLookup {
        guard let resolvedFunction else {
            return AccessibilityWindowIdentifierLookup(
                identifier: nil,
                error: nil,
                symbolName: nil
            )
        }

        var identifier = CGWindowID(0)
        let error = resolvedFunction.function(window, &identifier)

        guard error == .success, identifier != 0 else {
            return AccessibilityWindowIdentifierLookup(
                identifier: nil,
                error: error,
                symbolName: resolvedFunction.name
            )
        }

        return AccessibilityWindowIdentifierLookup(
            identifier: identifier,
            error: error,
            symbolName: resolvedFunction.name
        )
    }
}

enum AppDiscovery {
    static func loadInstalledApplications() -> [LaunchableApp] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var seenPaths = Set<String>()
        var apps: [LaunchableApp] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            apps.append(contentsOf: applications(in: root, seenPaths: &seenPaths))
        }

        return apps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func includeRunningApplications(in installedApps: [LaunchableApp]) -> [LaunchableApp] {
        var appsByHistoryKey: [String: LaunchableApp] = [:]
        var historyKeyByPath: [String: String] = [:]

        func store(_ app: LaunchableApp) {
            appsByHistoryKey[app.historyKey] = app

            if let resolvedPath = app.resolvedPath {
                historyKeyByPath[resolvedPath] = app.historyKey
            }
        }

        for app in installedApps {
            store(app)
        }

        for runningApp in runningApplications() {
            let existingKey = runningApp.resolvedPath.flatMap { historyKeyByPath[$0] } ?? runningApp.historyKey

            if let existingApp = appsByHistoryKey[existingKey] {
                store(existingApp.markedRunning(processIdentifier: runningApp.processIdentifier))
            } else {
                store(runningApp)
            }
        }

        let windowCandidates = windowCandidates(for: Array(appsByHistoryKey.values))
        let windowCandidateProcessIdentifiers = Set(windowCandidates.compactMap(\.processIdentifier))
        let applicationCandidates = appsByHistoryKey.values.filter { app in
            guard
                app.isRunning,
                app.targetKind == .application,
                let processIdentifier = app.processIdentifier
            else {
                return true
            }

            return !windowCandidateProcessIdentifiers.contains(processIdentifier)
        }

        var candidatesByIdentityKey = Dictionary(
            uniqueKeysWithValues: applicationCandidates.map { ($0.identityKey, $0) }
        )

        for windowCandidate in windowCandidates {
            candidatesByIdentityKey[windowCandidate.identityKey] = windowCandidate
        }

        return candidatesByIdentityKey.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func applications(in root: URL, seenPaths: inout Set<String>) -> [LaunchableApp] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var apps: [LaunchableApp] = []

        for case let url as URL in enumerator where url.pathExtension == "app" {
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard !seenPaths.contains(resolvedPath) else {
                continue
            }

            seenPaths.insert(resolvedPath)
            apps.append(makeApp(from: url))
        }

        return apps
    }

    private static func makeApp(from url: URL) -> LaunchableApp {
        let bundle = Bundle(url: url)
        let localizedInfo = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary

        let displayName =
            localizedInfo?["CFBundleDisplayName"] as? String ??
            localizedInfo?["CFBundleName"] as? String ??
            info?["CFBundleDisplayName"] as? String ??
            info?["CFBundleName"] as? String ??
            resourceName(for: url) ??
            url.deletingPathExtension().lastPathComponent

        let bundleIdentifier = bundle?.bundleIdentifier
        let historyKey = bundleIdentifier.map { "bundle:\($0)" } ??
            "path:\(url.resolvingSymlinksInPath().path)"
        let searchText = [
            displayName,
            bundleIdentifier,
            url.lastPathComponent,
            url.path
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: displayName,
            applicationName: displayName,
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: searchText,
            identityKey: historyKey,
            historyKey: historyKey,
            processIdentifier: nil,
            isRunning: false,
            targetKind: .application,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }

    private static func runningApplications() -> [LaunchableApp] {
        var appsByProcessIdentifier: [pid_t: LaunchableApp] = [:]
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        for runningApplication in NSWorkspace.shared.runningApplications {
            guard runningApplication.processIdentifier != currentProcessIdentifier else {
                continue
            }

            guard runningApplication.activationPolicy == .regular else {
                continue
            }

            if let app = makeApp(from: runningApplication) {
                appsByProcessIdentifier[runningApplication.processIdentifier] = app
            }
        }

        for app in coreGraphicsRunningApplications() {
            guard let processIdentifier = app.processIdentifier else {
                continue
            }

            guard processIdentifier != currentProcessIdentifier else {
                continue
            }

            appsByProcessIdentifier[processIdentifier] = appsByProcessIdentifier[processIdentifier] ?? app
        }

        return appsByProcessIdentifier.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeApp(
        from runningApplication: NSRunningApplication,
        fallbackName: String? = nil
    ) -> LaunchableApp? {
        let url = runningApplication.bundleURL
        let bundle = url.flatMap { Bundle(url: $0) }
        let localizedInfo = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary

        let displayNameCandidates: [String?] = [
            runningApplication.localizedName,
            localizedInfo?["CFBundleDisplayName"] as? String,
            localizedInfo?["CFBundleName"] as? String,
            info?["CFBundleDisplayName"] as? String,
            info?["CFBundleName"] as? String,
            fallbackName,
            url.flatMap { resourceName(for: $0) },
            url?.deletingPathExtension().lastPathComponent
        ]
        let displayName = displayNameCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let displayName else {
            return nil
        }

        let bundleIdentifier = runningApplication.bundleIdentifier ?? bundle?.bundleIdentifier
        return makeRunningApp(
            name: displayName,
            processIdentifier: runningApplication.processIdentifier,
            url: url,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func makeRunningApp(
        name: String,
        processIdentifier: pid_t,
        url: URL?,
        bundleIdentifier: String?
    ) -> LaunchableApp {
        let resolvedPath = url?.resolvingSymlinksInPath().path
        let historyKey = bundleIdentifier.map { "bundle:\($0)" } ??
            resolvedPath.map { "path:\($0)" } ??
            "pid:\(processIdentifier)"
        let searchText = [
            name,
            bundleIdentifier,
            url?.lastPathComponent,
            url?.path,
            "running"
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: name,
            applicationName: name,
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: searchText,
            identityKey: historyKey,
            historyKey: historyKey,
            processIdentifier: processIdentifier,
            isRunning: true,
            targetKind: .application,
            windowTitle: nil,
            windowFrame: nil,
            windowIdentifier: nil
        )
    }

    private static func coreGraphicsRunningApplications() -> [LaunchableApp] {
        var appsByProcessIdentifier: [pid_t: LaunchableApp] = [:]
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        for windowInfo in CoreGraphicsWindowReader.candidateWindows() {
            guard
                windowInfo.ownerProcessIdentifier != currentProcessIdentifier,
                appsByProcessIdentifier[windowInfo.ownerProcessIdentifier] == nil
            else {
                continue
            }

            let processIdentifier = windowInfo.ownerProcessIdentifier
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)

            if let runningApplication, let app = makeApp(from: runningApplication, fallbackName: windowInfo.ownerName) {
                appsByProcessIdentifier[processIdentifier] = app
                continue
            }

            guard let ownerName = windowInfo.ownerName else {
                continue
            }

            appsByProcessIdentifier[processIdentifier] = makeRunningApp(
                name: ownerName,
                processIdentifier: processIdentifier,
                url: runningApplication?.bundleURL,
                bundleIdentifier: runningApplication?.bundleIdentifier
            )
        }

        return appsByProcessIdentifier.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func windowCandidates(for apps: [LaunchableApp]) -> [LaunchableApp] {
        var candidates: [LaunchableApp] = []
        var seenWindowKeys = Set<String>()

        func append(_ candidate: LaunchableApp) {
            guard let processIdentifier = candidate.processIdentifier else {
                return
            }

            let title = candidate.windowTitle ?? candidate.name
            let windowKey = candidate.windowIdentifier.map {
                "\(processIdentifier):id:\($0)"
            } ?? "\(processIdentifier):title:\(title)"

            guard !seenWindowKeys.contains(windowKey) else {
                return
            }

            seenWindowKeys.insert(windowKey)
            candidates.append(candidate)
        }

        accessibilityWindowCandidates(for: apps).forEach(append)
        coreGraphicsWindowCandidates(for: apps).forEach(append)

        return candidates
    }

    private static func accessibilityWindowCandidates(for apps: [LaunchableApp]) -> [LaunchableApp] {
        guard AXIsProcessTrusted() else {
            return []
        }

        return apps.flatMap { app in
            guard let processIdentifier = app.processIdentifier else {
                return [LaunchableApp]()
            }

            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            let windows = accessibilityWindows(in: applicationElement)

            return windows.enumerated().compactMap { index, window in
                guard let title = accessibilityTitle(of: window), !title.isEmpty else {
                    return nil
                }

                let windowIdentifier = AccessibilityWindowIdentity.identifier(of: window)
                let identityKey = windowIdentifier.map {
                    "window:\(processIdentifier):ax-window-id:\($0)"
                } ?? "window:\(processIdentifier):ax:\(index):\(title)"

                return makeWindowCandidate(
                    baseApp: app,
                    title: title,
                    identityKey: identityKey,
                    frame: AccessibilityWindowGeometry.frame(of: window),
                    windowIdentifier: windowIdentifier
                )
            }
        }
    }

    private static func coreGraphicsWindowCandidates(for apps: [LaunchableApp]) -> [LaunchableApp] {
        let appsByPID = Dictionary(
            uniqueKeysWithValues: apps.compactMap { app -> (pid_t, LaunchableApp)? in
                guard let processIdentifier = app.processIdentifier else {
                    return nil
                }

                return (processIdentifier, app)
            }
        )

        return CoreGraphicsWindowReader.candidateWindows().compactMap { windowInfo in
            guard
                let baseApp = appsByPID[windowInfo.ownerProcessIdentifier],
                let title = windowInfo.title,
                let identifier = windowInfo.identifier
            else {
                return nil
            }

            let identityKey = "window:\(windowInfo.ownerProcessIdentifier):\(identifier)"
            return makeWindowCandidate(
                baseApp: baseApp,
                title: title,
                identityKey: identityKey,
                frame: windowInfo.frame,
                windowIdentifier: identifier
            )
        }
    }

    private static func makeWindowCandidate(
        baseApp: LaunchableApp,
        title: String,
        identityKey: String,
        frame: WindowFrame?,
        windowIdentifier: UInt32?
    ) -> LaunchableApp {
        let searchText = [
            title,
            baseApp.name,
            baseApp.applicationName,
            baseApp.bundleIdentifier,
            baseApp.url?.lastPathComponent,
            baseApp.url?.path,
            "window",
            "running"
        ]
            .compactMap { $0 }
            .joined(separator: " ")

        return LaunchableApp(
            name: title,
            applicationName: baseApp.applicationName ?? baseApp.name,
            url: baseApp.url,
            bundleIdentifier: baseApp.bundleIdentifier,
            searchText: searchText,
            identityKey: identityKey,
            historyKey: baseApp.historyKey,
            processIdentifier: baseApp.processIdentifier,
            isRunning: true,
            targetKind: .window,
            windowTitle: title,
            windowFrame: frame,
            windowIdentifier: windowIdentifier
        )
    }

    private static func accessibilityWindows(in applicationElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )

        guard error == .success, let windows = value as? [AXUIElement] else {
            return []
        }

        return windows
    }

    private static func accessibilityTitle(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resourceName(for url: URL) -> String? {
        try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName
    }
}

private struct LaunchHistoryEntry: Codable {
    var count: Int
    var lastLaunchedAt: Date
}

final class LaunchHistoryStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let legacyFileURL: URL
    private var entries: [String: LaunchHistoryEntry] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupportURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ??
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        self.fileURL = applicationSupportURL
            .appendingPathComponent("Tendon", isDirectory: true)
            .appendingPathComponent("launch-history.json")
        self.legacyFileURL = applicationSupportURL
            .appendingPathComponent("TakoLauncher", isDirectory: true)
            .appendingPathComponent("launch-history.json")

        load()
    }

    func recordLaunch(of app: LaunchableApp) {
        var entry = entries[app.historyKey] ?? LaunchHistoryEntry(
            count: 0,
            lastLaunchedAt: .distantPast
        )

        entry.count += 1
        entry.lastLaunchedAt = Date()
        entries[app.historyKey] = entry
        save()
    }

    func sort(_ apps: [LaunchableApp]) -> [LaunchableApp] {
        apps.sorted { lhs, rhs in
            let lhsEntry = entries[lhs.historyKey]
            let rhsEntry = entries[rhs.historyKey]
            let lhsCount = lhsEntry?.count ?? 0
            let rhsCount = rhsEntry?.count ?? 0

            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }

            let lhsLastLaunchedAt = lhsEntry?.lastLaunchedAt ?? .distantPast
            let rhsLastLaunchedAt = rhsEntry?.lastLaunchedAt ?? .distantPast

            if lhsLastLaunchedAt != rhsLastLaunchedAt {
                return lhsLastLaunchedAt > rhsLastLaunchedAt
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func load() {
        if let decodedEntries = entries(from: fileURL) {
            entries = decodedEntries
            return
        }

        if let decodedEntries = entries(from: legacyFileURL) {
            entries = decodedEntries
            save()
            return
        }

        entries = [:]
    }

    private func entries(from fileURL: URL) -> [String: LaunchHistoryEntry]? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decodedEntries = try? JSONDecoder().decode([String: LaunchHistoryEntry].self, from: data)
        else {
            return nil
        }

        return decodedEntries
    }

    private func save() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("Failed to save launch history: \(error.localizedDescription)\n", stderr)
        }
    }
}

enum WindowActivator {
    private struct AXWindowsLookup {
        let windows: [AXUIElement]
        let error: AXError
        let valueDescription: String
        let source: String
        let manualAccessibilityError: AXError?
        let childrenError: AXError?
        let childrenValueDescription: String?
        let childrenVisitedCount: Int?
    }

    private struct AXElementArrayLookup {
        let elements: [AXUIElement]
        let error: AXError
        let valueDescription: String
    }

    private struct AXChildrenWindowLookup {
        let windows: [AXUIElement]
        let error: AXError
        let valueDescription: String
        let visitedCount: Int
    }

    private struct AXElementLookup {
        let element: AXUIElement?
        let error: AXError
        let valueDescription: String
    }

    private struct AXMenuItemSearchResult {
        let item: AXUIElement?
        let visitedCount: Int
        let visibleTitles: [String]
    }

    private enum WindowMenuFallbackActivationMode {
        case direct
        case activateFirst

        var logLabel: String {
            switch self {
            case .direct:
                return "direct"
            case .activateFirst:
                return "activated"
            }
        }
    }

    static func activate(
        _ app: LaunchableApp,
        previousFrontmostProcessIdentifier: pid_t?,
        previousFrontmostWindowTitle: String?
    ) -> Bool {
        switch app.targetKind {
        case .application:
            return activateApplication(
                for: app,
                previousFrontmostProcessIdentifier: previousFrontmostProcessIdentifier,
                previousFrontmostWindowTitle: previousFrontmostWindowTitle
            )
        case .window:
            return activateWindow(for: app)
        }
    }

    static func frontmostWindowTitle(for processIdentifier: pid_t) -> String? {
        accessibilityFocusedWindowTitle(for: processIdentifier) ?? CoreGraphicsWindowReader.candidateWindows().first {
            $0.ownerProcessIdentifier == processIdentifier && $0.hasTitle
        }?.title
    }

    private static func activateApplication(
        for app: LaunchableApp,
        previousFrontmostProcessIdentifier: pid_t?,
        previousFrontmostWindowTitle: String?
    ) -> Bool {
        var lines = [
            "context: application candidate",
            "candidate: \(app.name)",
            "previous pid: \(previousFrontmostProcessIdentifier.map(String.init) ?? "nil")",
            "previous title: \(previousFrontmostWindowTitle ?? "nil")"
        ]

        guard
            app.isRunning,
            let processIdentifier = app.processIdentifier
        else {
            lines.append("result: skipped, candidate is not a running app with pid")
            recordActivation(lines)
            return false
        }

        lines.append("target pid: \(processIdentifier)")

        guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            lines.append("result: skipped, NSRunningApplication not found")
            recordActivation(lines)
            return false
        }

        runningApplication.unhide()

        guard AXIsProcessTrusted() else {
            WindowPermissionManager.requestAccessibilityPermission()
            let activated = runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            lines.append("result: accessibility not trusted, fallback activate \(activated ? "true" : "false")")
            recordActivation(lines)
            return activated
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let windowsLookup = windowsResult(in: applicationElement, enableManualAccessibility: true)
        let windows = windowsLookup.windows
        let targetWindows = candidateApplicationWindows(in: windows)
        let shouldCycleWindow = previousFrontmostProcessIdentifier == processIdentifier
        let coreGraphicsTitles = coreGraphicsWindowTitles(for: processIdentifier)

        lines.append("same app as previous: \(shouldCycleWindow ? "true" : "false")")
        lines.append("AXManualAccessibility set: \(formatOptionalError(windowsLookup.manualAccessibilityError))")
        lines.append("AX windows copy error: \(describe(windowsLookup.error))")
        lines.append("AX windows value: \(windowsLookup.valueDescription)")
        lines.append("AX windows source: \(windowsLookup.source)")
        lines.append("AX children copy error: \(formatOptionalError(windowsLookup.childrenError))")
        lines.append("AX children value: \(windowsLookup.childrenValueDescription ?? "not attempted")")
        lines.append("AX children visited: \(windowsLookup.childrenVisitedCount.map(String.init) ?? "not attempted")")
        lines.append("AX windows: \(windows.count)")
        lines.append("AX titled windows: \(targetWindows.count)")
        lines.append("CG titles: \(formatTitles(coreGraphicsTitles))")

        let targetWindow = targetApplicationWindow(
            in: targetWindows,
            processIdentifier: processIdentifier,
            applicationElement: applicationElement,
            shouldCycleWindow: shouldCycleWindow,
            previousFrontmostWindowTitle: previousFrontmostWindowTitle
        )

        guard let targetWindow else {
            let activated = runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            lines.append("result: no target AX window, fallback activate \(activated ? "true" : "false")")
            recordActivation(lines)
            return activated
        }

        raise(
            targetWindow,
            in: applicationElement,
            runningApplication: runningApplication,
            context: "application candidate",
            processIdentifier: processIdentifier,
            prefixLines: lines
        )
        return true
    }

    private static func activateWindow(for app: LaunchableApp) -> Bool {
        var lines = [
            "context: window candidate",
            "candidate: \(app.name)",
            "candidate window title: \(app.windowTitle ?? "nil")",
            "candidate window id: \(formatIdentifier(app.windowIdentifier))",
            "candidate frame: \(formatFrame(app.windowFrame))"
        ]

        guard
            app.targetKind == .window,
            let processIdentifier = app.processIdentifier
        else {
            lines.append("result: skipped, candidate is not a window with pid")
            recordActivation(lines)
            return false
        }

        lines.append("target pid: \(processIdentifier)")

        guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            lines.append("result: skipped, NSRunningApplication not found")
            recordActivation(lines)
            return false
        }

        runningApplication.unhide()

        guard AXIsProcessTrusted() else {
            WindowPermissionManager.requestAccessibilityPermission()
            let activated = runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            lines.append("result: accessibility not trusted, fallback activate \(activated ? "true" : "false")")
            recordActivation(lines)
            return false
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let windowsLookup = windowsResult(in: applicationElement, enableManualAccessibility: true)
        let axWindows = windowsLookup.windows
        lines.append("AX window id symbol: \(AccessibilityWindowIdentity.availabilityDescription)")
        lines.append("AXManualAccessibility set: \(formatOptionalError(windowsLookup.manualAccessibilityError))")
        lines.append("AX windows copy error: \(describe(windowsLookup.error))")
        lines.append("AX windows value: \(windowsLookup.valueDescription)")
        lines.append("AX windows source: \(windowsLookup.source)")
        lines.append("AX children copy error: \(formatOptionalError(windowsLookup.childrenError))")
        lines.append("AX children value: \(windowsLookup.childrenValueDescription ?? "not attempted")")
        lines.append("AX children visited: \(windowsLookup.childrenVisitedCount.map(String.init) ?? "not attempted")")
        lines.append("AX windows: \(axWindows.count)")
        lines.append("AX frames: \(formatAXWindows(axWindows))")

        var targetWindow = findWindow(
            in: axWindows,
            matching: app.windowTitle,
            identifier: app.windowIdentifier,
            frame: app.windowFrame
        )

        if targetWindow == nil, windowsLookup.source != "AXChildren" {
            let childrenLookup = childWindows(in: applicationElement)
            lines.append("secondary AX children copy error: \(describe(childrenLookup.error))")
            lines.append("secondary AX children value: \(childrenLookup.valueDescription)")
            lines.append("secondary AX children visited: \(childrenLookup.visitedCount)")
            lines.append("secondary AX children windows: \(childrenLookup.windows.count)")
            lines.append("secondary AX children frames: \(formatAXWindows(childrenLookup.windows))")
            targetWindow = findWindow(
                in: childrenLookup.windows,
                matching: app.windowTitle,
                identifier: app.windowIdentifier,
                frame: app.windowFrame
            )
        }

        if targetWindow == nil {
            targetWindow = hitTestWindow(for: app, processIdentifier: processIdentifier, lines: &lines)
        }

        if targetWindow == nil,
            pressWindowMenuItem(
                for: app,
                in: applicationElement,
                runningApplication: runningApplication,
                lines: &lines
            ) {
            recordActivation(lines)
            return true
        }

        guard let targetWindow else {
            lines.append("result: target AX window not found")
            recordActivation(lines)
            return false
        }

        raise(
            targetWindow,
            in: applicationElement,
            runningApplication: runningApplication,
            context: "window candidate",
            processIdentifier: processIdentifier,
            prefixLines: lines
        )

        return true
    }

    private static func targetApplicationWindow(
        in windows: [AXUIElement],
        processIdentifier: pid_t,
        applicationElement: AXUIElement,
        shouldCycleWindow: Bool,
        previousFrontmostWindowTitle: String?
    ) -> AXUIElement? {
        guard !windows.isEmpty else {
            return nil
        }

        guard shouldCycleWindow, windows.count > 1 else {
            return focusedWindow(in: applicationElement) ?? windows.first
        }

        if
            let previousFrontmostWindowTitle,
            let nextWindowTitle = nextWindowTitle(
                after: previousFrontmostWindowTitle,
                for: processIdentifier
            ),
            let nextWindow = findWindow(in: windows, matching: nextWindowTitle) {
            return nextWindow
        }

        if
            let previousFrontmostWindowTitle,
            let previousIndex = firstWindowIndex(in: windows, matching: previousFrontmostWindowTitle) {
            return windows[(previousIndex + 1) % windows.count]
        }

        guard
            let focusedWindow = focusedWindow(in: applicationElement),
            let focusedIndex = windows.firstIndex(where: { CFEqual($0, focusedWindow) })
        else {
            return windows.dropFirst().first ?? windows.first
        }

        return windows[(focusedIndex + 1) % windows.count]
    }

    private static func nextWindowTitle(after currentTitle: String, for processIdentifier: pid_t) -> String? {
        let orderedTitles = deduplicate(
            CoreGraphicsWindowReader.candidateWindows()
                .filter { $0.ownerProcessIdentifier == processIdentifier && $0.hasTitle }
                .compactMap(\.title)
        )

        guard orderedTitles.count > 1 else {
            return nil
        }

        guard let currentIndex = orderedTitles.firstIndex(where: { titlesMatch($0, currentTitle) }) else {
            return orderedTitles.first
        }

        return orderedTitles[(currentIndex + 1) % orderedTitles.count]
    }

    private static func deduplicate(_ titles: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for title in titles {
            let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            result.append(title)
        }

        return result
    }

    private static func firstWindowIndex(in windows: [AXUIElement], matching targetTitle: String) -> Int? {
        if let exactMatch = windows.firstIndex(where: { title(of: $0) == targetTitle }) {
            return exactMatch
        }

        return windows.firstIndex { window in
            guard let windowTitle = title(of: window) else {
                return false
            }

            return titlesMatch(windowTitle, targetTitle)
        }
    }

    private static func candidateApplicationWindows(in windows: [AXUIElement]) -> [AXUIElement] {
        let titledWindows = windows.filter { window in
            title(of: window)?.isEmpty == false
        }

        return titledWindows.isEmpty ? windows : titledWindows
    }

    private static func raise(
        _ targetWindow: AXUIElement,
        in applicationElement: AXUIElement,
        runningApplication: NSRunningApplication,
        context: String,
        processIdentifier: pid_t,
        prefixLines: [String] = []
    ) {
        let targetTitle = title(of: targetWindow) ?? "(untitled)"
        var lines = prefixLines + [
            "activation context: \(context)",
            "activation pid: \(processIdentifier)",
            "target title: \(targetTitle)"
        ]

        let unminimizeError = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        lines.append("set AXMinimized=false: \(describe(unminimizeError))")

        let mainError = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        lines.append("set window AXMain=true: \(describe(mainError))")

        let focusedError = AXUIElementSetAttributeValue(
            targetWindow,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        lines.append("set window AXFocused=true: \(describe(focusedError))")

        let mainWindowError = AXUIElementSetAttributeValue(
            applicationElement,
            kAXMainWindowAttribute as CFString,
            targetWindow
        )
        lines.append("set app AXMainWindow: \(describe(mainWindowError))")

        let focusedWindowError = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            targetWindow
        )
        lines.append("set app AXFocusedWindow: \(describe(focusedWindowError))")

        let preActivationRaiseError = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        lines.append("perform AXRaise before app activation: \(describe(preActivationRaiseError))")

        let frontmostError = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        lines.append("set app AXFrontmost=true: \(describe(frontmostError))")

        let activated = runningApplication.activate(options: [.activateIgnoringOtherApps])
        lines.append("NSRunningApplication.activate: \(activated ? "true" : "false")")

        let postActivationRaiseError = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        lines.append("perform AXRaise after app activation: \(describe(postActivationRaiseError))")

        recordActivation(lines)
    }

    private static func findWindow(
        in windows: [AXUIElement],
        matching targetTitle: String?,
        identifier targetIdentifier: UInt32? = nil,
        frame targetFrame: WindowFrame? = nil
    ) -> AXUIElement? {
        if
            let targetIdentifier,
            let identifierMatch = windows.first(where: {
                AccessibilityWindowIdentity.identifier(of: $0) == targetIdentifier
            }) {
            return identifierMatch
        }

        let fallbackWindows: [AXUIElement]
        if targetIdentifier == nil {
            fallbackWindows = windows
        } else {
            fallbackWindows = windows.filter {
                AccessibilityWindowIdentity.identifier(of: $0) == nil
            }
        }

        if let targetTitle, let exactMatch = fallbackWindows.first(where: { title(of: $0) == targetTitle }) {
            return exactMatch
        }

        if let targetTitle {
            return fallbackWindows.first { window in
                guard let windowTitle = title(of: window) else {
                    return false
                }

                return titlesAreCompatible(windowTitle, targetTitle)
            }
        }

        if
            targetIdentifier == nil,
            let frameMatch = findWindow(in: fallbackWindows, matching: targetFrame) {
            return frameMatch
        }

        if targetIdentifier == nil {
            return fallbackWindows.first
        }

        return nil
    }

    private static func findWindow(in windows: [AXUIElement], matching targetFrame: WindowFrame?) -> AXUIElement? {
        guard let targetFrame else {
            return nil
        }

        return windows
            .compactMap { window -> (AXUIElement, Double)? in
                guard let frame = AccessibilityWindowGeometry.frame(of: window) else {
                    return nil
                }

                return (window, frameDistance(frame, targetFrame))
            }
            .filter { _, distance in distance <= 96 }
            .min { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private static func titlesAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
        titlesMatch(lhs, rhs) ||
            lhs.localizedCaseInsensitiveContains(rhs) ||
            rhs.localizedCaseInsensitiveContains(lhs)
    }

    private static func hitTestWindow(
        for app: LaunchableApp,
        processIdentifier: pid_t,
        lines: inout [String]
    ) -> AXUIElement? {
        guard let frame = app.windowFrame else {
            lines.append("AX hit test: skipped, no candidate frame")
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        let points = hitTestPoints(in: frame)

        for (index, point) in points.enumerated() {
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(
                systemWideElement,
                Float(point.x),
                Float(point.y),
                &element
            )
            lines.append("AX hit test \(index) at x:\(Int(point.x)) y:\(Int(point.y)): \(describe(error))")

            guard error == .success, let element else {
                continue
            }

            let elementPID = pid(of: element)
            let elementRole = role(of: element) ?? "nil"
            let elementTitle = title(of: element) ?? "(untitled)"
            lines.append(
                "AX hit test element: pid \(formatPID(elementPID)) role \(elementRole) title \(elementTitle)"
            )

            guard let window = relatedWindow(of: element) else {
                lines.append("AX hit test result: no related AX window")
                continue
            }

            let windowPID = pid(of: window)
            let windowIdentifierLookup = AccessibilityWindowIdentity.lookup(of: window)
            let windowTitle = title(of: window) ?? "(untitled)"
            lines.append(
                "AX hit test window: pid \(formatPID(windowPID)) id \(formatWindowIdentifierLookup(windowIdentifierLookup)) title \(windowTitle) frame \(formatFrame(AccessibilityWindowGeometry.frame(of: window)))"
            )

            guard windowPID == processIdentifier else {
                lines.append("AX hit test rejected: pid mismatch")
                continue
            }

            guard windowMatchesTarget(window, title: app.windowTitle, identifier: app.windowIdentifier) else {
                lines.append("AX hit test rejected: target id/title mismatch")
                continue
            }

            lines.append("AX hit test result: matched target window")
            return window
        }

        lines.append("AX hit test result: no matched window")
        return nil
    }

    private static func pressWindowMenuItem(
        for app: LaunchableApp,
        in applicationElement: AXUIElement,
        runningApplication: NSRunningApplication,
        lines: inout [String]
    ) -> Bool {
        guard let targetTitle = app.windowTitle else {
            lines.append("Window menu fallback: skipped, no target title")
            return false
        }

        if pressWindowMenuItemAttempt(
            targetTitle: targetTitle,
            in: applicationElement,
            runningApplication: runningApplication,
            activationMode: .direct,
            lines: &lines
        ) {
            return true
        }

        lines.append("Window menu fallback: direct attempt failed, retrying after app activation")
        return pressWindowMenuItemAttempt(
            targetTitle: targetTitle,
            in: applicationElement,
            runningApplication: runningApplication,
            activationMode: .activateFirst,
            lines: &lines
        )
    }

    private static func pressWindowMenuItemAttempt(
        targetTitle: String,
        in applicationElement: AXUIElement,
        runningApplication: NSRunningApplication,
        activationMode: WindowMenuFallbackActivationMode,
        lines: inout [String]
    ) -> Bool {
        switch activationMode {
        case .direct:
            lines.append("Window menu fallback direct: skipped explicit app activation")
        case .activateFirst:
            let frontmostError = AXUIElementSetAttributeValue(
                applicationElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
            lines.append("Window menu fallback activated set app AXFrontmost=true: \(describe(frontmostError))")

            let activated = runningApplication.activate(options: [.activateIgnoringOtherApps])
            lines.append("Window menu fallback activated activate app: \(activated ? "true" : "false")")
            Thread.sleep(forTimeInterval: 0.18)
        }

        let menuBarLookup = elementAttribute(
            kAXMenuBarAttribute as CFString,
            of: applicationElement
        )
        lines.append(
            "Window menu fallback \(activationMode.logLabel) menu bar: \(describe(menuBarLookup.error)) \(menuBarLookup.valueDescription)"
        )

        guard let menuBar = menuBarLookup.element else {
            lines.append("Window menu fallback \(activationMode.logLabel) result: no menu bar")
            return false
        }

        let menuBarItemsLookup = elementArray(
            attribute: kAXChildrenAttribute as CFString,
            of: menuBar
        )
        let menuBarItems = menuBarItemsLookup.elements
        let menuBarTitles = menuBarItems.compactMap { title(of: $0) }
        lines.append("Window menu fallback \(activationMode.logLabel) menu bar items: \(formatTitles(menuBarTitles))")

        let windowMenuItems = menuBarItems.filter {
            title(of: $0).map(isWindowMenuTitle) == true
        }

        guard !windowMenuItems.isEmpty else {
            lines.append("Window menu fallback \(activationMode.logLabel) result: Window menu not found")
            return false
        }

        for windowMenuItem in windowMenuItems {
            let windowMenuTitle = title(of: windowMenuItem) ?? "(untitled)"
            let initialSearch = menuItem(in: windowMenuItem, matching: targetTitle)
            lines.append(
                "Window menu fallback \(activationMode.logLabel) initial search in \(windowMenuTitle): visited \(initialSearch.visitedCount), titles \(formatTitles(initialSearch.visibleTitles))"
            )

            if let item = initialSearch.item {
                return pressMenuItem(
                    item,
                    targetTitle: targetTitle,
                    source: "\(activationMode.logLabel) initial",
                    runningApplication: runningApplication,
                    lines: &lines
                )
            }

            guard activationMode == .activateFirst else {
                lines.append("Window menu fallback direct: target not visible without opening menu")
                continue
            }

            let openError = AXUIElementPerformAction(windowMenuItem, kAXPressAction as CFString)
            lines.append("Window menu fallback activated open \(windowMenuTitle): \(describe(openError))")
            Thread.sleep(forTimeInterval: 0.12)

            let openedSearch = menuItem(in: windowMenuItem, matching: targetTitle)
            lines.append(
                "Window menu fallback activated opened search in \(windowMenuTitle): visited \(openedSearch.visitedCount), titles \(formatTitles(openedSearch.visibleTitles))"
            )

            if let item = openedSearch.item {
                return pressMenuItem(
                    item,
                    targetTitle: targetTitle,
                    source: "activated opened",
                    runningApplication: runningApplication,
                    lines: &lines
                )
            }
        }

        lines.append("Window menu fallback \(activationMode.logLabel) result: no matching menu item")
        return false
    }

    private static func pressMenuItem(
        _ menuItem: AXUIElement,
        targetTitle: String,
        source: String,
        runningApplication: NSRunningApplication,
        lines: inout [String]
    ) -> Bool {
        let menuItemTitle = title(of: menuItem) ?? "(untitled)"
        let pressError = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        lines.append(
            "Window menu fallback press \(source): target \(targetTitle), item \(menuItemTitle), \(describe(pressError))"
        )

        guard pressError == .success else {
            lines.append("Window menu fallback result: press failed")
            return false
        }

        Thread.sleep(forTimeInterval: 0.45)
        var observedFrontmostProcessIdentifier = frontmostProcessIdentifier()
        var observedTitle = frontmostWindowTitle(for: runningApplication.processIdentifier)
        lines.append(
            "Window menu fallback observed after press: frontmost pid \(formatPID(observedFrontmostProcessIdentifier)), title \(observedTitle ?? "nil")"
        )

        if observedFrontmostProcessIdentifier != runningApplication.processIdentifier {
            let activated = runningApplication.activate(options: [.activateIgnoringOtherApps])
            lines.append("Window menu fallback activate after press: \(activated ? "true" : "false")")
            Thread.sleep(forTimeInterval: 0.18)
            observedFrontmostProcessIdentifier = frontmostProcessIdentifier()
            observedTitle = frontmostWindowTitle(for: runningApplication.processIdentifier)
            lines.append(
                "Window menu fallback observed after activate: frontmost pid \(formatPID(observedFrontmostProcessIdentifier)), title \(observedTitle ?? "nil")"
            )
        }

        guard
            observedFrontmostProcessIdentifier == runningApplication.processIdentifier,
            let observedTitle,
            menuItemTitleMatches(observedTitle, targetTitle)
        else {
            lines.append("Window menu fallback result: press succeeded but target app/title not observed")
            return false
        }

        lines.append("Window menu fallback result: pressed and observed matching Window menu item")
        return true
    }

    private static func menuItem(in root: AXUIElement, matching targetTitle: String) -> AXMenuItemSearchResult {
        var queue = [(root, 0)]
        var visibleTitles: [String] = []
        var visitedCount = 0
        let maxDepth = 8
        let maxVisitedCount = 700

        while !queue.isEmpty, visitedCount < maxVisitedCount {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1

            let elementRole = role(of: element)
            if
                elementRole == (kAXMenuItemRole as String),
                let elementTitle = title(of: element),
                !elementTitle.isEmpty {
                visibleTitles.append(elementTitle)

                if menuItemTitleMatches(elementTitle, targetTitle), isEnabled(element) {
                    return AXMenuItemSearchResult(
                        item: element,
                        visitedCount: visitedCount,
                        visibleTitles: visibleTitles
                    )
                }
            }

            guard depth < maxDepth else {
                continue
            }

            let childrenLookup = elementArray(
                attribute: kAXChildrenAttribute as CFString,
                of: element
            )
            queue.append(contentsOf: childrenLookup.elements.map { ($0, depth + 1) })
        }

        return AXMenuItemSearchResult(
            item: nil,
            visitedCount: visitedCount,
            visibleTitles: visibleTitles
        )
    }

    private static func hitTestPoints(in frame: WindowFrame) -> [CGPoint] {
        let insetX = min(max(frame.width * 0.08, 32), max(frame.width / 2, 1))
        let insetY = min(max(frame.height * 0.08, 32), max(frame.height / 2, 1))

        return [
            CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2),
            CGPoint(x: frame.x + insetX, y: frame.y + insetY),
            CGPoint(x: frame.x + frame.width - insetX, y: frame.y + insetY)
        ]
    }

    private static func relatedWindow(of element: AXUIElement) -> AXUIElement? {
        if role(of: element) == (kAXWindowRole as String) {
            return element
        }

        return axElementAttribute("AXWindow" as CFString, of: element) ??
            axElementAttribute("AXTopLevelUIElement" as CFString, of: element)
    }

    private static func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXElementLookup {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard error == .success else {
            return AXElementLookup(
                element: nil,
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        guard
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return AXElementLookup(
                element: nil,
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        return AXElementLookup(
            element: (value as! AXUIElement),
            error: error,
            valueDescription: "AXUIElement"
        )
    }

    private static func axElementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard
            error == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func isWindowMenuTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.compare("Window", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
            normalized.compare("Windows", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
            normalized == "ウインドウ" ||
            normalized == "ウィンドウ"
    }

    private static func menuItemTitleMatches(_ menuItemTitle: String, _ targetTitle: String) -> Bool {
        let normalizedMenuItemTitle = normalizedWindowMenuTitle(menuItemTitle)
        let normalizedTargetTitle = normalizedWindowMenuTitle(targetTitle)

        guard !normalizedMenuItemTitle.isEmpty, !normalizedTargetTitle.isEmpty else {
            return false
        }

        return normalizedMenuItemTitle == normalizedTargetTitle ||
            normalizedMenuItemTitle.contains(normalizedTargetTitle) ||
            normalizedTargetTitle.contains(normalizedMenuItemTitle)
    }

    private static func normalizedWindowMenuTitle(_ title: String) -> String {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = normalized.first, "✓✔•".contains(first) {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let shortcutRange = normalized.range(
            of: #"^\d+[\.)]?\s+"#,
            options: .regularExpression
        ) {
            normalized.removeSubrange(shortcutRange)
        }

        return normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func windowMatchesTarget(
        _ window: AXUIElement,
        title targetTitle: String?,
        identifier targetIdentifier: UInt32?
    ) -> Bool {
        if
            let targetIdentifier {
            let lookup = AccessibilityWindowIdentity.lookup(of: window)

            if let identifier = lookup.identifier {
                return identifier == targetIdentifier
            }
        }

        if
            let targetTitle,
            let windowTitle = title(of: window) {
            return titlesAreCompatible(windowTitle, targetTitle)
        }

        return targetTitle == nil && targetIdentifier == nil
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &value
        )

        guard error == .success else {
            return true
        }

        return (value as? Bool) ?? true
    }

    private static func coreGraphicsWindowTitles(for processIdentifier: pid_t) -> [String] {
        deduplicate(
            CoreGraphicsWindowReader.candidateWindows()
                .filter { $0.ownerProcessIdentifier == processIdentifier && $0.hasTitle }
                .compactMap(\.title)
        )
    }

    private static func formatTitles(_ titles: [String]) -> String {
        guard !titles.isEmpty else {
            return "none"
        }

        return titles.prefix(6).joined(separator: " | ")
    }

    private static func formatAXWindows(_ windows: [AXUIElement]) -> String {
        guard !windows.isEmpty else {
            return "none"
        }

        return windows.prefix(6).map { window in
            let windowTitle = title(of: window) ?? "(untitled)"
            let identifierLookup = AccessibilityWindowIdentity.lookup(of: window)
            return "pid:\(formatPID(pid(of: window))) id:\(formatWindowIdentifierLookup(identifierLookup)) \(windowTitle) \(formatFrame(AccessibilityWindowGeometry.frame(of: window)))"
        }.joined(separator: " | ")
    }

    private static func formatIdentifier(_ identifier: UInt32?) -> String {
        identifier.map(String.init) ?? "nil"
    }

    private static func formatWindowIdentifierLookup(_ lookup: AccessibilityWindowIdentifierLookup) -> String {
        if let identifier = lookup.identifier {
            return "\(identifier) via \(lookup.symbolName ?? "unknown")"
        }

        if let error = lookup.error {
            return "nil via \(lookup.symbolName ?? "unknown") \(describe(error))"
        }

        return "nil (symbol unavailable)"
    }

    private static func formatPID(_ processIdentifier: pid_t?) -> String {
        processIdentifier.map(String.init) ?? "nil"
    }

    private static func formatFrame(_ frame: WindowFrame?) -> String {
        guard let frame else {
            return "nil"
        }

        return "x:\(Int(frame.x)) y:\(Int(frame.y)) w:\(Int(frame.width)) h:\(Int(frame.height))"
    }

    private static func frameDistance(_ lhs: WindowFrame, _ rhs: WindowFrame) -> Double {
        abs(lhs.x - rhs.x) +
            abs(lhs.y - rhs.y) +
            abs(lhs.width - rhs.width) +
            abs(lhs.height - rhs.height)
    }

    private static func describe(_ error: AXError) -> String {
        error == .success ? "success" : "error \(error.rawValue)"
    }

    private static func formatOptionalError(_ error: AXError?) -> String {
        error.map(describe) ?? "not attempted"
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var processIdentifier = pid_t(0)
        let error = AXUIElementGetPid(element, &processIdentifier)

        guard error == .success else {
            return nil
        }

        return processIdentifier
    }

    private static func frontmostProcessIdentifier() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func recordActivation(_ lines: [String]) {
        AppLog.write("window_activation", [
            "lines": lines
        ])
    }

    private static func windowsResult(
        in applicationElement: AXUIElement,
        enableManualAccessibility: Bool = false
    ) -> AXWindowsLookup {
        let manualAccessibilityError: AXError?

        if enableManualAccessibility {
            manualAccessibilityError = AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            Thread.sleep(forTimeInterval: 0.12)
        } else {
            manualAccessibilityError = nil
        }

        let directLookup = elementArray(
            attribute: kAXWindowsAttribute as CFString,
            of: applicationElement
        )

        if !directLookup.elements.isEmpty {
            return AXWindowsLookup(
                windows: directLookup.elements,
                error: directLookup.error,
                valueDescription: directLookup.valueDescription,
                source: "AXWindows",
                manualAccessibilityError: manualAccessibilityError,
                childrenError: nil,
                childrenValueDescription: nil,
                childrenVisitedCount: nil
            )
        }

        let childrenLookup = childWindows(in: applicationElement)
        if !childrenLookup.windows.isEmpty {
            return AXWindowsLookup(
                windows: childrenLookup.windows,
                error: directLookup.error,
                valueDescription: directLookup.valueDescription,
                source: "AXChildren",
                manualAccessibilityError: manualAccessibilityError,
                childrenError: childrenLookup.error,
                childrenValueDescription: childrenLookup.valueDescription,
                childrenVisitedCount: childrenLookup.visitedCount
            )
        }

        return AXWindowsLookup(
            windows: [],
            error: directLookup.error,
            valueDescription: directLookup.valueDescription,
            source: "none",
            manualAccessibilityError: manualAccessibilityError,
            childrenError: childrenLookup.error,
            childrenValueDescription: childrenLookup.valueDescription,
            childrenVisitedCount: childrenLookup.visitedCount
        )
    }

    private static func elementArray(attribute: CFString, of element: AXUIElement) -> AXElementArrayLookup {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )

        guard error == .success else {
            return AXElementArrayLookup(
                elements: [],
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        guard let elements = value as? [AXUIElement] else {
            return AXElementArrayLookup(
                elements: [],
                error: error,
                valueDescription: describeAXValue(value)
            )
        }

        return AXElementArrayLookup(
            elements: elements,
            error: error,
            valueDescription: "AXUIElement array count \(elements.count)"
        )
    }

    private static func childWindows(in applicationElement: AXUIElement) -> AXChildrenWindowLookup {
        let rootChildrenLookup = elementArray(
            attribute: kAXChildrenAttribute as CFString,
            of: applicationElement
        )
        var queue = rootChildrenLookup.elements.map { ($0, 1) }
        var windows: [AXUIElement] = []
        var visitedCount = 0
        let maxDepth = 7
        let maxVisitedCount = 500

        while !queue.isEmpty, visitedCount < maxVisitedCount {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1

            if role(of: element) == (kAXWindowRole as String) {
                windows.append(element)
                continue
            }

            guard depth < maxDepth else {
                continue
            }

            let childrenLookup = elementArray(
                attribute: kAXChildrenAttribute as CFString,
                of: element
            )
            queue.append(contentsOf: childrenLookup.elements.map { ($0, depth + 1) })
        }

        return AXChildrenWindowLookup(
            windows: windows,
            error: rootChildrenLookup.error,
            valueDescription: rootChildrenLookup.valueDescription,
            visitedCount: visitedCount
        )
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        return value as? String
    }

    private static func describeAXValue(_ value: CFTypeRef?) -> String {
        guard let value else {
            return "nil"
        }

        if let array = value as? [Any] {
            return "array count \(array.count)"
        }

        return String(describing: type(of: value))
    }

    private static func accessibilityFocusedWindowTitle(for processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        return focusedWindow(in: applicationElement).flatMap { title(of: $0) }
    }

    private static func focusedWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        guard let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        )

        guard error == .success else {
            return nil
        }

        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

enum WindowPermissionManager {
    private static var isStartupPermissionSequenceRunning = false
    private static var permissionPollTimer: Timer?

    static func requestStartupPermissions() {
        guard !isStartupPermissionSequenceRunning else {
            return
        }

        guard !isScreenRecordingGranted || !isAccessibilityGranted else {
            return
        }

        isStartupPermissionSequenceRunning = true
        requestScreenRecordingPermission {
            requestAccessibilityPermission {
                isStartupPermissionSequenceRunning = false
            }
        }
    }

    static func requestAccessibilityPermission() {
        requestAccessibilityPermission(onGranted: nil)
    }

    private static func requestAccessibilityPermission(onGranted: (() -> Void)?) {
        guard !isAccessibilityGranted else {
            onGranted?()
            return
        }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        AXIsProcessTrustedWithOptions(options)

        if let onGranted {
            waitUntil({ isAccessibilityGranted }, then: onGranted)
        }
    }

    private static func requestScreenRecordingPermission(onGranted: (() -> Void)?) {
        guard !isScreenRecordingGranted else {
            onGranted?()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )

                await MainActor.run {
                    onGranted?()
                }
            } catch {
                await MainActor.run {
                    if !isScreenRecordingGranted {
                        openScreenRecordingSettings()
                    }

                    if let onGranted {
                        waitUntil({ isScreenRecordingGranted }, then: onGranted)
                    }
                }
            }
        }
    }

    private static func waitUntil(_ isGranted: @escaping () -> Bool, then onGranted: @escaping () -> Void) {
        guard !isGranted() else {
            onGranted()
            return
        }

        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard isGranted() else {
                return
            }

            timer.invalidate()
            permissionPollTimer = nil
            onGranted()
        }
    }

    private static func openScreenRecordingSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }
}

private enum LauncherKey {
    static let a: UInt16 = 0
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let n: UInt16 = 45
    static let p: UInt16 = 35
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    static func isControlPressed(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.control)
    }

    static func isCommandPressed(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
    }
}

final class LauncherSearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard LauncherKey.isCommandPressed(event), event.keyCode == LauncherKey.a else {
            return super.performKeyEquivalent(with: event)
        }

        if let editor = currentEditor() {
            editor.selectAll(nil)
        } else {
            selectText(nil)
        }

        return true
    }

    override func keyDown(with event: NSEvent) {
        if LauncherKey.isControlPressed(event) {
            switch event.keyCode {
            case LauncherKey.n:
                onMoveSelection?(1)
            case LauncherKey.p:
                onMoveSelection?(-1)
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case LauncherKey.returnKey, LauncherKey.keypadEnter:
            onSubmit?()
        case LauncherKey.escape:
            onCancel?()
        case LauncherKey.downArrow:
            onMoveSelection?(1)
        case LauncherKey.upArrow:
            onMoveSelection?(-1)
        default:
            super.keyDown(with: event)
        }
    }
}

final class LauncherTableView: NSTableView {
    var onMoveSelection: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if LauncherKey.isControlPressed(event) {
            switch event.keyCode {
            case LauncherKey.n:
                onMoveSelection?(1)
            case LauncherKey.p:
                onMoveSelection?(-1)
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case LauncherKey.returnKey, LauncherKey.keypadEnter:
            onSubmit?()
        case LauncherKey.escape:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class LauncherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else {
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        let selectedRect = bounds.insetBy(dx: 6, dy: 3)
        NSBezierPath(roundedRect: selectedRect, xRadius: 8, yRadius: 8).fill()
    }
}

final class AppCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppCellView")

    private let appIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with app: LaunchableApp) {
        if let url = app.url {
            appIconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else if
            let processIdentifier = app.processIdentifier,
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier),
            let icon = runningApplication.icon {
            appIconView.image = icon
        } else {
            appIconView.image = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        titleLabel.stringValue = app.name
        detailLabel.stringValue = app.subtitle
    }

    private func setup() {
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        imageView = appIconView
        textField = titleLabel

        addSubview(appIconView)
        addSubview(titleLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            appIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            appIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 32),
            appIconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
    }
}

final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onLaunch: ((LaunchableApp) -> Void)?
    var onClose: (() -> Void)?
    var sortApps: (([LaunchableApp]) -> [LaunchableApp])?

    private let effectView = NSVisualEffectView()
    private let searchField = LauncherSearchField()
    private let scrollView = NSScrollView()
    private let tableView = LauncherTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching applications")

    private var apps: [LaunchableApp] = []
    private var filteredApps: [LaunchableApp] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        setupSearchField()
        setupTableView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.tableColumns.first?.width = tableView.bounds.width
    }

    func prepareForPresentation(apps: [LaunchableApp]) {
        self.apps = apps
        searchField.stringValue = ""
        applyFilter()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func setupView() {
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true

        view.addSubview(effectView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: view.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search applications"
        searchField.font = .systemFont(ofSize: 18)
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.onMoveSelection = { [weak self] delta in
            self?.moveSelection(by: delta)
        }
        searchField.onSubmit = { [weak self] in
            self?.launchSelectedApp()
        }
        searchField.onCancel = { [weak self] in
            self?.onClose?()
        }

        effectView.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 18),
            searchField.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func setupTableView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 54
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.focusRingType = .none
        tableView.onMoveSelection = { [weak self] delta in
            self?.moveSelection(by: delta)
        }
        tableView.onSubmit = { [weak self] in
            self?.launchSelectedApp()
        }
        tableView.onCancel = { [weak self] in
            self?.onClose?()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        effectView.addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        effectView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else {
            return false
        }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            launchSelectedApp()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }

        if commandSelector == #selector(NSResponder.selectAll(_:)) {
            textView.selectAll(nil)
            return true
        }

        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredApps.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LauncherRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(
            withIdentifier: AppCellView.reuseIdentifier,
            owner: self
        ) as? AppCellView ?? AppCellView()

        cell.configure(with: filteredApps[row])
        return cell
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        launchSelectedApp()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingApps = apps.filter { $0.matches(query) }
        filteredApps = sortApps?(matchingApps) ?? matchingApps

        tableView.reloadData()
        emptyLabel.isHidden = !filteredApps.isEmpty

        if filteredApps.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredApps.isEmpty else {
            return
        }

        let currentRow = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let nextRow = min(max(currentRow + delta, 0), filteredApps.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(nextRow)
    }

    private func launchSelectedApp() {
        let selectedRow = tableView.selectedRow
        guard filteredApps.indices.contains(selectedRow) else {
            return
        }

        onLaunch?(filteredApps[selectedRow])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launcherViewController = LauncherViewController()
    private let launchHistoryStore = LaunchHistoryStore()
    private var window: LauncherPanel?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var cachedInstalledApps: [LaunchableApp] = []
    private var cachedApps: [LaunchableApp] = []
    private var lastScanDate = Date.distantPast
    private var previousFrontmostProcessIdentifier: pid_t?
    private var previousFrontmostWindowTitle: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.start()
        NSApp.setActivationPolicy(.accessory)
        setupWindow()
        setupStatusItem()
        registerHotKey()
        refreshApplications(force: true)
        WindowPermissionManager.requestStartupPermissions()
        AppLog.write("application_did_finish_launching", [
            "cached_installed_apps": cachedInstalledApps.count,
            "cached_apps": cachedApps.count
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func setupWindow() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = launcherViewController
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        launcherViewController.onLaunch = { [weak self] app in
            self?.launch(app)
        }
        launcherViewController.onClose = { [weak self] in
            self?.hideLauncher()
        }
        launcherViewController.sortApps = { [weak self] apps in
            self?.launchHistoryStore.sort(apps) ?? apps
        }

        window = panel
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Tendon"
        item.button?.toolTip = "Tendon"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        ))
        item.menu = menu
        statusItem = item
    }

    private func registerHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard hotKeyID.id == 1 else {
                    return noErr
                }

                let delegate = Unmanaged<AppDelegate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                DispatchQueue.main.async {
                    delegate.toggleLauncher()
                }

                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            reportHotKeyFailure(status: installStatus)
            return
        }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("TNDN"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            reportHotKeyFailure(status: registerStatus)
        }
    }

    private func reportHotKeyFailure(status: OSStatus) {
        fputs("Failed to register Option+N hotkey: \(status)\n", stderr)
        statusItem?.button?.title = "Tendon!"
        statusItem?.button?.toolTip = "Option+N could not be registered"
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func toggleLauncher() {
        guard let window else {
            return
        }

        if window.isVisible {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    private func showLauncher() {
        capturePreviousFrontmostWindow()
        refreshApplications(force: false)
        launcherViewController.prepareForPresentation(apps: cachedApps)
        positionWindow()
        AppLog.write("show_launcher", [
            "candidate_count": cachedApps.count,
            "previous_pid": logPID(previousFrontmostProcessIdentifier),
            "previous_title": previousFrontmostWindowTitle ?? "nil"
        ])

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            self?.launcherViewController.focusSearchField()
        }
    }

    private func hideLauncher() {
        window?.orderOut(nil)
    }

    private func capturePreviousFrontmostWindow() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            previousFrontmostProcessIdentifier = nil
            previousFrontmostWindowTitle = nil
            AppLog.write("capture_previous_frontmost_window", [
                "result": "no_frontmost_application"
            ])
            return
        }

        let processIdentifier = frontmostApplication.processIdentifier
        previousFrontmostProcessIdentifier = processIdentifier
        previousFrontmostWindowTitle = WindowActivator.frontmostWindowTitle(for: processIdentifier)
        AppLog.write("capture_previous_frontmost_window", [
            "pid": Int(processIdentifier),
            "localized_name": frontmostApplication.localizedName ?? "nil",
            "bundle_id": frontmostApplication.bundleIdentifier ?? "nil",
            "window_title": previousFrontmostWindowTitle ?? "nil"
        ])
    }

    private func positionWindow() {
        guard let window else {
            return
        }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let width = min(680, max(360, screenFrame.width - 32))
        let height = min(420, max(300, screenFrame.height - 80))
        let windowSize = NSSize(width: width, height: height)
        window.setContentSize(windowSize)

        let preferredY = screenFrame.midY + screenFrame.height * 0.12
        let minY = screenFrame.minY + 24
        let maxY = max(minY, screenFrame.maxY - windowSize.height - 24)

        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: min(max(preferredY, minY), maxY)
        )
        window.setFrameOrigin(origin)
    }

    private func refreshApplications(force: Bool) {
        if force || cachedInstalledApps.isEmpty || Date().timeIntervalSince(lastScanDate) > 30 {
            cachedInstalledApps = AppDiscovery.loadInstalledApplications()
            lastScanDate = Date()
        }

        cachedApps = AppDiscovery.includeRunningApplications(in: cachedInstalledApps)
        AppLog.write("refresh_applications", [
            "force": force,
            "installed_candidates": cachedInstalledApps.count,
            "all_candidates": cachedApps.count
        ])
    }

    private func launch(_ app: LaunchableApp) {
        hideLauncher()
        AppLog.write("launch_candidate", [
            "name": app.name,
            "application_name": (app.applicationName ?? "nil") as String,
            "bundle_id": (app.bundleIdentifier ?? "nil") as String,
            "pid": logPID(app.processIdentifier),
            "is_running": app.isRunning,
            "target_kind": app.targetKind == .window ? "window" : "application",
            "window_title": (app.windowTitle ?? "nil") as String,
            "window_identifier": logWindowIdentifier(app.windowIdentifier),
            "window_frame": logFrame(app.windowFrame)
        ])

        if WindowActivator.activate(
            app,
            previousFrontmostProcessIdentifier: previousFrontmostProcessIdentifier,
            previousFrontmostWindowTitle: previousFrontmostWindowTitle
        ) {
            launchHistoryStore.recordLaunch(of: app)
            return
        }

        if app.targetKind == .window {
            NSSound.beep()
            AppLog.write("launch_failed", [
                "name": app.name,
                "reason": "target_window_not_focusable"
            ])
            return
        }

        if
            app.isRunning,
            let processIdentifier = app.processIdentifier,
            let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) {
            runningApplication.unhide()

            if runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                AppLog.write("running_app_fallback_activated", [
                    "name": app.name,
                    "pid": Int(processIdentifier)
                ])
                launchHistoryStore.recordLaunch(of: app)
                return
            }
        }

        guard let url = app.url else {
            NSSound.beep()
            fputs("Failed to activate \(app.name): no application URL is available\n", stderr)
            AppLog.write("launch_failed", [
                "name": app.name,
                "reason": "missing_url"
            ])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSSound.beep()
                fputs("Failed to launch \(app.name): \(error.localizedDescription)\n", stderr)
                AppLog.write("launch_failed", [
                    "name": app.name,
                    "reason": error.localizedDescription
                ])
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.launchHistoryStore.recordLaunch(of: app)
                AppLog.write("launch_completed", [
                    "name": app.name,
                    "url": url.path
                ])
            }
        }
    }

    private func logFrame(_ frame: WindowFrame?) -> [String: Any] {
        guard let frame else {
            return [:]
        }

        return [
            "x": frame.x,
            "y": frame.y,
            "width": frame.width,
            "height": frame.height
        ]
    }

    private func logPID(_ processIdentifier: pid_t?) -> Any {
        processIdentifier.map { Int($0) } ?? NSNull()
    }

    private func logWindowIdentifier(_ windowIdentifier: UInt32?) -> Any {
        windowIdentifier.map { Int($0) } ?? NSNull()
    }
}

private func fourCharacterCode(_ code: String) -> OSType {
    code.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
