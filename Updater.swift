import Foundation

/// 更新检查频率
enum UpdateFrequency: String, Codable {
    case never
    case launch
    case daily
    case weekly
}

/// GitHub Releases API 的 latest release 响应（只取需要的字段）
struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let publishedAt: String?
    let body: String?
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case body
    }
}

/// 一次成功的更新检查结果
struct UpdateInfo {
    let latestVersion: String
    let releaseURL: URL
    let notes: String?
}

/// 更新检查器：查 GitHub Releases 最新版，与本地版本比较
enum Updater {
    static let repoOwner = "ryanyang7899"
    static let repoName = "APIMug"

    /// 当前安装版本（读 Info.plist）
    static func installedVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 检查是否有新版本。
    /// - 参数 `installed`：当前安装版本（CLI 自测时可传模拟值）
    /// - 返回 `UpdateInfo`：存在比当前更新的 Release
    /// - 返回 `nil`：已是最新版本，或仓库暂无 Release（latest 404）
    /// - 抛错：网络 / 解析失败
    static func check(installed: String = installedVersion()) async throws -> UpdateInfo? {
        let api = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: api) else {
            throw APIError.badURL(api)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("APIMug/\(installed)", forHTTPHeaderField: "User-Agent")  // GitHub API 强制要求 UA

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { return nil }  // 尚无 Release
            throw APIError.httpStatus(http.statusCode)
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
        let version = normalizeVersion(release.tagName)
        guard isNewer(version, than: installed),
              let releaseURL = URL(string: release.htmlURL) else {
            return nil
        }
        return UpdateInfo(latestVersion: version, releaseURL: releaseURL, notes: release.body)
    }

    /// 按频率判断启动时是否该自动检查
    static func shouldAutoCheck(config: AppConfig) -> Bool {
        switch config.updateCheckFrequency ?? .launch {
        case .never:
            return false
        case .launch:
            return true
        case .daily:
            return daysSinceLastCheck() >= 1
        case .weekly:
            return daysSinceLastCheck() >= 7
        }
    }

    private static func daysSinceLastCheck() -> Int {
        guard let last = ConfigStore.lastUpdateCheck else { return Int.max }
        return Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? Int.max
    }

    /// 语义化版本比较：v1.0.0 / 1.0 / 1.0.0 均可
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compareVersions(candidate, current) > 0
    }

    static func normalizeVersion(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    /// 返回正数 = a>b，0 = 相等，负数 = a<b
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let n = max(aParts.count, bParts.count)
        for i in 0..<n {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        return 0
    }
}
