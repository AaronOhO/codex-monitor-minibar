import AppKit
import CodexMonitorCore
import Foundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexRateLimitClient()
    private let tokenUsageStore = CodexLocalTokenUsageStore()
    private var quotaTimer: Timer?
    private var activityTimer: Timer?
    private var tokenUsageTimer: Timer?
    private var activitySocketServer: CodexHookSocketServer?
    private let activityStore = CodexActivityStore()
    private var latestSnapshot: RateLimitSnapshot?
    private var latestTokenUsageSnapshot: LocalTokenUsageSnapshot?
    private var latestActivityStatus: CodexActivityStatus = .none
    private var latestActivityMenuTitle = "Activity: none"
    private var latestError: String?
    private var latestTokenUsageError: String?
    private var latestLoginItemError: String?
    private var staleFiveHourQuota = false
    private var staleWeeklyQuota = false
    private var isRefreshing = false
    private var isTokenUsageRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Codex quota and activity"
        updateStatusImage(snapshot: nil, error: nil, refreshing: true)
        installCodexHooks()
        startActivitySocketServer()
        rebuildMenu()
        refresh()
        refreshTokenUsage()
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
        tokenUsageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTokenUsage()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        activityTimer?.invalidate()
        tokenUsageTimer?.invalidate()
        activitySocketServer?.stop()
        client.shutdown()
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

    @objc private func refreshAllData() {
        refreshActivity()
        refresh()
        refreshTokenUsage()
    }

    private func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        updateStatusImage(snapshot: latestSnapshot, error: latestError, refreshing: true)
        rebuildMenu()

        Task {
            do {
                let snapshot = try await client.readRateLimits()
                applyRateLimitSnapshot(snapshot)
                isRefreshing = false
                updateStatusImage(snapshot: latestSnapshot, error: nil, refreshing: false)
                rebuildMenu()
            } catch {
                markRateLimitRefreshFailed(error)
                isRefreshing = false
                updateStatusImage(snapshot: latestSnapshot, error: latestError, refreshing: false)
                rebuildMenu()
            }
        }
    }

    private func updateStatusImage(
        snapshot: RateLimitSnapshot?,
        error: String?,
        refreshing: Bool
    ) {
        statusItem.button?.image = MenuBarImageRenderer.image(
            snapshot: snapshot,
            todayTokenText: menuBarTokenText(),
            isRefreshing: refreshing,
            activityStatus: latestActivityStatus,
            staleFiveHourQuota: staleFiveHourQuota,
            staleWeeklyQuota: staleWeeklyQuota
        )
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let snapshot = latestSnapshot {
            addUsageItems(to: menu, snapshot: snapshot)
        } else if isRefreshing {
            addUsageUnavailableItem(to: menu, title: "Refreshing...")
        } else {
            addUsageUnavailableItem(to: menu, title: "Unavailable")
        }
        addLocalTokenUsageItems(to: menu)
        menu.addItem(disabledItem(latestActivityMenuTitle))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshAllData), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: ""))
        addLaunchAtLoginItem(to: menu)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addUsageItems(to menu: NSMenu, snapshot: RateLimitSnapshot) {
        menu.addItem(disabledItem("Usage"))

        if let fiveHour = snapshot.fiveHour {
            menu.addItem(quotaProgressItem(label: "5H", quota: fiveHour, isStale: staleFiveHourQuota))
        } else {
            menu.addItem(disabledItem("5H unavailable"))
        }

        if let weekly = snapshot.weekly {
            menu.addItem(quotaProgressItem(label: "WK", quota: weekly, isStale: staleWeeklyQuota))
        } else {
            menu.addItem(disabledItem("WK unavailable"))
        }

        if latestError != nil || staleFiveHourQuota || staleWeeklyQuota {
            menu.addItem(disabledItem("Showing last known quota"))
        }
    }

    private func addUsageUnavailableItem(to menu: NSMenu, title: String) {
        menu.addItem(disabledItem("Usage"))
        menu.addItem(disabledItem(title))
    }

    private func addLocalTokenUsageItems(to menu: NSMenu) {
        if let snapshot = latestTokenUsageSnapshot {
            let usage = snapshot.usage(for: todayKey())
            menu.addItem(disabledItem("This Mac Tokens \(LocalTokenUsageText.compact(usage.totalTokens)) today"))
            if usage.totalTokens > 0 {
                menu.addItem(disabledItem(
                    "In \(LocalTokenUsageText.compact(usage.inputTokens)) · Cache \(LocalTokenUsageText.compact(usage.cachedInputTokens))"
                ))
                menu.addItem(disabledItem(
                    "Out \(LocalTokenUsageText.compact(usage.outputTokens)) · Reason \(LocalTokenUsageText.compact(usage.reasoningOutputTokens))"
                ))
            }
        } else if isTokenUsageRefreshing {
            menu.addItem(disabledItem("This Mac Tokens indexing..."))
        } else if latestTokenUsageError != nil {
            menu.addItem(disabledItem("This Mac Tokens unavailable"))
        } else {
            menu.addItem(disabledItem("This Mac Tokens --"))
        }
    }

    private func quotaProgressItem(label: String, quota: QuotaInfo, isStale: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = QuotaProgressMenuView(
            label: label,
            remainingPercent: quota.remainingPercent,
            resetText: ResetCountdownFormatter.compactText(resetsAt: quota.resetsAt),
            isStale: isStale
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

    private func refreshTokenUsage() {
        guard !isTokenUsageRefreshing else {
            return
        }
        isTokenUsageRefreshing = true

        let store = tokenUsageStore
        let startOfToday = Calendar.current.startOfDay(for: Date())
        Task.detached {
            let result = Result {
                try store.refresh(since: startOfToday)
            }
            await MainActor.run {
                self.isTokenUsageRefreshing = false
                switch result {
                case .success(let snapshot):
                    self.latestTokenUsageSnapshot = snapshot
                    self.latestTokenUsageError = nil
                case .failure(let error):
                    self.latestTokenUsageError = error.localizedDescription
                }
                self.updateStatusImage(
                    snapshot: self.latestSnapshot,
                    error: self.latestError,
                    refreshing: self.isRefreshing
                )
                self.rebuildMenu()
            }
        }
    }

    private func refreshActivity() {
        let summary = activityStore.summary()
        latestActivityStatus = summary.status
        latestActivityMenuTitle = summary.menuTitle
        updateStatusImage(
            snapshot: latestSnapshot,
            error: latestError,
            refreshing: isRefreshing
        )
        rebuildMenu()
    }

    private func menuBarTokenText() -> String? {
        if let usage = latestTokenUsageSnapshot?.usage(for: todayKey()) {
            return "TK \(LocalTokenUsageText.compact(usage.totalTokens))"
        }
        return isTokenUsageRefreshing ? "TK ..." : nil
    }

    private func todayKey() -> String {
        dayKey(for: Date())
    }

    private func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func applyRateLimitSnapshot(_ snapshot: RateLimitSnapshot) {
        let previous = latestSnapshot
        staleFiveHourQuota = snapshot.fiveHour == nil && previous?.fiveHour != nil
        staleWeeklyQuota = snapshot.weekly == nil && previous?.weekly != nil
        latestSnapshot = RateLimitSnapshot(
            fiveHour: snapshot.fiveHour ?? previous?.fiveHour,
            weekly: snapshot.weekly ?? previous?.weekly,
            planType: snapshot.planType ?? previous?.planType,
            limitName: snapshot.limitName ?? previous?.limitName
        )
        latestError = nil
    }

    private func markRateLimitRefreshFailed(_ error: Error) {
        latestError = error.localizedDescription
        staleFiveHourQuota = latestSnapshot?.fiveHour != nil
        staleWeeklyQuota = latestSnapshot?.weekly != nil
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
    private let isStale: Bool

    init(label: String, remainingPercent: Double, resetText: String, isStale: Bool) {
        self.label = label
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetText = resetText
        self.isStale = isStale
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 32))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isStale ? NSColor.systemRed : NSColor.labelColor
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
        (isStale ? NSColor.systemRed : color(forRemainingPercent: remainingPercent)).setFill()
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
