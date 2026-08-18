import Foundation

/// UserDefaults 读写：配置 / 快照 / 提醒去重日期
enum ConfigStore {
    static let defaults = UserDefaults.standard

    static let configKey = "appConfig"
    static let snapshotsKey = "siteSnapshots"
    static let alertDaysKey = "alertDays"

    static func loadConfig() -> AppConfig {
        if let data = defaults.data(forKey: configKey),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        return migratedDefaultConfig()
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
}
