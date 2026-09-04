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
        if args.count >= 2, args[1] == "--charttest" {
            CLI.runChartTest()          // 渲染折线图到 /tmp/chart.png 供检查
        }
        if args.count >= 2, args[1] == "--measure" {
            CLI.runMeasure()            // 测量菜单宽度，校准折线图宽度
        }
        if args.count >= 2, args[1] == "--configtest" {
            CLI.runConfigTest()         // 配置加载/迁移自测
        }
        if args.count >= 2, args[1] == "--lbqhtest" {
            CLI.runLBQHTest()           // 联并千行余额刷新链路自测
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 无 Dock 图标、不出现在 Cmd+Tab
        let delegate = AppDelegate()          // app.delegate 是弱引用，需强持有
        app.delegate = delegate
        delegate.setupMainMenu()
        app.run()
    }

    /// 设置主菜单（含「编辑」菜单）：accessory 应用虽不显示菜单栏，但快捷键
    /// ⌘C/⌘V/⌘X/⌘A 依赖菜单项注册，缺失会导致文本框无法复制/粘贴。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "APIMug")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 APIMug",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 APIMug", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 APIMug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 编辑菜单（剪贴板快捷键）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
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
            statusItem.button?.attributedTitle = controller.aggregateShortTitle()
            return
        }
        menu.removeAllItems()

        // 用「探针」临时菜单测量文字总宽（禁止在展示中的菜单上 insertItem —— AppKit 断言崩溃）
        let probe = NSMenu()
        addMenuHeader(to: probe)
        addSiteRows(to: probe)
        addBottomItems(to: probe)
        let chartWidth = max(240, probe.size.width)

        // 真实菜单按顺序构建（全部用 addItem）
        addMenuHeader(to: menu)

        // 近 7 日用量折线图：宽度=文字菜单总宽 → 填满弹窗、左右等距居中
        let chartItem = NSMenuItem()
        let hasCNY = controller.config.sites.contains { $0.provider.displayCurrency == "CNY" }
        let chartSeries = controller.dailyUsageSeriesForLastDays(7).map { s in
            DailyUsageChartView.Series(name: s.site.name,
                                       color: s.site.provider.chartColor,
                                       points: s.points)
        }
        chartItem.view = DailyUsageChartView(series: chartSeries,
                                             width: chartWidth,
                                             symbol: hasCNY ? "¥" : "$")
        menu.addItem(chartItem)
        menu.addItem(.separator())

        addSiteRows(to: menu)
        addBottomItems(to: menu)

        statusItem.button?.attributedTitle = controller.aggregateShortTitle()
    }

    /// 头部两行 + 分隔线
    private func addMenuHeader(to menu: NSMenu) {
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let (line1, line2) = headerLines()
        header.attributedTitle = twoLine(line1, line2, weight: .semibold)
        menu.addItem(header)
        menu.addItem(.separator())
    }

    /// 站点行（每站点两行：平台+余额 / 本日·本月·更新时间）
    private func addSiteRows(to menu: NSMenu) {
        let enabledSites = controller.config.sites.filter { $0.enabled }
        let lbqhEnabled = controller.config.lbqh?.enabled ?? false
        if enabledSites.isEmpty && !lbqhEnabled {
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
        // 联并千行虚拟站点行（独立开关启用时显示）
        if lbqhEnabled, let lbqh = controller.config.lbqh {
            let lbqhItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            lbqhItem.isEnabled = false
            lbqhItem.attributedTitle = lbqhRowAttributedTitle(lbqh: lbqh)
            menu.addItem(lbqhItem)
        }
    }

    /// 联并千行行：两行（余额 / 更新时间），与站点行一致
    private func lbqhRowAttributedTitle(lbqh: LBQHConfig) -> NSAttributedString {
        guard let snap = controller.snapshots[MonitorController.lbqhSiteID] else {
            return twoLine("○ 联并千行", "尚未检查")
        }
        let mark = snap.ok ? "✓" : "✕"
        let time = AppFormatters.time.string(from: snap.checkedAt)
        if let err = snap.lastError {
            return twoLine("\(mark) 联并千行 — 错误", "\(err) · 更新 \(time)")
        }
        if let b = snap.balance {
            return twoLine("\(mark) 联并千行 — 余额 ¥\(fmt("%.2f", b))", "更新 \(time)")
        }
        return twoLine("\(mark) 联并千行 — 余额 ¥0.00", "更新 \(time)")
    }

    /// 版本 / 更新 / 操作区（底部固定项）
    private func addBottomItems(to menu: NSMenu) {
        menu.addItem(.separator())

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
    }

    /// 头部两行：第一行 状态（含异常/低余额提示）；第二行 上次检查时间
    private func headerLines() -> (String, String) {
        var errCount = 0
        var lowCount = 0
        for site in controller.config.sites where site.enabled {
            if let snap = controller.snapshots[site.id] {
                if !snap.ok {
                    errCount += 1
                } else if let b = snap.balance {
                    let t = site.lowBalanceThreshold > 0 ? site.lowBalanceThreshold : controller.config.defaultLowBalanceThreshold
                    if b < t { lowCount += 1 }
                }
            }
        }
        // 联并千行参与统计
        if let lbqh = controller.config.lbqh, lbqh.enabled,
           let snap = controller.snapshots[MonitorController.lbqhSiteID] {
            if !snap.ok {
                errCount += 1
            } else if let b = snap.balance {
                let t = lbqh.lowBalanceThreshold > 0 ? lbqh.lowBalanceThreshold : controller.config.defaultLowBalanceThreshold
                if b < t { lowCount += 1 }
            }
        }
        let status: String
        if errCount > 0 {
            status = "⚠ \(errCount) 个站点异常"
        } else if lowCount > 0 {
            status = "! \(lowCount) 个站点余额低"
        } else {
            status = "全部正常"
        }
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

    // MARK: - 动作

    @objc private func refreshNow(_ sender: Any?) {
        // 手动「立即刷新」：联并千行同时 POST /api/balance/fetch 立即抓取最新余额
        controller.refreshNow(forceLBQH: true)
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

    /// 折线图渲染自测：模拟两条站点线（含颜色、填充去除、居中宽度），导出 PNG 到 /tmp/chart.png
    static func runChartTest() -> Never {
        let days1: [(day: String, value: Double)] = [
            ("2026-08-12", 0), ("2026-08-13", 0), ("2026-08-14", 0),
            ("2026-08-15", 0), ("2026-08-16", 0), ("2026-08-17", 0),
            ("2026-08-18", 15.66),
        ]
        let days2: [(day: String, value: Double)] = [
            ("2026-08-12", 0), ("2026-08-13", 0.5), ("2026-08-14", 1.2),
            ("2026-08-15", 2.0), ("2026-08-16", 1.5), ("2026-08-17", 2.8),
            ("2026-08-18", 3.1),
        ]
        let series = [
            DailyUsageChartView.Series(name: "DeepSeek", color: NSColor.systemBlue, points: days1),
            DailyUsageChartView.Series(name: "Kimi", color: NSColor.systemPurple, points: days2),
        ]
        let view = DailyUsageChartView(series: series, width: 251, height: 100, symbol: "¥")
        view.frame = NSRect(x: 0, y: 0, width: 251, height: 100)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("ERROR: 无法创建位图")
            exit(2)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("ERROR: PNG 编码失败")
            exit(2)
        }
        try? png.write(to: URL(fileURLWithPath: "/tmp/chart.png"))
        print("已导出 /tmp/chart.png")
        exit(0)
    }

    /// 联并千行余额刷新链路自测：--lbqhtest [baseURL] [apiKey] [--force]
    /// 用假服务器/真实服务验证「refresh → snapshot → 聚合标题」全链路（不污染真实配置）。
    /// 传 --force 时走 POST /api/balance/fetch 立即抓取分支（对应手动「立即刷新」）。
    static func runLBQHTest() -> Never {
        let args = CommandLine.arguments
        let force = args.contains("--force")
        let base = args.count >= 3 ? args[2] : LBQHConfig.defaultBaseURL
        let key = args.count >= 4 ? args[3] : LBQHConfig.defaultAPIKey
        var config = AppConfig(sites: [], refreshIntervalMinutes: 30,
                               defaultLowBalanceThreshold: 50)
        config.lbqh = LBQHConfig(enabled: true, baseURL: base, apiKey: key,
                                 showInMenuBar: true, lowBalanceThreshold: 0)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let mc = MonitorController(config: config)
            mc.onStateChange = {
                if let snap = mc.snapshots[MonitorController.lbqhSiteID] {
                    print("snapshot ok=\(snap.ok) balance=\(snap.balance ?? -1) currency=\(snap.currency ?? "nil")")
                    print("tracking dayUsage=\(snap.tracking?.dayUsage ?? -1)")
                } else {
                    print("snapshot: nil（未查到）")
                }
                print("aggregateShortTitle: \(mc.aggregateShortTitle().string)")
            }
            // 直接 await refresh()：不走 refreshNow() 的 @MainActor 跳转，
            // 避免无头自测无主 RunLoop 导致死锁（refresh() 本身非 MainActor 隔离）
            await mc.refresh(forceLBQH: force)
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    /// 配置加载/迁移自测：--configtest
    /// 验证含已移除平台（如 siliconflow）的旧配置能容错迁移，只打印站点元信息（不泄露 token）。
    static func runConfigTest() -> Never {
        let config = ConfigStore.loadConfig()
        print("刷新间隔 \(config.refreshIntervalMinutes)min · 默认阈值 \(config.defaultLowBalanceThreshold) · 站点 \(config.sites.count) 个")
        for (i, s) in config.sites.enumerated() {
            print("site\(i + 1): name=\(s.name) enabled=\(s.enabled) provider=\(s.provider.rawValue) url=\(s.baseURL)")
        }
        exit(0)
    }

    /// 测量菜单宽度：文字行实际宽度 vs menu.size，用于校准折线图宽度
    static func runMeasure() -> Never {
        let text = "✓ DeepSeek — 余额 ¥60.45\n本日 ¥15.66 · 本月 ¥12.50 · 更新 12:34:56"
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
        ])
        print("文字内容宽度: \(attr.size().width)")

        let menu = NSMenu()
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = attr
        menu.addItem(item)
        print("纯文字菜单 size: \(menu.size.width)")

        // 视图项菜单
        let menu2 = NSMenu()
        let item2 = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item2.attributedTitle = attr
        menu2.addItem(item2)
        let chart = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 90))
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu2.addItem(chartItem)
        print("含视图项菜单 size: \(menu2.size.width)")

        // 两行字符串 size() 是否返回最宽行
        let line1 = "✓ DeepSeek — 余额 ¥60.45"
        let line2 = "本日 ¥15.66 · 本月 ¥12.50 · 更新 12:34:56"
        let two = NSMutableAttributedString()
        two.append(NSAttributedString(string: line1, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        two.append(NSAttributedString(string: "\n" + line2, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        print("两行字符串 size(): \(two.size().width)")
        print("line1 单独宽度: \((line1 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)")
        print("line2 单独宽度: \((line2 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)")
        exit(0)
    }
}
