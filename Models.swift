import Foundation

/// 站点协议类型（每站点可选）
enum ProviderType: String, Codable, CaseIterable {
    /// DeepSeek 官方：GET {base}/user/balance
    case deepseek = "deepseek"
    /// OpenAI / NewAPI 兼容：GET {base}/v1/dashboard/billing/*
    case newapi = "newapi"
}

/// 一个监测站点
struct Site: Codable, Identifiable {
    var id: UUID
    var name: String
    var enabled: Bool
    var baseURL: String
    var apiToken: String
    var provider: ProviderType
    /// 低余额阈值；0 表示使用全局默认值
    var lowBalanceThreshold: Double
}

/// 全局配置
struct AppConfig: Codable {
    var sites: [Site]
    var refreshIntervalMinutes: Int
    var defaultLowBalanceThreshold: Double
    /// 菜单栏是否显示余额总额（nil = 显示）
    var showBalanceInMenuBar: Bool?
    /// 菜单栏是否显示本日用量（nil = 不显示）
    var showTodayUsageInMenuBar: Bool?
    /// 菜单栏是否显示本月用量（nil = 不显示）
    var showMonthUsageInMenuBar: Bool?
    /// 更新检查频率（nil = 每次启动）
    var updateCheckFrequency: UpdateFrequency?
}

/// 某站点最近一次检查的结果（持久化，供菜单与聚合显示）
struct SiteSnapshot: Codable {
    var siteID: UUID
    var checkedAt: Date
    var day: String
    var ok: Bool
    var balance: Double?
    var currency: String?
    var usedToday: Double?
    var usedThisMonth: Double?
    var hardLimit: Double?
    var lastError: String?
    /// 本日/本月用量追踪状态（DeepSeek 等仅余额服务）
    var tracking: UsageTracking?
}

/// 本日/本月用量的余额基准追踪状态
struct UsageTracking: Codable {
    var day: String?
    var dayBaseline: Double?
    var dayUsage: Double = 0
    var month: String?
    var monthBaseline: Double?
    var monthUsage: Double = 0
    var lastBalance: Double?
}

/// 余额基准用量算法（纯函数，便于 CLI 自测）
enum UsageTracker {
    /// 用本次查询的余额推进追踪状态：
    /// - 首次启动当日 → 以当前余额设本日基准，本日用量清零
    /// - 跨天（0 点后首次查询）→ 重置本日基准
    /// - 每次查询 → 按「上次余额 - 本次余额」累加消费
    /// - 充值（本次余额 > 旧基准）→ 基准升到本次余额；已累加用量不清零
    /// - 本月同理，以自然月为周期
    static func advance(_ t: inout UsageTracking, date: Date, balance: Double) {
        let today = AppFormatters.day.string(from: date)
        let thisMonth = AppFormatters.month.string(from: date)

        // —— 本日 ——
        if t.dayBaseline == nil || t.day != today {
            t.day = today
            t.dayBaseline = balance
            t.dayUsage = 0
        } else {
            t.day = today
            if let pb = t.lastBalance, pb > balance {
                t.dayUsage += pb - balance
            }
            if let base = t.dayBaseline, balance > base {
                t.dayBaseline = balance   // 充值：基准升到最高
            }
        }

        // —— 本月 ——
        if t.monthBaseline == nil || t.month != thisMonth {
            t.month = thisMonth
            t.monthBaseline = balance
            t.monthUsage = 0
        } else {
            t.month = thisMonth
            if let pb = t.lastBalance, pb > balance {
                t.monthUsage += pb - balance
            }
            if let base = t.monthBaseline, balance > base {
                t.monthBaseline = balance
            }
        }

        t.lastBalance = balance
    }
}

/// 单次检查返回的结构化结果
struct SiteResult {
    let siteID: UUID
    let balance: Double?
    let currency: String?
    let usedToday: Double?
    let usedThisMonth: Double?
    let hardLimit: Double?
    let checkedAt: Date
}

// MARK: - 响应 DTO

struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]
    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct DeepSeekBalanceInfo: Decodable {
    let currency: String
    let totalBalance: String
    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
    }
}

struct NewAPISubscription: Decodable {
    let hardLimitUsd: Double
    enum CodingKeys: String, CodingKey {
        case hardLimitUsd = "hard_limit_usd"
    }
}

struct NewAPIUsage: Decodable {
    let totalUsage: Double
    enum CodingKeys: String, CodingKey {
        case totalUsage = "total_usage"
    }
}

// MARK: - 格式化工具

enum AppFormatters {
    /// yyyy-MM-dd
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// yyyy-MM
    static let month: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
    /// HH:mm:ss
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    /// 金额：两位小数
    static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
