import AppKit
import Carbon

struct LaunchableApp: Hashable {
    let name: String
    let url: URL
    let bundleIdentifier: String?
    let searchText: String
    let historyKey: String

    var subtitle: String {
        bundleIdentifier ?? url.path
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
}

enum AppDiscovery {
    static func loadApplications() -> [LaunchableApp] {
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
            url: url,
            bundleIdentifier: bundleIdentifier,
            searchText: searchText,
            historyKey: historyKey
        )
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
    private var entries: [String: LaunchHistoryEntry] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupportURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ??
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        self.fileURL = applicationSupportURL
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
        guard
            let data = try? Data(contentsOf: fileURL),
            let decodedEntries = try? JSONDecoder().decode([String: LaunchHistoryEntry].self, from: data)
        else {
            entries = [:]
            return
        }

        entries = decodedEntries
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
        appIconView.image = NSWorkspace.shared.icon(forFile: app.url.path)
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
    private var cachedApps: [LaunchableApp] = []
    private var lastScanDate = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupWindow()
        setupStatusItem()
        registerHotKey()
        refreshApplications(force: true)
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
        item.button?.title = "Tako"
        item.button?.toolTip = "Tako Launcher"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Show Launcher",
            action: #selector(showLauncherFromMenu),
            keyEquivalent: "n"
        ))
        menu.addItem(NSMenuItem(
            title: "Rescan Applications",
            action: #selector(rescanApplicationsFromMenu),
            keyEquivalent: "r"
        ))
        menu.addItem(.separator())
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

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("TAKO"), id: 1)
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
        statusItem?.button?.title = "Tako!"
        statusItem?.button?.toolTip = "Option+N could not be registered"
    }

    @objc private func showLauncherFromMenu() {
        showLauncher()
    }

    @objc private func rescanApplicationsFromMenu() {
        refreshApplications(force: true)
        showLauncher()
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
        refreshApplications(force: false)
        launcherViewController.prepareForPresentation(apps: cachedApps)
        positionWindow()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self] in
            self?.launcherViewController.focusSearchField()
        }
    }

    private func hideLauncher() {
        window?.orderOut(nil)
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
        guard force || cachedApps.isEmpty || Date().timeIntervalSince(lastScanDate) > 30 else {
            return
        }

        cachedApps = AppDiscovery.loadApplications()
        lastScanDate = Date()
    }

    private func launch(_ app: LaunchableApp) {
        hideLauncher()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error {
                NSSound.beep()
                fputs("Failed to launch \(app.name): \(error.localizedDescription)\n", stderr)
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.launchHistoryStore.recordLaunch(of: app)
            }
        }
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
