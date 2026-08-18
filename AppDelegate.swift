import AppKit
import Darwin

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var controller: MonitorController!
    private var settingsController: SettingsWindowController?

    // 更新检查状态
    private var updateInfo: UpdateInfo?
    private var isUpdating = false
    private var lastManualCheckResult: String?
    // 菜单当前是否打开（避免 tracking 期间重建导致崩溃）
    private var menuIsOpen = false

    /// 入口：先处理 --test 无头自测分支，否则启动菜单栏应用。
    /// 不能用 NSApplicationMain（需要 MainMenu.nib），用自定义 @main。
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 5, args[1] == "--test", let provider = ProviderType(rawValue: args[2]) {
            CLI.runTest(provider: provider, url: args[3], token: args[4])
        }
        if args.count >= 2, args[1] == "--sim" {
            CLI.runSim()
        }
        if args.count >= 2, args[1] == "--update" {
            CLI.runUpdateCheck(simulatedVersion: args.count >= 3 ? args[2] : nil)
        }
        if args.count >= 3, args[1] == "--loginitem" {
            CLI.runLoginItem(args[2])   // status / on / off
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 无 Dock 图标、不出现在 Cmd+Tab
        let delegate = AppDelegate()          // app.delegate 是弱引用，需强持有
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        menu.delegate = self
        statusItem.menu = menu

        let config = ConfigStore.loadConfig()
        controller = MonitorController(config: config)
        controller.onStateChange = { [weak self] in
            self?.rebuildMenu()
        }
        controller.start()

        NotificationManager.shared.requestAuthorizationIfNeeded()

        // 按设置频率自动检查更新（后台）
        if Updater.shouldAutoCheck(config: controller.config) {
            Task { await runUpdateCheck(manual: false) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - NSMenuDelegate

    /// 每次菜单打开前强制重建，保证显示最新数据（menuWillOpen 阶段修改菜单是安全的）
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu(force: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    // MARK: - 菜单

    private func rebuildMenu(force: Bool = false) {
        // 菜单正在显示时修改会崩溃（AppKit 不允许 tracking 期间改动），仅更新标题；
        // 下次打开前会在 menuWillOpen 中强制重建，保证内容最新。
        guard force || !menuIsOpen else {
            statusItem.button?.title = controller.aggregateShortTitle()
            return
        }
        menu.removeAllItems()

        // 汇总头部（两行：状态 + 上次检查时间）
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let (headerLine1, headerLine2) = headerLines()
        header.attributedTitle = twoLine(headerLine1, headerLine2, weight: .semibold)
        menu.addItem(header)
        menu.addItem(.separator())

        // 近 7 日用量折线图（宽度对齐菜单内容宽度，视觉居中；高度紧凑；悬停显示当日用量）
        let chartItem = NSMenuItem()
        let hasCNY = controller.config.sites.contains { $0.provider.displayCurrency == "CNY" }
        chartItem.view = DailyUsageChartView(data: controller.dailyUsageForLastDays(7),
                                             width: menuChartWidth(),
                                             symbol: hasCNY ? "¥" : "$")
        menu.addItem(chartItem)
        menu.addItem(.separator())

        // 每站点两行：第一行 平台+余额；第二行 本日/本月/更新时间
        let enabledSites = controller.config.sites.filter { $0.enabled }
        if enabledSites.isEmpty {
            let empty = NSMenuItem(title: "未启用任何站点，请在设置中添加", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for site in enabledSites {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = siteRowAttributedTitle(site: site)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // —— 版本与更新 ——
        let versionRow = NSMenuItem(title: "版本 v\(Updater.installedVersion())", action: nil, keyEquivalent: "")
        versionRow.isEnabled = false
        menu.addItem(versionRow)

        if let info = updateInfo, info.latestVersion != ConfigStore.ignoredVersion {
            let download = NSMenuItem(title: "⬆ 发现新版本 v\(info.latestVersion) — 前往下载",
                                      action: #selector(openUpdateURL(_:)), keyEquivalent: "")
            menu.addItem(download)

            let ignore = NSMenuItem(title: "忽略此版本 v\(info.latestVersion)",
                                    action: #selector(ignoreUpdate(_:)), keyEquivalent: "")
            menu.addItem(ignore)
        }

        let checkUpdate = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "u")
        checkUpdate.keyEquivalentModifierMask = [.command]
        menu.addItem(checkUpdate)

        if let result = lastManualCheckResult {
            let resultRow = NSMenuItem(title: result, action: nil, keyEquivalent: "")
            resultRow.isEnabled = false
            menu.addItem(resultRow)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = [.command]
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        statusItem.button?.title = controller.aggregateShortTitle()
    }

    /// 头部两行：第一行 状态；第二行 上次检查时间
    private func headerLines() -> (String, String) {
        var okCount = 0
        var errCount = 0
        for site in controller.config.sites where site.enabled {
            if let snap = controller.snapshots[site.id] {
                if snap.ok { okCount += 1 } else { errCount += 1 }
            }
        }
        let status = errCount > 0 ? "⚠ \(errCount) 个站点异常" : "全部正常"
        let lastTime = controller.snapshots.values.map { $0.checkedAt }.max()
            .map { AppFormatters.time.string(from: $0) } ?? "—"
        return (status, "上次检查 \(lastTime)")
    }

    /// 两行富文本：第一行平台+余额（中粗），第二行本日/本月/更新时间（小号次级色）
    private func twoLine(_ line1: String, _ line2: String, weight: NSFont.Weight = .regular) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: line1, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]))
        s.append(NSAttributedString(string: "\n\(line2)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        return s
    }

    /// 站点行两行内容：第一行 平台+余额；第二行 本日/本月/更新时间
    private func siteRowAttributedTitle(site: Site) -> NSAttributedString {
        guard let snap = controller.snapshots[site.id] else {
            return twoLine("○ \(site.name)", "尚未检查")
        }
        let mark = snap.ok ? "✓" : "✕"
        let time = AppFormatters.time.string(from: snap.checkedAt)

        var line1: String
        var line2: String
        if let err = snap.lastError {
            line1 = "\(mark) \(site.name) — 错误"
            line2 = "\(err) · 更新 \(time)"
        } else if snap.currency == "CNY" {
            line1 = "\(mark) \(site.name) — 余额 \(fmt("¥%.2f", snap.balance ?? 0))"
            var parts: [String] = []
            if let d = snap.tracking?.dayUsage { parts.append("本日 \(fmt("¥%.2f", d))") }
            if let m = snap.tracking?.monthUsage { parts.append("本月 \(fmt("¥%.2f", m))") }
            parts.append("更新 \(time)")
            line2 = parts.joined(separator: " · ")
        } else if snap.currency == "USD", snap.usedToday == nil {
            // 仅余额的美元平台（如 DeepInfra）
            line1 = "\(mark) \(site.name) — 余额 \(fmt("$%.2f", snap.balance ?? 0))"
            line2 = "更新 \(time)"
        } else {
            // 有用量的平台（OpenRouter / NewAPI）
            line1 = "\(mark) \(site.name) — 今日 \(fmt("$%.2f", snap.usedToday ?? 0))"
            var parts: [String] = []
            if let m = snap.usedThisMonth { parts.append("本月 \(fmt("$%.2f", m))") }
            if let h = snap.hardLimit { parts.append("上限 \(fmt("$%.0f", h))") }
            parts.append("更新 \(time)")
            line2 = parts.joined(separator: " · ")
        }
        return twoLine(line1, line2)
    }

    private func fmt(_ format: String, _ value: Double) -> String {
        String(format: format, value)
    }

    /// 计算菜单内容宽度（取所有文字行的最宽值 + 内边距），让折线图与弹窗同宽、视觉居中
    private func menuChartWidth() -> CGFloat {
        func textWidth(_ s: String, _ size: CGFloat) -> CGFloat {
            NSAttributedString(string: s,
                               attributes: [.font: NSFont.systemFont(ofSize: size)]).size().width
        }
        var maxW: CGFloat = 0
        let (h1, h2) = headerLines()
        maxW = max(maxW, textWidth(h1, 13), textWidth(h2, 11))
        for site in controller.config.sites where site.enabled {
            maxW = max(maxW, siteRowAttributedTitle(site: site).size().width)
        }
        maxW = max(maxW, textWidth("版本 v\(Updater.installedVersion())", 13))
        maxW = max(maxW, textWidth("检查更新…", 13))
        // 菜单项左右内边距约 40pt
        return max(240, maxW + 40)
    }

    // MARK: - 动作

    @objc private func refreshNow(_ sender: Any?) {
        controller.refreshNow()
    }

    @objc private func openSettings(_ sender: Any?) {
        if let sc = settingsController {
            sc.updateConfig(controller.config)
            sc.show()
            return
        }
        let sc = SettingsWindowController(config: controller.config)
        sc.onSave = { [weak self] newConfig in
            self?.controller.setConfig(newConfig)
        }
        sc.onCheckUpdate = { [weak self] in
            self?.checkForUpdates(nil)
        }
        settingsController = sc
        sc.show()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 更新检查

    @objc private func checkForUpdates(_ sender: Any?) {
        Task { await runUpdateCheck(manual: true) }
    }

    @objc private func openUpdateURL(_ sender: Any?) {
        guard let info = updateInfo else { return }
        NSWorkspace.shared.open(info.releaseURL)
    }

    @objc private func ignoreUpdate(_ sender: Any?) {
        guard let info = updateInfo else { return }
        ConfigStore.ignoredVersion = info.latestVersion
        updateInfo = nil
        lastManualCheckResult = "已忽略 v\(info.latestVersion)"
        rebuildMenu()
    }

    private func runUpdateCheck(manual: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        ConfigStore.lastUpdateCheck = Date()

        do {
            if let info = try await Updater.check() {
                if info.latestVersion != ConfigStore.ignoredVersion {
                    updateInfo = info
                    NotificationManager.shared.notifyUpdateAvailable(version: info.latestVersion, url: info.releaseURL)
                }
                lastManualCheckResult = nil
            } else {
                updateInfo = nil
                lastManualCheckResult = manual ? "已是最新版本 v\(Updater.installedVersion())" : nil
            }
        } catch {
            updateInfo = nil
            lastManualCheckResult = manual ? "检查更新失败（\(error)）" : nil
        }

        settingsController?.showUpdateStatus(lastManualCheckResult ?? "")
        rebuildMenu()
    }
}

// MARK: - CLI 无头自测模式
// 用法: NewAPIMonitor --test <deepseek|newapi> <baseURL> <token>

enum CLI {
    static func runTest(provider: ProviderType, url: String, token: String) -> Never {
        let site = Site(id: UUID(), name: "test", enabled: true, baseURL: url,
                        apiToken: token, provider: provider, lowBalanceThreshold: 0)
        let sem = DispatchSemaphore(value: 0)
        // Task.detached：避免 @MainActor 继承任务与主线程信号量死锁。
        // 任务内直接 exit() 结束进程；主线程永久阻塞在 sem.wait()，确保任务跑完。
        Task.detached {
            do {
                let result = try await APIService.fetch(site)
                var parts: [String] = ["ok"]
                if let b = result.balance {
                    parts.append(String(format: "balance=%@ %.2f", result.currency ?? "", b))
                }
                if let t = result.usedToday { parts.append(String(format: "usedToday=%.2f", t)) }
                if let m = result.usedThisMonth { parts.append(String(format: "usedThisMonth=%.2f", m)) }
                if let h = result.hardLimit { parts.append(String(format: "hardLimit=%.0f", h)) }
                print(parts.joined(separator: " "))
                exit(0)
            } catch {
                print("ERROR: \(error)")
                exit(2)
            }
        }
        sem.wait()
        fatalError("unreachable")
    }

    /// 用量追踪算法自测：跑一组固定余额场景，验证本日/本月基准与累计逻辑
    static func runSim() -> Never {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let steps: [(String, String, Double)] = [
            ("月首 08:00       ", "2026-08-01 08:00", 100),   // 设基准
            ("当天 10:00       ", "2026-08-01 10:00", 90),    // 本日+10
            ("当天 12:00       ", "2026-08-01 12:00", 80),    // 本日+10
            ("当天 14:00 充值  ", "2026-08-01 14:00", 150),   // 充值→基准升150，用量不清零
            ("当天 16:00       ", "2026-08-01 16:00", 140),   // 本日+10
            ("次日 00:05       ", "2026-08-02 00:05", 135),   // 跨天→本日基准重置，本月继续+5
            ("次日 10:00       ", "2026-08-02 10:00", 120),   // 本日+15
            ("次月 01:00       ", "2026-09-01 01:00", 200),   // 跨月→本月基准重置
        ]
        var t = UsageTracking()
        print("场景                | 余额 | 本日基准 | 本日用量 | 本月基准 | 本月用量")
        print("────────────────────┼──────┼─────────┼─────────┼─────────┼─────────")
        for (label, ds, balance) in steps {
            guard let date = fmt.date(from: ds) else { continue }
            UsageTracker.advance(&t, date: date, balance: balance)
            print(String(format: "%-16@ | ¥%.0f | %8@ | %8@ | %8@ | %8@",
                         label as NSString, balance,
                         (t.dayBaseline.map { "¥\($0)" } ?? "—") as NSString,
                         (t.dayUsage > 0 ? "¥\(t.dayUsage)" : "¥0") as NSString,
                         (t.monthBaseline.map { "¥\($0)" } ?? "—") as NSString,
                         (t.monthUsage > 0 ? "¥\(t.monthUsage)" : "¥0") as NSString))
        }
        exit(0)
    }

    /// 更新检查自测：--update [模拟版本号]
    static func runUpdateCheck(simulatedVersion: String?) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let installed = simulatedVersion ?? Updater.installedVersion()
            print("本机版本: v\(installed)")
            do {
                if let info = try await Updater.check(installed: installed) {
                    print("最新版本: v\(info.latestVersion)")
                    print("发布页: \(info.releaseURL.absoluteString)")
                    print("是否更新: \(Updater.isNewer(info.latestVersion, than: installed) ? "是 ✅" : "否")")
                } else {
                    print("最新版本: 已是最新（或无新 Release）")
                }
            } catch {
                print("ERROR: \(error)")
            }
            exit(0)
        }
        sem.wait()
        fatalError("unreachable")
    }

    /// 开机自启动自测：--loginitem status|on|off
    static func runLoginItem(_ action: String) -> Never {
        print("当前状态: \(LoginItem.isEnabled ? "已开启" : "未开启")")
        do {
            if action == "on" {
                try LoginItem.setEnabled(true)
                print("已开启开机自启动")
            } else if action == "off" {
                try LoginItem.setEnabled(false)
                print("已关闭开机自启动")
            }
        } catch {
            print("ERROR: \(error)")
        }
        print("操作后状态: \(LoginItem.isEnabled ? "已开启" : "未开启")")
        exit(0)
    }
}
