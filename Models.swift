import Foundation

/// 站点协议类型（每站点可选）
enum ProviderType: String, Codable, CaseIterable {
    /// DeepSeek 官方：GET {base}/user/balance
    case deepseek = "deepseek"
    /// OpenAI / NewAPI 兼容：GET {base}/v1/dashboard/billing/*
    case newapi = "newapi"
    /// OpenRouter：GET {base}/api/v1/key
    case openrouter = "openrouter"
    /// 月之暗面 Kimi：GET {base}/v1/users/me/balance
    case kimi = "kimi"
    /// 硅基流动 SiliconFlow：GET {base}/v1/user/info
    case siliconflow = "siliconflow"
    /// 阶跃星辰 StepFun：GET {base}/v1/accounts
    case stepfun = "stepfun"
    /// DeepInfra：GET {base}/payment/checklist
    case deepinfra = "deepinfra"

    /// 设置界面显示名
    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek 官方"
        case .newapi: return "OpenAI / NewAPI"
        case .openrouter: return "OpenRouter"
        case .kimi: return "Kimi（月之暗面）"
        case .siliconflow: return "硅基流动 SiliconFlow"
        case .stepfun: return "阶跃星辰 StepFun"
        case .deepinfra: return "DeepInfra"
        }
    }

    /// 该平台的默认 Base URL（新增站点时自动填入）
    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .newapi: return ""
        case .openrouter: return "https://openrouter.ai"
        case .kimi: return "https://api.moonshot.cn"
        case .siliconflow: return "https://api.siliconflow.cn"
        case .stepfun: return "https://api.stepfun.com"
        case .deepinfra: return "https://api.deepinfra.com"
        }
    }

    /// 是否使用「余额基准法」推算本日/本月用量（仅余额型平台）
    var usesBalanceTracking: Bool {
        switch self {
        case .deepseek, .kimi, .siliconflow, .stepfun, .deepinfra: return true
        case .newapi, .openrouter: return false   // 这两种平台 API 直接返回用量
        }
    }

    /// 该平台余额/用量的主要币种
    var displayCurrency: String {
        switch self {
        case .deepseek, .kimi, .siliconflow, .stepfun: return "CNY"
        case .newapi, .openrouter, .deepinfra: return "USD"
        }
    }
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
    /// 菜单栏是否显示本站点余额（nil = 不显示）
    var showBalanceInMenuBar: Bool?
    /// 菜单栏是否显示本站点本日用量（nil = 不显示）
    var showTodayUsageInMenuBar: Bool?
    /// 菜单栏是否显示本站点本月用量（nil = 不显示）
    var showMonthUsageInMenuBar: Bool?
}

/// 全局配置
struct AppConfig: Codable {
    var sites: [Site]
    var refreshIntervalMinutes: Int
    var defaultLowBalanceThreshold: Double
    /// 更新检查频率（nil = 每次启动）
    var updateCheckFrequency: UpdateFrequency?
    // —— 以下为已废弃的全局菜单栏显示开关，仅用于迁移到各站点后清空 ——
    var showBalanceInMenuBar: Bool?
    var showTodayUsageInMenuBar: Bool?
    var showMonthUsageInMenuBar: Bool?
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

// MARK: - 各平台余额/用量响应 DTO

/// 兼容「JSON 数字」和「JSON 字符串数字」两种字段，缺失/null 时为 nil
struct FlexibleDouble: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = Double(s) }
        else { value = nil }
    }
}

/// OpenRouter：GET /api/v1/key
struct OpenRouterKeyResponse: Decodable {
    let data: OpenRouterKeyData
}
struct OpenRouterKeyData: Decodable {
    let limit: FlexibleDouble?          // 信用额度上限（null = 无限）
    let limitRemaining: FlexibleDouble? // 剩余额度
    let usageDaily: FlexibleDouble?     // 今日用量
    let usageWeekly: FlexibleDouble?    // 本周用量
    let usageMonthly: FlexibleDouble?   // 本月用量
    enum CodingKeys: String, CodingKey {
        case limit
        case limitRemaining = "limit_remaining"
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
    }
}

/// 月之暗面 Kimi：GET /v1/users/me/balance
struct KimiBalanceResponse: Decodable {
    let data: KimiBalanceData
}
struct KimiBalanceData: Decodable {
    let availableBalance: FlexibleDouble?  // 可用余额
    let cashBalance: FlexibleDouble?       // 现金余额
    let voucherBalance: FlexibleDouble?    // 代金券余额
    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case cashBalance = "cash_balance"
        case voucherBalance = "voucher_balance"
    }
}

/// 硅基流动 SiliconFlow：GET /v1/user/info
struct SiliconFlowUserInfo: Decodable {
    let data: SiliconFlowUserData
}
struct SiliconFlowUserData: Decodable {
    let balance: FlexibleDouble?        // 赠送余额
    let chargeBalance: FlexibleDouble?  // 充值余额
    let totalBalance: FlexibleDouble?   // 总余额
}

/// 阶跃星辰 StepFun：GET /v1/accounts
struct StepFunAccount: Decodable {
    let balance: FlexibleDouble?          // 当前可用余额
    let type: String?                     // prepaid / postpaid
    let totalCashBalance: FlexibleDouble? // 总充值
    let totalVoucherBalance: FlexibleDouble? // 总赠送
    enum CodingKeys: String, CodingKey {
        case balance
        case type
        case totalCashBalance = "total_cash_balance"
        case totalVoucherBalance = "total_voucher_balance"
    }
}

/// DeepInfra：GET /payment/checklist
struct DeepInfraChecklist: Decodable {
    let stripeBalance: FlexibleDouble?  // 负值=可用余额，正值=欠款
    let recent: FlexibleDouble?         // 上次发票后用量
    let limit: FlexibleDouble?
    let suspended: Bool?
    enum CodingKeys: String, CodingKey {
        case stripeBalance = "stripe_balance"
        case recent
        case limit
        case suspended
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
