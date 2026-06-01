import AppKit
import CodexMonitorCore
import Foundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexRateLimitClient()
    private var quotaTimer: Timer?
    private var activityTimer: Timer?
    private var activitySocketServer: CodexHookSocketServer?
    private let activityStore = CodexActivityStore()
    private var latestSnapshot: RateLimitSnapshot?
    private var latestWeeklyUsedTodayPercent: Double?
    private var latestActivityStatus: CodexActivityStatus = .none
    private var latestError: String?
    private var latestLoginItemError: String?
    private var isRefreshing = false
    private static let weeklyUsageDayKey = "weeklyUsage.dayKey"
    private static let weeklyUsageBaselineKey = "weeklyUsage.baselineUsedPercent"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Codex quota and activity"
        updateStatusImage(snapshot: nil, weeklyUsedTodayPercent: nil, error: nil, refreshing: true)
        installCodexHooks()
        startActivitySocketServer()
        rebuildMenu()
        refresh()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActivity()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        activityTimer?.invalidate()
        activitySocketServer?.stop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openCodex() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(appURL)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app"))
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            @unknown default:
                try SMAppService.mainApp.register()
            }
            latestLoginItemError = nil
        } catch {
            latestLoginItemError = error.localizedDescription
        }
        rebuildMenu()
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        updateStatusImage(snapshot: latestSnapshot, weeklyUsedTodayPercent: latestWeeklyUsedTodayPercent, error: latestError, refreshing: true)
        rebuildMenu()

        Task {
            do {
                let snapshot = try await client.readRateLimits()
                let weeklyUsedTodayPercent = updateWeeklyUsedToday(from: snapshot.weekly)
                latestSnapshot = snapshot
                latestWeeklyUsedTodayPercent = weeklyUsedTodayPercent
                latestError = nil
                isRefreshing = false
                updateStatusImage(snapshot: snapshot, weeklyUsedTodayPercent: weeklyUsedTodayPercent, error: nil, refreshing: false)
                rebuildMenu()
            } catch {
                latestError = error.localizedDescription
                isRefreshing = false
                updateStatusImage(snapshot: latestSnapshot, weeklyUsedTodayPercent: latestWeeklyUsedTodayPercent, error: latestError, refreshing: false)
                rebuildMenu()
            }
        }
    }

    private func updateStatusImage(
        snapshot: RateLimitSnapshot?,
        weeklyUsedTodayPercent: Double?,
        error: String?,
        refreshing: Bool
    ) {
        statusItem.button?.image = MenuBarImageRenderer.image(
            snapshot: snapshot,
            weeklyUsedTodayPercent: weeklyUsedTodayPercent,
            isRefreshing: refreshing,
            activityStatus: latestActivityStatus
        )
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let snapshot = latestSnapshot, latestError == nil {
            addUsageItems(to: menu, snapshot: snapshot, weeklyUsedTodayPercent: latestWeeklyUsedTodayPercent)
        } else if isRefreshing {
            addUsageUnavailableItem(to: menu, title: "Refreshing...")
        } else {
            addUsageUnavailableItem(to: menu, title: "Unavailable")
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: ""))
        addLaunchAtLoginItem(to: menu)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addUsageItems(to menu: NSMenu, snapshot: RateLimitSnapshot, weeklyUsedTodayPercent: Double?) {
        menu.addItem(disabledItem("Usage"))

        if let fiveHour = snapshot.fiveHour {
            menu.addItem(quotaProgressItem(label: "5H", quota: fiveHour))
        } else {
            menu.addItem(disabledItem("5H unavailable"))
        }

        if let weekly = snapshot.weekly {
            menu.addItem(quotaProgressItem(label: "WK", quota: weekly))
        } else {
            menu.addItem(disabledItem("WK unavailable"))
        }

        if let weeklyUsedTodayPercent {
            menu.addItem(disabledItem("Today \(DailyWeeklyUsageText.percent(weeklyUsedTodayPercent))"))
        } else {
            menu.addItem(disabledItem("Today --"))
        }
    }

    private func addUsageUnavailableItem(to menu: NSMenu, title: String) {
        menu.addItem(disabledItem("Usage"))
        menu.addItem(disabledItem(title))
    }

    private func quotaProgressItem(label: String, quota: QuotaInfo) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = QuotaProgressMenuView(
            label: label,
            remainingPercent: quota.remainingPercent,
            resetText: ResetCountdownFormatter.compactText(resetsAt: quota.resetsAt)
        )
        return item
    }

    private func addLaunchAtLoginItem(to menu: NSMenu) {
        let status = SMAppService.mainApp.status
        let item = NSMenuItem(
            title: status == .requiresApproval ? "Launch at Login (Needs Approval)" : "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        item.state = status == .enabled || status == .requiresApproval ? .on : .off
        menu.addItem(item)

        if status == .requiresApproval {
            menu.addItem(NSMenuItem(title: "Open Login Items Settings", action: #selector(openLoginItemsSettings), keyEquivalent: ""))
        }
        if let latestLoginItemError {
            menu.addItem(disabledItem(latestLoginItemError))
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func startActivitySocketServer() {
        let server = CodexHookSocketServer { [weak self] event in
            Task { @MainActor in
                self?.activityStore.record(event)
                self?.refreshActivity()
            }
        }
        do {
            try server.start()
            activitySocketServer = server
        } catch {
        }
    }

    private func installCodexHooks() {
        do {
            let installer = CodexHookInstaller(bridgeCommand: try bridgeCommandPath())
            try installer.install()
        } catch {
        }
    }

    private func bridgeCommandPath() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw AppError.missingBridge
        }
        let bridgeURL = executableURL.deletingLastPathComponent().appendingPathComponent("CodexMonitorHookBridge")
        guard FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
            throw AppError.missingBridge
        }
        return bridgeURL.path
    }

    private func refreshActivity() {
        latestActivityStatus = activityStore.aggregateStatus()
        updateStatusImage(
            snapshot: latestSnapshot,
            weeklyUsedTodayPercent: latestWeeklyUsedTodayPercent,
            error: latestError,
            refreshing: isRefreshing
        )
        rebuildMenu()
    }

    private func updateWeeklyUsedToday(from quota: QuotaInfo?) -> Double? {
        guard let quota else {
            return nil
        }

        let defaults = UserDefaults.standard
        let dayKey = todayKey()
        let storedState = storedWeeklyUsageState(defaults: defaults)
        let persistedState = persistedWeeklyUsageState()
        let mergedState = DailyWeeklyUsageTracker.mergedState(
            primary: persistedState,
            fallback: storedState,
            dayKey: dayKey
        )

        let result = DailyWeeklyUsageTracker.update(
            currentUsedPercent: quota.usedPercent,
            state: mergedState,
            dayKey: dayKey
        )
        defaults.set(result.state.dayKey, forKey: Self.weeklyUsageDayKey)
        defaults.set(result.state.baselineUsedPercent, forKey: Self.weeklyUsageBaselineKey)
        persistWeeklyUsageState(result.state)
        return result.usedTodayPercent
    }

    private func storedWeeklyUsageState(defaults: UserDefaults) -> DailyWeeklyUsageState? {
        guard
            let storedDayKey = defaults.string(forKey: Self.weeklyUsageDayKey),
            let storedBaseline = storedWeeklyUsageBaseline(defaults: defaults)
        else {
            return nil
        }
        return DailyWeeklyUsageState(dayKey: storedDayKey, baselineUsedPercent: storedBaseline)
    }

    private func storedWeeklyUsageBaseline(defaults: UserDefaults) -> Double? {
        let value = defaults.object(forKey: Self.weeklyUsageBaselineKey)
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let intValue = value as? Int {
            return Double(intValue)
        }
        return nil
    }

    private func persistedWeeklyUsageState() -> DailyWeeklyUsageState? {
        guard let data = try? Data(contentsOf: weeklyUsageStateURL()) else {
            return nil
        }
        return try? JSONDecoder().decode(DailyWeeklyUsageState.self, from: data)
    }

    private func persistWeeklyUsageState(_ state: DailyWeeklyUsageState) {
        do {
            let url = weeklyUsageStateURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
        }
    }

    private func weeklyUsageStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-monitor-minibar", isDirectory: true)
            .appendingPathComponent("weekly-usage.json")
    }

    private func todayKey() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private enum AppError: LocalizedError {
    case missingBridge

    var errorDescription: String? {
        switch self {
        case .missingBridge:
            return "CodexMonitorHookBridge is missing from the app bundle"
        }
    }
}

private final class QuotaProgressMenuView: NSView {
    private let label: String
    private let remainingPercent: Double
    private let resetText: String

    init(label: String, remainingPercent: Double, resetText: String) {
        self.label = label
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetText = resetText
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 32))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let contentX: CGFloat = 26
        label.draw(at: NSPoint(x: contentX, y: 15), withAttributes: textAttributes)
        wholePercent(remainingPercent).draw(at: NSPoint(x: contentX + 26, y: 15), withAttributes: textAttributes)
        "· \(resetText)".draw(at: NSPoint(x: contentX + 66, y: 15), withAttributes: textAttributes)

        let track = NSRect(x: contentX, y: 7, width: 206, height: 5)
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        rounded(track, radius: 2.5).fill()

        let fillWidth = max(2, track.width * CGFloat(remainingPercent) / 100)
        let fillRect = NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
        color(forRemainingPercent: remainingPercent).setFill()
        rounded(fillRect, radius: 2.5).fill()
    }

    private func color(forRemainingPercent percent: Double) -> NSColor {
        if percent <= 15 {
            return NSColor.systemRed
        }
        if percent <= 35 {
            return NSColor.systemYellow
        }
        return NSColor.systemGreen
    }

    private func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func wholePercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

@main
enum CodexMonitorMinibarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
