# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

API Mug —— macOS 菜单栏 API 余额/用量监测应用。**纯 Swift + AppKit，无 Xcode、无 SwiftUI、无 xib**，单次 `swiftc` 调用编译。菜单栏常驻（`LSUIElement` + 激活策略 `.accessory`），无 Dock 图标。

## 常用命令

```sh
./build.sh               # 编译 + 生成图标 + ad-hoc 签名 + 安装到 /Applications + 重启
./build.sh --no-launch   # 只构建不启动
./build.sh 1.1.0         # 指定版本号（必须与发布 tag 一致，更新检查靠它比较）
```

**无头自测**（跑可执行文件，进 `AppDelegate.static func main()` 的 CLI 分支，不启 GUI）：
```sh
build/APIMug.app/Contents/MacOS/APIMug --test <provider> <url> <token>  # provider: deepseek|newapi|openrouter|kimi|stepfun|deepinfra
build/APIMug.app/Contents/MacOS/APIMug --sim                            # 余额基准用量算法场景自测
build/APIMug.app/Contents/MacOS/APIMug --update [版本号]                 # 更新检查
build/APIMug.app/Contents/MacOS/APIMug --loginitem status|on|off        # 开机自启动
build/APIMug.app/Contents/MacOS/APIMug --charttest                      # 渲染折线图到 /tmp/chart.png
build/APIMug.app/Contents/MacOS/APIMug --configtest                     # 配置加载/迁移自测
build/APIMug.app/Contents/MacOS/APIMug --lbqhtest [baseURL] [令牌] [--force]  # 联并千行余额刷新链路自测
build/APIMug.app/Contents/MacOS/APIMug --measure                        # 测量菜单宽度（校准折线图）
```

本地假服务器（离线测协议解析）：`python3 test/fake_newapi.py 8787`、`python3 test/fake_providers.py 8788`。

**Git / 发布**：仓库 `github.com/ryanyang7899/APIMug`（公开）。直连 github.com 不通，须走本地代理 `127.0.0.1:7890`（已在仓库 git config 配好 `http.https://github.com.proxy`，push 前确认代理在运行）。发布流程：改 `build.sh` 默认版本 → `./build.sh` → 提交打 tag → `ditto -c -k --sequesterRsrc --keepParent build/APIMug.app build/APIMug-vX-macOS.zip` → `gh release create`。

## 架构（读多文件才能看懂的部分）

### 数据流
```
定时器/手动 → MonitorController.refresh() [MonitorController.swift]
  → APIService.fetch(site) [APIService.swift] 按 ProviderType 分发到各家 fetch 函数
  → 构造 SiteSnapshot（含 balance/usedToday/usedThisMonth/hardLimit）
  → 余额基准追踪：仅 usesBalanceTracking 平台 → UsageTracker.advance() [Models.swift]
  → updateDailyUsageHistory()：当日用量=各启用站点之和 → 持久化
  → onStateChange → AppDelegate.rebuildMenu(force:)
```

### 关键设计决策

- **6 种协议全部走同一 `SiteResult` 模型**：`balance`+`currency` / `usedToday` / `usedThisMonth` / `hardLimit`。新增平台 = 加 `ProviderType` 枚举 + `displayName`/`defaultBaseURL`/`usesBalanceTracking`/`displayCurrency` + APIService 一个 fetch 函数 + 设置下拉（自动用 `allCases`）+ 菜单行分支。
- **两套用量来源**：余额型平台（deepseek/kimi/stepfun/deepinfra）用 `UsageTracker` 余额差值累加推算本日/本月；newapi/openrouter 直接用 API 返回的 usage。`ProviderType.usesBalanceTracking` 决定走哪套。
- **联并千行（lbqh）是独立开关**：不是真实站点，勾选时由 MonitorController.refreshLBQH() 用固定虚拟 ID（`MonitorController.lbqhSiteID`）查询并存 snapshot，复用站点的展示/低余额提醒/折线图/用量追踪。配置在 `AppConfig.lbqh`（`LBQHConfig`）。接口走 `GET {base}/user/balance`（DeepSeek 风格，`Authorization: Bearer <令牌>`），手动立即刷新额外触发 `POST /api/balance/fetch`（`APIService.fetchLBQH(forceUpdate:)`）。
- **持久化**：全部 UserDefaults，经 `ConfigStore`。bundle id 是 `com.alfye.NewAPIMonitor`（沿袭原版应用，保证配置延续）。注意：经 `open` 启动时 defaults 域=bundle id；直接跑二进制时=进程名，CLI 自测读写不到 GUI 的配置。
- **菜单弹窗**：`rebuildMenu(force:)`。**菜单 tracking 期间绝不能修改菜单结构（会崩）**——`menuIsOpen` + `NSMenuDelegate.menuWillOpen` 强制下次打开前重建；tracking 中只更新状态栏标题。任何 `onStateChange` 触发的刷新都要走这个守卫。
- **菜单宽度**：折线图宽度 = `menuChartWidth()`（测量最宽文字行 + 40 内边距），保证图与弹窗同宽居中。
- **无头 CLI**：`AppDelegate.static func main()` 里 `Task.detached` + `DispatchSemaphore`（防主线程死锁），任务内 `exit()` 结束。
- **编译约束**：`-parse-as-library`（入口是 `@main`）、`-swift-version 5`（规避 Swift 6 严格并发）、`-target arm64-apple-macosx14.0`。新增源文件要加进 `build.sh` 的 swiftc 命令行。Apple Silicon 必须 ad-hoc 签名（build.sh 已处理）。

### 显示与交互要点

- 站点行两行富文本（`twoLine`）：第一行平台+余额，第二行本日/本月/更新时间。仅余额的美元平台（deepinfra）走单独分支显示「余额 $x」。
- 聚合标题 `aggregateShortTitle()`：`⚠︎`/`!`警告前缀 + 各站点**带首字符**的余额/用量（`D ¥40.74` = DeepSeek 余额）。显示项由**每个站点**的 `Site.showBalanceInMenuBar` / `showTodayUsageInMenuBar` / `showMonthUsageInMenuBar` 三个开关控制。旧版全局开关字段保留仅用于一次性迁移后清空。
- 折线图 `DailyUsageChartView`：**非翻转坐标系**（`yPos` 值越大越靠上，注意与默认 AppKit 坐标系相反）；40ms 定时轮询鼠标显示悬停气泡；数据源 `MonitorController.dailyUsageForLastDays(7)`，历史保留 10 天。

### 已知事项

- OpenAI 官方已封普通 `sk-` Key 的 `/v1/dashboard/billing/*`（403），`newapi` 协议用于自建 new-api/one-api 网关及中转站。
- **硅基流动已移除**（2026-08）：官方停用 `/v1/user/info` 余额字段（自 2025-12-25 返回 0）。若未来官方出替代接口，需在 ConfigStore 的 `migrateRemovedProviders` 之外恢复枚举 + fetch 函数，且旧配置中硅基流动站点已被丢弃。
- `evaluateLowBalance` 目前只对 `.deepseek` 触发低余额提醒（注释还写着"仅 DeepSeek"），其它余额型平台未接入，如需可扩展。
- 折线图历史从启用那天开始积累，早期 7 天中过去几天会是 0。
