import Foundation

/// 刷新编排 + 定时器 + 低余额判定 + 聚合标题
final class MonitorController {
    var onStateChange: (() -> Void)?

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

    func refreshNow() {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    /// 更新配置（持久化 + 重置定时器 + 刷新）
    func setConfig(_ newConfig: AppConfig) {
        config = newConfig
        ConfigStore.saveConfig(newConfig)
        scheduleTimer()
        refreshNow()
    }

    func refresh() async {
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
        updateDailyUsageHistory()
        onStateChange?()
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
        return result
    }

    /// 低余额判定（仅 DeepSeek 有余额概念）
    private func evaluateLowBalance(site: Site, snapshot: SiteSnapshot) {
        guard let balance = snapshot.balance, site.provider == .deepseek else { return }
        let threshold = site.lowBalanceThreshold > 0 ? site.lowBalanceThreshold : config.defaultLowBalanceThreshold
        if balance < threshold {
            NotificationManager.shared.notifyLowBalance(site: site, balance: balance,
                                                        currency: snapshot.currency ?? "CNY")
        }
    }

    /// 状态栏短标题
    func aggregateShortTitle() -> String {
        let enabledSites = config.sites.filter { $0.enabled }

        // 有站点报错 → ⚠︎
        if enabledSites.contains(where: { snapshots[$0.id]?.ok == false }) {
            return "⚠︎"
        }
        // 有站点低于阈值 → !
        let anyLow = enabledSites.contains { site in
            guard let snap = snapshots[site.id], let b = snap.balance else { return false }
            let t = site.lowBalanceThreshold > 0 ? site.lowBalanceThreshold : config.defaultLowBalanceThreshold
            return b < t
        }
        if anyLow { return "!" }

        // 余额 / 本日 / 本月 三个显示项并列，互不冲突
        let showBalance = config.showBalanceInMenuBar ?? true
        let showToday = config.showTodayUsageInMenuBar ?? false
        let showMonth = config.showMonthUsageInMenuBar ?? false
        let hasCNY = enabledSites.contains(where: { $0.provider.displayCurrency == "CNY" })
        let symbol = hasCNY ? "¥" : "$"

        var parts: [String] = []

        // 余额总额（CNY 与 USD 分别汇总）
        if showBalance {
            let totalCNY = enabledSites.reduce(0.0) { sum, site in
                guard let snap = snapshots[site.id], snap.currency == "CNY" else { return sum }
                return sum + (snap.balance ?? 0)
            }
            let totalUSD = enabledSites.reduce(0.0) { sum, site in
                guard let snap = snapshots[site.id], snap.currency == "USD" else { return sum }
                return sum + (snap.balance ?? 0)
            }
            if totalCNY > 0 {
                parts.append("¥" + (AppFormatters.money.string(from: NSNumber(value: totalCNY)) ?? "0"))
            }
            if totalUSD > 0 {
                parts.append("$" + (AppFormatters.money.string(from: NSNumber(value: totalUSD)) ?? "0"))
            }
        }

        // 本日用量：余额追踪平台用 tracking，其他用 API 返回
        if showToday {
            let total = enabledSites.reduce(0.0) { sum, site in
                guard let snap = snapshots[site.id] else { return sum }
                return sum + (site.provider.usesBalanceTracking ? (snap.tracking?.dayUsage ?? 0) : (snap.usedToday ?? 0))
            }
            parts.append("今日 \(symbol)" + (AppFormatters.money.string(from: NSNumber(value: total)) ?? "0"))
        }

        // 本月用量
        if showMonth {
            let total = enabledSites.reduce(0.0) { sum, site in
                guard let snap = snapshots[site.id] else { return sum }
                return sum + (site.provider.usesBalanceTracking ? (snap.tracking?.monthUsage ?? 0) : (snap.usedThisMonth ?? 0))
            }
            parts.append("本月 \(symbol)" + (AppFormatters.money.string(from: NSNumber(value: total)) ?? "0"))
        }

        // 全部未开启 → 兜底显示余额，仍无则 ☕
        if parts.isEmpty {
            let totalCNY = enabledSites.reduce(0.0) { sum, site in
                guard let snap = snapshots[site.id], snap.currency == "CNY" else { return sum }
                return sum + (snap.balance ?? 0)
            }
            let totalUSD = enabledSites.reduce(0.0) { sum, site in
                guard let snap = snapshots[site.id], snap.currency == "USD" else { return sum }
                return sum + (snap.balance ?? 0)
            }
            if totalCNY > 0 {
                return "¥" + (AppFormatters.money.string(from: NSNumber(value: totalCNY)) ?? "0")
            }
            if totalUSD > 0 {
                return "$" + (AppFormatters.money.string(from: NSNumber(value: totalUSD)) ?? "0")
            }
            return "☕"
        }
        return parts.joined(separator: " · ")
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
