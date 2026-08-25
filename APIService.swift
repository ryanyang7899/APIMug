import Foundation

enum APIError: Error, CustomStringConvertible {
    case badURL(String)
    case httpStatus(Int)
    case decode(Error)
    case network(Error)

    var description: String {
        switch self {
        case .badURL(let s):
            return "无效 URL: \(s)"
        case .httpStatus(let code):
            switch code {
            case 401, 403:
                return "鉴权失败 (HTTP \(code)) — 检查 Token"
            case 404:
                return "接口不存在 (HTTP 404) — 检查 URL 或协议类型"
            default:
                return "HTTP \(code)"
            }
        case .decode(let e):
            return "解析失败: \(e.localizedDescription)"
        case .network(let e):
            return "网络错误: \(e.localizedDescription)"
        }
    }
}

enum APIService {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    static func fetch(_ site: Site) async throws -> SiteResult {
        switch site.provider {
        case .deepseek:
            return try await fetchDeepSeek(site)
        case .newapi:
            return try await fetchNewAPI(site)
        case .openrouter:
            return try await fetchOpenRouter(site)
        case .kimi:
            return try await fetchKimi(site)
        case .stepfun:
            return try await fetchStepFun(site)
        case .deepinfra:
            return try await fetchDeepInfra(site)
        case .lbqh:
            return try await fetchLBQH(site)
        }
    }

    // MARK: - DeepSeek 官方

    private static func fetchDeepSeek(_ site: Site) async throws -> SiteResult {
        let url = try makeURL(base: site.baseURL, path: "user/balance")
        let data = try await get(url, token: site.apiToken)
        let resp: DeepSeekBalanceResponse
        do {
            resp = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw APIError.decode(error)
        }

        // 按币种汇总 total_balance（字段是字符串）
        var balanceByCurrency: [String: Double] = [:]
        for info in resp.balanceInfos {
            if let v = Double(info.totalBalance) {
                balanceByCurrency[info.currency, default: 0] += v
            }
        }
        let currency = balanceByCurrency.keys.sorted().first ?? "CNY"
        let balance = balanceByCurrency[currency]
        return SiteResult(siteID: site.id, balance: balance, currency: currency,
                          usedToday: nil, usedThisMonth: nil, hardLimit: nil,
                          checkedAt: Date())
    }

    // MARK: - OpenAI / NewAPI 兼容

    private static func fetchNewAPI(_ site: Site) async throws -> SiteResult {
        // 1) subscription
        let subURL = try makeURL(base: site.baseURL, path: "v1/dashboard/billing/subscription")
        let subData = try await get(subURL, token: site.apiToken)
        let sub: NewAPISubscription
        do {
            sub = try JSONDecoder().decode(NewAPISubscription.self, from: subData)
        } catch {
            throw APIError.decode(error)
        }

        // 2) usage：今日 + 本月
        let now = Date()
        let today = AppFormatters.day.string(from: now)
        let cal = Calendar.current
        let monthFirstDate = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let monthFirst = AppFormatters.day.string(from: monthFirstDate)

        var usedToday: Double = 0
        var usedThisMonth: Double = 0
        do {
            usedToday = try await fetchUsage(base: site.baseURL, token: site.apiToken, from: today, to: today)
            usedThisMonth = try await fetchUsage(base: site.baseURL, token: site.apiToken, from: monthFirst, to: today)
        } catch {
            // usage 查询失败不致命（部分服务可能不实现该接口），保留 0
        }

        return SiteResult(siteID: site.id, balance: nil, currency: "USD",
                          usedToday: usedToday, usedThisMonth: usedThisMonth,
                          hardLimit: sub.hardLimitUsd, checkedAt: Date())
    }

    private static func fetchUsage(base: String, token: String, from: String, to: String) async throws -> Double {
        let url = try makeURL(base: base, path: "v1/dashboard/billing/usage",
                              query: [URLQueryItem(name: "start_date", value: from),
                                      URLQueryItem(name: "end_date", value: to)])
        let data = try await get(url, token: token)
        let usage: NewAPIUsage
        do {
            usage = try JSONDecoder().decode(NewAPIUsage.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        return usage.totalUsage / 100.0  // 分 → 美元
    }

    // MARK: - OpenRouter

    private static func fetchOpenRouter(_ site: Site) async throws -> SiteResult {
        let url = try makeURL(base: site.baseURL, path: "api/v1/key")
        let data = try await get(url, token: site.apiToken)
        let resp: OpenRouterKeyResponse
        do {
            resp = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        let d = resp.data
        return SiteResult(siteID: site.id,
                          balance: d.limitRemaining?.value,
                          currency: "USD",
                          usedToday: d.usageDaily?.value,
                          usedThisMonth: d.usageMonthly?.value,
                          hardLimit: d.limit?.value,
                          checkedAt: Date())
    }

    // MARK: - Kimi（月之暗面）

    private static func fetchKimi(_ site: Site) async throws -> SiteResult {
        let url = try makeURL(base: site.baseURL, path: "v1/users/me/balance")
        let data = try await get(url, token: site.apiToken)
        let resp: KimiBalanceResponse
        do {
            resp = try JSONDecoder().decode(KimiBalanceResponse.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        return SiteResult(siteID: site.id,
                          balance: resp.data.availableBalance?.value,
                          currency: "CNY",
                          usedToday: nil, usedThisMonth: nil, hardLimit: nil,
                          checkedAt: Date())
    }

    // MARK: - 阶跃星辰 StepFun

    private static func fetchStepFun(_ site: Site) async throws -> SiteResult {
        let url = try makeURL(base: site.baseURL, path: "v1/accounts")
        let data = try await get(url, token: site.apiToken)
        let resp: StepFunAccount
        do {
            resp = try JSONDecoder().decode(StepFunAccount.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        return SiteResult(siteID: site.id,
                          balance: resp.balance?.value,
                          currency: "CNY",
                          usedToday: nil, usedThisMonth: nil, hardLimit: nil,
                          checkedAt: Date())
    }

    // MARK: - DeepInfra

    private static func fetchDeepInfra(_ site: Site) async throws -> SiteResult {
        let url = try makeURL(base: site.baseURL, path: "payment/checklist",
                              query: [URLQueryItem(name: "compute_owed", value: "true")])
        let data = try await get(url, token: site.apiToken)
        let resp: DeepInfraChecklist
        do {
            resp = try JSONDecoder().decode(DeepInfraChecklist.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        // stripe_balance：负值=可用余额，正值=欠款 → 余额取相反数
        let balance = resp.stripeBalance?.value.map { -$0 }
        return SiteResult(siteID: site.id,
                          balance: balance,
                          currency: "USD",
                          usedToday: nil, usedThisMonth: nil,
                          hardLimit: resp.limit?.value,
                          checkedAt: Date())
    }

    // MARK: - 联并千行 MaaS（多用户服务）

    /// 联并千行查询（新版接口，鉴权对齐 DeepSeek 的 Bearer 令牌）：
    /// - forceUpdate == false：GET {base}/user/balance，DeepSeek 风格，读缓存（无成本）
    /// - forceUpdate == true ：POST {base}/api/balance/fetch 同步抓一次（登录+验证码，约 10~20 秒，有成本），
    ///                          再 GET {base}/user/balance 取最新余额（fetch 返回的是内部快照，结构不固定）
    /// 返回结构 /user/balance 与 DeepSeek 一致：{is_available, balance_infos:[{currency, total_balance, ...}]}
    static func fetchLBQH(_ site: Site, forceUpdate: Bool = false) async throws -> SiteResult {
        // 立即刷新：先 POST fetch 触发抓取（同步等待），再用 /user/balance 拿数据
        if forceUpdate {
            let fetchURL = try makeURL(base: site.baseURL, path: "api/balance/fetch")
            var fetchReq = URLRequest(url: fetchURL)
            fetchReq.httpMethod = "POST"
            fetchReq.setValue("Bearer \(site.apiToken)", forHTTPHeaderField: "Authorization")
            fetchReq.timeoutInterval = 60
            _ = try await getWithHeaders(fetchReq, session: lbqhFetchSession)
        }

        // 查余额（GET /user/balance）
        let url = try makeURL(base: site.baseURL, path: "user/balance")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(site.apiToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let data = try await getWithHeaders(req)
        let resp: DeepSeekBalanceResponse
        do {
            resp = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        // 与 DeepSeek 相同：按币种汇总 total_balance（字段是字符串）
        var balanceByCurrency: [String: Double] = [:]
        for info in resp.balanceInfos {
            if let v = Double(info.totalBalance) {
                balanceByCurrency[info.currency, default: 0] += v
            }
        }
        let currency = balanceByCurrency.keys.sorted().first ?? "CNY"
        let balance = balanceByCurrency[currency]
        return SiteResult(siteID: site.id, balance: balance, currency: currency,
                          usedToday: nil, usedThisMonth: nil, hardLimit: nil,
                          checkedAt: Date())
    }

    /// 立即抓取专用 session：抓取登录+验证码耗时 10~20 秒，需要比默认更宽松的超时
    private static let lbqhFetchSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    // MARK: - 底层请求

    private static func makeURL(base: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        var baseStr = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseStr.hasSuffix("/") { baseStr.removeLast() }
        // 未带 scheme 的地址（如内网 IP "100.66.1.1:8100"）自动补 http://，否则 URLComponents 解析失败报「无效 URL」
        if !baseStr.contains("://") {
            baseStr = "http://" + baseStr
        }
        guard var comps = URLComponents(string: baseStr) else {
            throw APIError.badURL(base)
        }
        comps.path = comps.path + "/" + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL(base) }
        return url
    }

    private static func get(_ url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return try await getWithHeaders(req)
    }

    /// 发送请求并校验状态码（请求头已由调用方设好，含 lbqh 的 X-API-Key）。
    /// 可传入自定义 session（如 lbqh 立即抓取的长超时 session）。
    private static func getWithHeaders(_ req: URLRequest, session s: URLSession = session) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await s.data(for: req)
        } catch {
            throw APIError.network(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode)
        }
        return data
    }
}
