import AppKit
import Foundation

/// 刷新编排 + 定时器 + 低余额判定 + 聚合标题
final class MonitorController {
    var onStateChange: (() -> Void)?

    /// 联并千行虚拟站点的固定 ID（独立开关，不占用用户站点位）
    /// 注意：UUID 仅接受 0-9a-f 十六进制字符
    static let lbqhSiteID = UUID(uuidString: "0b0c0000-0000-0000-0000-000000000001")!

    private(set) var config: AppConfig
    private(set) var snapshots: [UUID: SiteSnapshot] = [:]
    /// 每日用量历史（按站点）：siteID → [日期(yyyy-MM-dd) → 当天用量]
    private(set) var dailyUsageHistory: [UUID: [String: Double]] = [:]
    private var timer: Timer?
    private var isRefreshing = false

    init(config: AppConfig) {
        self.config = config
        self.snapshots = ConfigStore.loadSnapshots()
        self.dailyUsageHistory = ConfigStore.loadDailyUsage()
    }

    /// 启动：立即刷新一次 + 开启定时
    func start() {
        scheduleTimer()
        refreshNow()
    }

    /// forceLBQH == true：此次刷新对联并千行走 POST /api/balance/fetch 立即抓取最新余额
    /// （手动「立即刷新」触发；定时刷新不传参，走低成本 GET）
    func refreshNow(forceLBQH: Bool = false) {
        Task { @MainActor [weak self] in
            await self?.refresh(forceLBQH: forceLBQH)
        }
    }

    /// 更新配置（持久化 + 重置定时器 + 刷新）
    func setConfig(_ newConfig: AppConfig) {
        config = newConfig
        ConfigStore.saveConfig(newConfig)
        scheduleTimer()
        refreshNow()
    }

    func refresh(forceLBQH: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for site in config.sites where site.enabled {
            do {
                let result = try await APIService.fetch(site)
                var snapshot = SiteSnapshot(siteID: site.id, checkedAt: result.checkedAt,
                                            day: AppFormatters.day.string(from: result.checkedAt),
                                            ok: true, balance: result.balance, currency: result.currency,
                                            usedToday: result.usedToday, usedThisMonth: result.usedThisMonth,
                                            hardLimit: result.hardLimit, lastError: nil)
                snapshot.tracking = snapshots[site.id]?.tracking   // 延续用量追踪状态
                if site.provider.usesBalanceTracking, let balance = result.balance {
                    var t = snapshot.tracking ?? UsageTracking()
                    UsageTracker.advance(&t, date: result.checkedAt, balance: balance)
                    snapshot.tracking = t
                }
                snapshots[site.id] = snapshot
                ConfigStore.saveSnapshots(snapshots)
                evaluateLowBalance(site: site, snapshot: snapshot)
            } catch {
                var snap = snapshots[site.id] ?? SiteSnapshot(siteID: site.id, checkedAt: Date(),
                                                              day: AppFormatters.day.string(from: Date()),
                                                              ok: true, balance: nil, currency: nil,
                                                              usedToday: nil, usedThisMonth: nil,
                                                              hardLimit: nil, lastError: nil)
                snap.ok = false
                snap.lastError = "\(error)"
                snap.checkedAt = Date()
                snap.day = AppFormatters.day.string(from: Date())
                snapshots[site.id] = snap
                ConfigStore.saveSnapshots(snapshots)
            }
        }
        // 联并千行：独立开关，勾选时额外查询余额（作为虚拟站点复用展示/提醒/历史机制）
        if let lbqh = config.lbqh, lbqh.enabled {
            await refreshLBQH(lbqh: lbqh, forceFetch: forceLBQH)
        }

        updateDailyUsageHistory()
        onStateChange?()
    }

    /// 联并千行余额查询（只查余额，元/人民币）。
    /// forceFetch == true 时走 POST /api/balance/fetch 立即抓取（手动刷新），否则 GET /api/balance 读缓存（定时刷新）。
    private func refreshLBQH(lbqh: LBQHConfig, forceFetch: Bool = false) async {
        let id = Self.lbqhSiteID
        let site = Site(id: id, name: "联并千行", enabled: true,
                        baseURL: lbqh.baseURL, apiToken: lbqh.apiKey,
                        provider: .lbqh, lowBalanceThreshold: lbqh.lowBalanceThreshold)
        do {
            let result = forceFetch
                ? try await APIService.fetchLBQH(site, forceUpdate: true)
                : try await APIService.fetch(site)
            var snapshot = SiteSnapshot(siteID: id, checkedAt: result.checkedAt,
                                        day: AppFormatters.day.string(from: result.checkedAt),
                                        ok: true, balance: result.balance, currency: result.currency,
                                        usedToday: result.usedToday, usedThisMonth: result.usedThisMonth,
                                        hardLimit: result.hardLimit, lastError: nil)
            snapshot.tracking = snapshots[id]?.tracking
            if let balance = result.balance {
                var t = snapshot.tracking ?? UsageTracking()
                UsageTracker.advance(&t, date: result.checkedAt, balance: balance)
                snapshot.tracking = t
            }
            snapshots[id] = snapshot
            ConfigStore.saveSnapshots(snapshots)
            evaluateLowBalance(site: site, snapshot: snapshot)
        } catch {
            var snap = snapshots[id] ?? SiteSnapshot(siteID: id, checkedAt: Date(),
                                                     day: AppFormatters.day.string(from: Date()),
                                                     ok: true, balance: nil, currency: "CNY",
                                                     usedToday: nil, usedThisMonth: nil,
                                                     hardLimit: nil, lastError: nil)
            snap.ok = false
            snap.lastError = "\(error)"
            snap.checkedAt = Date()
            snap.day = AppFormatters.day.string(from: Date())
            snapshots[id] = snap
            ConfigStore.saveSnapshots(snapshots)
        }
    }

    /// 每个启用站点把今日用量写入各自的历史（折线图数据源）
    private func updateDailyUsageHistory() {
        let today = AppFormatters.day.string(from: Date())
        for site in config.sites where site.enabled {
            guard let snap = snapshots[site.id], snap.ok else { continue }
            let usage = site.provider.usesBalanceTracking ? (snap.tracking?.dayUsage ?? 0) : (snap.usedToday ?? 0)
            var h = dailyUsageHistory[site.id] ?? [:]
            h[today] = usage
            // 只保留最近 10 天，避免无限增长
            let keys = h.keys.sorted()
            if keys.count > 10 {
                for k in keys.prefix(keys.count - 10) {
                    h.removeValue(forKey: k)
                }
            }
            dailyUsageHistory[site.id] = h
        }
        // 联并千行虚拟站点同样写入历史（复用余额基准用量）
        if let lbqh = config.lbqh, lbqh.enabled,
           let snap = snapshots[Self.lbqhSiteID], snap.ok {
            var h = dailyUsageHistory[Self.lbqhSiteID] ?? [:]
            h[today] = snap.tracking?.dayUsage ?? 0
            let keys = h.keys.sorted()
            if keys.count > 10 {
                for k in keys.prefix(keys.count - 10) {
                    h.removeValue(forKey: k)
                }
            }
            dailyUsageHistory[Self.lbqhSiteID] = h
        }
        ConfigStore.saveDailyUsage(dailyUsageHistory)
    }

    /// 各启用站点最近 n 天的每日用量序列（含今天，从旧到新），供折线图多系列使用
    func dailyUsageSeriesForLastDays(_ n: Int) -> [(site: Site, points: [(day: String, value: Double)])] {
        let cal = Calendar.current
        let today = Date()
        var days: [String] = []
        for i in (0..<n).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: today) {
                days.append(AppFormatters.day.string(from: d))
            }
        }
        var result: [(site: Site, points: [(day: String, value: Double)])] = []
        for site in config.sites where site.enabled {
            let h = dailyUsageHistory[site.id] ?? [:]
            let points = days.map { ($0, h[$0] ?? 0) }
            result.append((site, points))
        }
        // 联并千行虚拟站点同样加入折线图
        if let lbqh = config.lbqh, lbqh.enabled {
            let h = dailyUsageHistory[Self.lbqhSiteID] ?? [:]
            let points = days.map { ($0, h[$0] ?? 0) }
            let site = Site(id: Self.lbqhSiteID, name: "联并千行", enabled: true,
                            baseURL: lbqh.baseURL, apiToken: lbqh.apiKey,
                            provider: .lbqh, lowBalanceThreshold: lbqh.lowBalanceThreshold)
            result.append((site, points))
        }
        return result
    }

    /// 低余额判定（目前仅 DeepSeek 与联并千行有余额概念）
    private func evaluateLowBalance(site: Site, snapshot: SiteSnapshot) {
        guard let balance = snapshot.balance,
              site.provider == .deepseek || site.provider == .lbqh else { return }
        let threshold = site.lowBalanceThreshold > 0 ? site.lowBalanceThreshold : config.defaultLowBalanceThreshold
        if balance < threshold {
            NotificationManager.shared.notifyLowBalance(site: site, balance: balance,
                                                        currency: snapshot.currency ?? "CNY")
        }
    }

    /// 状态栏短标题（富文本）：按各站点自己的「菜单栏显示」开关拼装，
    /// 站点名首字符加粗，一眼区分是哪个站点的数据。
    func aggregateShortTitle() -> NSAttributedString {
        let enabledSites = config.sites.filter { $0.enabled }
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13)]

        // 警告前缀（⚠ 报错 / ! 低余额），与数据并列显示，不覆盖
        var anyError = enabledSites.contains(where: { snapshots[$0.id]?.ok == false })
        var anyLow = enabledSites.contains { site in
            guard let snap = snapshots[site.id], let b = snap.balance else { return false }
            let t = site.lowBalanceThreshold > 0 ? site.lowBalanceThreshold : config.defaultLowBalanceThreshold
            return b < t
        }
        // 联并千行也参与报错/低余额警告
        if let lbqh = config.lbqh, lbqh.enabled {
            if snapshots[Self.lbqhSiteID]?.ok == false { anyError = true }
            if let snap = snapshots[Self.lbqhSiteID], let b = snap.balance {
                let t = lbqh.lowBalanceThreshold > 0 ? lbqh.lowBalanceThreshold : config.defaultLowBalanceThreshold
                if b < t { anyLow = true }
            }
        }

        func money(_ v: Double) -> String {
            AppFormatters.money.string(from: NSNumber(value: v)) ?? "0"
        }

        var prefix = ""
        if anyError { prefix += "⚠︎ " }
        if anyLow { prefix += "! " }

        // 各站点要显示的片段：(首字符, 其余文字)
        var segments: [(tag: String, rest: String)] = []
        for site in enabledSites {
            guard let snap = snapshots[site.id], snap.ok else { continue }
            let tag = String(site.name.prefix(1))                       // 站点名首字符
            let symbol = site.provider.displayCurrency == "CNY" ? "¥" : "$"
            if site.showBalanceInMenuBar ?? false, let b = snap.balance {
                segments.append((tag, " \(symbol)\(money(b))"))
            }
            if site.showTodayUsageInMenuBar ?? false {
                let v = site.provider.usesBalanceTracking ? (snap.tracking?.dayUsage ?? 0) : (snap.usedToday ?? 0)
                segments.append((tag, " 今日 \(symbol)\(money(v))"))
            }
            if site.showMonthUsageInMenuBar ?? false {
                let v = site.provider.usesBalanceTracking ? (snap.tracking?.monthUsage ?? 0) : (snap.usedThisMonth ?? 0)
                segments.append((tag, " 本月 \(symbol)\(money(v))"))
            }
        }
        // 联并千行：独立开关，勾选时按 showInMenuBar 显示余额
        if let lbqh = config.lbqh, lbqh.enabled, lbqh.showInMenuBar,
           let snap = snapshots[Self.lbqhSiteID], snap.ok, let b = snap.balance {
            segments.append(("联", " ¥\(money(b))"))
        }

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: prefix, attributes: normal))
        if segments.isEmpty {
            result.append(NSAttributedString(string: "☕", attributes: normal))
            return result
        }
        for (i, seg) in segments.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: " · ", attributes: normal)) }
            result.append(NSAttributedString(string: seg.tag, attributes: bold))
            result.append(NSAttributedString(string: seg.rest, attributes: normal))
        }
        return result
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        let interval = max(1, TimeInterval(config.refreshIntervalMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
