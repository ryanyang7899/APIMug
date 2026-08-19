import Foundation

/// UserDefaults 读写：配置 / 快照 / 提醒去重日期
enum ConfigStore {
    static let defaults = UserDefaults.standard

    static let configKey = "appConfig"
    static let snapshotsKey = "siteSnapshots"
    static let alertDaysKey = "alertDays"

    static func loadConfig() -> AppConfig {
        if let data = defaults.data(forKey: configKey) {
            if var config = try? JSONDecoder().decode(AppConfig.self, from: data) {
                migrateDisplayFlags(&config)
                return config
            }
            // 正常解码失败：多为配置里含已移除的平台（如 siliconflow），容错迁移后重存
            if var config = migrateRemovedProviders(from: data) {
                migrateDisplayFlags(&config)
                return config
            }
        }
        return migratedDefaultConfig()
    }

    /// 容错迁移：把 config 的 JSON 按「provider 为原始字符串」读取，
    /// 丢弃 provider 已不存在的站点（如已移除的 siliconflow），保留其余配置。
    /// 返回 nil 表示连容错解码也不可用（数据损坏，走默认配置）。
    private static func migrateRemovedProviders(from data: Data) -> AppConfig? {
        guard let tolerant = try? JSONDecoder().decode(TolerantConfig.self, from: data) else {
            return nil
        }
        let valid = Set(ProviderType.allCases.map { $0.rawValue })
        var config = AppConfig(sites: [],
                               refreshIntervalMinutes: tolerant.refreshIntervalMinutes,
                               defaultLowBalanceThreshold: tolerant.defaultLowBalanceThreshold,
                               updateCheckFrequency: tolerant.updateCheckFrequency)
        config.showBalanceInMenuBar = tolerant.showBalanceInMenuBar
        config.showTodayUsageInMenuBar = tolerant.showTodayUsageInMenuBar
        config.showMonthUsageInMenuBar = tolerant.showMonthUsageInMenuBar
        for s in tolerant.sites where valid.contains(s.providerRaw) {
            config.sites.append(s.toSite())
        }
        saveConfig(config)
        return config
    }

    /// 一次性迁移：旧版「全局菜单栏显示开关」→ 各站点。迁移后清空全局字段。
    private static func migrateDisplayFlags(_ config: inout AppConfig) {
        let hasLegacy = config.showBalanceInMenuBar != nil
            || config.showTodayUsageInMenuBar != nil
            || config.showMonthUsageInMenuBar != nil
        guard hasLegacy else { return }
        let legacyBalance = config.showBalanceInMenuBar ?? false
        let legacyToday = config.showTodayUsageInMenuBar ?? false
        let legacyMonth = config.showMonthUsageInMenuBar ?? false
        for i in config.sites.indices {
            if config.sites[i].showBalanceInMenuBar == nil {
                config.sites[i].showBalanceInMenuBar = legacyBalance
            }
            if config.sites[i].showTodayUsageInMenuBar == nil {
                config.sites[i].showTodayUsageInMenuBar = legacyToday
            }
            if config.sites[i].showMonthUsageInMenuBar == nil {
                config.sites[i].showMonthUsageInMenuBar = legacyMonth
            }
        }
        config.showBalanceInMenuBar = nil
        config.showTodayUsageInMenuBar = nil
        config.showMonthUsageInMenuBar = nil
        saveConfig(config)
    }

    static func saveConfig(_ config: AppConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

    /// 首次启动：若不存在 appConfig，尝试从旧版 NewAPI Monitor 的 plist 迁移 site1（DeepSeek 官方）。
    static func migratedDefaultConfig() -> AppConfig {
        var sites: [Site] = []
        if defaults.object(forKey: "site1_enabled") != nil,
           defaults.bool(forKey: "site1_enabled") == true,
           let url = defaults.string(forKey: "site1_url"),
           let token = defaults.string(forKey: "site1_token"),
           !url.isEmpty, !token.isEmpty {
            let name = defaults.string(forKey: "site1_name") ?? "site1"
            sites.append(Site(id: UUID(), name: name, enabled: true, baseURL: url,
                              apiToken: token, provider: .deepseek, lowBalanceThreshold: 0))
        }
        if sites.isEmpty {
            sites.append(Site(id: UUID(), name: "site1", enabled: false,
                              baseURL: "https://api.deepseek.com", apiToken: "",
                              provider: .deepseek, lowBalanceThreshold: 0))
        }
        let config = AppConfig(sites: sites, refreshIntervalMinutes: 30,
                               defaultLowBalanceThreshold: 50)
        saveConfig(config)
        return config
    }

    static func loadSnapshots() -> [UUID: SiteSnapshot] {
        guard let data = defaults.data(forKey: snapshotsKey),
              let dict = try? JSONDecoder().decode([String: SiteSnapshot].self, from: data) else {
            return [:]
        }
        var result: [UUID: SiteSnapshot] = [:]
        for (key, value) in dict {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    static func saveSnapshots(_ snapshots: [UUID: SiteSnapshot]) {
        var dict: [String: SiteSnapshot] = [:]
        for (id, value) in snapshots { dict[id.uuidString] = value }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: snapshotsKey)
        }
    }

    static func lastAlertDay(for id: UUID) -> String? {
        guard let dict = defaults.dictionary(forKey: alertDaysKey) as? [String: String] else { return nil }
        return dict[id.uuidString]
    }

    static func setLastAlertDay(_ day: String, for id: UUID) {
        var dict = defaults.dictionary(forKey: alertDaysKey) as? [String: String] ?? [:]
        dict[id.uuidString] = day
        defaults.set(dict, forKey: alertDaysKey)
    }

    // MARK: - 更新检查状态

    static let lastUpdateCheckKey = "lastUpdateCheck"
    static let ignoredVersionKey = "ignoredVersion"
    static let lastNotifiedVersionKey = "lastNotifiedVersion"

    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: lastUpdateCheckKey) as? Date }
        set { defaults.set(newValue, forKey: lastUpdateCheckKey) }
    }

    static var ignoredVersion: String? {
        get { defaults.string(forKey: ignoredVersionKey) }
        set { defaults.set(newValue, forKey: ignoredVersionKey) }
    }

    static var lastNotifiedVersion: String? {
        get { defaults.string(forKey: lastNotifiedVersionKey) }
        set { defaults.set(newValue, forKey: lastNotifiedVersionKey) }
    }

    // MARK: - 每日用量历史（折线图，按站点）

    static let dailyUsageKey = "dailyUsageHistory"

    static func loadDailyUsage() -> [UUID: [String: Double]] {
        guard let data = defaults.data(forKey: dailyUsageKey),
              let dict = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else {
            return [:]
        }
        var result: [UUID: [String: Double]] = [:]
        for (k, v) in dict {
            if let id = UUID(uuidString: k) { result[id] = v }
        }
        return result
    }

    static func saveDailyUsage(_ dict: [UUID: [String: Double]]) {
        var s: [String: [String: Double]] = [:]
        for (k, v) in dict { s[k.uuidString] = v }
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: dailyUsageKey)
        }
    }

    // MARK: - 容错解码（迁移已移除平台）

    /// Site 的容错形态：provider 以原始字符串读取，避免未知平台导致整个配置解码失败。
    private struct TolerantSite: Decodable {
        let id: UUID
        let name: String
        let enabled: Bool
        let baseURL: String
        let apiToken: String
        let providerRaw: String
        let lowBalanceThreshold: Double
        let showBalanceInMenuBar: Bool?
        let showTodayUsageInMenuBar: Bool?
        let showMonthUsageInMenuBar: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, enabled, baseURL, apiToken, lowBalanceThreshold
            case showBalanceInMenuBar, showTodayUsageInMenuBar, showMonthUsageInMenuBar
            case providerRaw = "provider"
        }

        func toSite() -> Site {
            Site(id: id, name: name, enabled: enabled, baseURL: baseURL,
                 apiToken: apiToken, provider: ProviderType(rawValue: providerRaw)!,
                 lowBalanceThreshold: lowBalanceThreshold,
                 showBalanceInMenuBar: showBalanceInMenuBar,
                 showTodayUsageInMenuBar: showTodayUsageInMenuBar,
                 showMonthUsageInMenuBar: showMonthUsageInMenuBar)
        }
    }

    /// AppConfig 的容错形态：sites 用 TolerantSite，全局旧开关字段按可选保留。
    private struct TolerantConfig: Decodable {
        let sites: [TolerantSite]
        let refreshIntervalMinutes: Int
        let defaultLowBalanceThreshold: Double
        let updateCheckFrequency: UpdateFrequency?
        let showBalanceInMenuBar: Bool?
        let showTodayUsageInMenuBar: Bool?
        let showMonthUsageInMenuBar: Bool?
    }
}
