# API Mug — macOS 菜单栏 API 监测

原生 Swift + AppKit 菜单栏 API 监测应用（无 Dock 图标，纯代码 UI，无 Xcode）。

支持每站点选择协议类型（7 种，均为「普通 API Key + 一次请求」）：

| 类型 | 接口 | 显示内容 |
|---|---|---|
| `deepseek`（DeepSeek 官方） | `GET {base}/user/balance` | 余额（¥） |
| `newapi`（OpenAI / NewAPI 网关） | `GET {base}/v1/dashboard/billing/subscription` + `/usage` | 今日/本月用量、额度上限（$） |
| `openrouter`（OpenRouter） | `GET {base}/api/v1/key` | 余额、今日/本月用量、上限（$） |
| `kimi`（月之暗面） | `GET {base}/v1/users/me/balance` | 余额（¥，现金+代金券） |
| `siliconflow`（硅基流动） | `GET {base}/v1/user/info` | 余额（¥） |
| `stepfun`（阶跃星辰） | `GET {base}/v1/accounts` | 余额（¥） |
| `deepinfra`（DeepInfra） | `GET {base}/payment/checklist` | 余额、上限（$） |

> 说明：`newapi` 协议适用于自建 new-api / one-api 网关及基于它们的中转站；**OpenAI 官方已封禁普通 Key 访问 billing 接口**，请勿用于 OpenAI 官方。切换协议时设置窗口会自动填入该平台的默认 Base URL。余额型平台（DeepSeek/Kimi/SiliconFlow/StepFun/DeepInfra）自动启用本日/本月用量追踪。

功能：多站点监测、菜单栏聚合显示、**本日/本月用量统计（余额基准法）**、低余额通知（按天去重）、定时自动刷新（默认 30 分钟）、设置窗口、**检查更新**、配置持久化（UserDefaults）。

## 检查更新

- 应用启动时按设置频率自动检查 GitHub 最新 Release（默认每次启动，可在 设置 → 更新 改为 关闭/每天/每周）
- 发现新版本 → 菜单栏出现「⬆ 发现新版本 vX — 前往下载」+ 系统通知（点击通知直接打开下载页）
- 菜单栏「检查更新…」可手动触发；支持「忽略此版本」
- 版本对比：读取 Info.plist `CFBundleShortVersionString`，与 GitHub tag（如 `v1.0.0`）语义化比较
- 自测：`APIMug --update [版本号]` 打印检查结果

## 本日/本月用量规则

针对只有余额、无用量接口的服务（DeepSeek 官方）：

- **本日用量**：每天第一次启动程序时以当时余额设基准，之后每次查询按余额差值累加消费；0 点 / 跨天重置基准重新计算。
- **本月用量**：同理，以自然月为周期，月初第一次启动时设基准，跨月重置。
- **充值处理**：当新查询余额高于旧基准（充值）时，基准升到查询到的最高余额；已累计的本日/本月用量**不清零，继续累加**。

菜单栏显示内容由 设置 → 通用设置 中的三个**并列勾选框**控制（互不冲突，可同时勾选）：

- ☑️ **菜单栏显示余额总额**（默认勾选）
- ☐ 菜单栏显示本日用量
- ☐ 菜单栏显示本月用量

勾选后相应内容**叠加**显示在菜单栏（如 `¥60.45 · 今日 ¥3.20 · 本月 ¥12.50`），不会互相替换。全部不勾时兜底显示余额。站点详情行始终显示 余额 + 本日 + 本月。

## 使用

```sh
cd /Users/ryan/APIMug
./build.sh                 # 编译 + 签名 + 重启应用
./build.sh --no-launch     # 只构建不启动
```

菜单栏图标说明（显示内容按设置开关而定）：
- `⚠︎` 有站点报错
- `!` 有站点余额低于阈值
- `今日 ¥x · 本月 ¥y` 用量统计（在设置中开启）
- `¥xx.xx` DeepSeek 余额汇总（用量显示关闭时）
- `今日 $x.xx` NewAPI 今日用量汇总
- `☕` 无数据时的默认显示

点菜单栏图标 → 设置… 增删站点、改协议/阈值/刷新间隔。

## 无头自测（CLI）

```sh
build/APIMug.app/Contents/MacOS/APIMug --test deepseek <url> <token>
build/APIMug.app/Contents/MacOS/APIMug --test newapi <url> <token>
# 例如：
build/APIMug.app/Contents/MacOS/APIMug --test deepseek https://api.deepseek.com sk-xxx
```

## 测试假服务

```sh
python3 test/fake_newapi.py 8787   # 本地模拟 NewAPI 接口
```

## 发布新版本

```sh
cd /Users/ryan/APIMug
# 1. 提交代码
git add -A && git commit -m "v1.1.0: 更新说明"
# 2. 打 tag
git tag v1.1.0
# 3. 构建（自动安装到 /Applications）
./build.sh 1.1.0
# 4. 打包并发布
ditto -c -k --sequesterRsrc --keepParent build/APIMug.app build/APIMug-v1.1.0-macOS.zip
gh release create v1.1.0 build/APIMug-v1.1.0-macOS.zip --title "v1.1.0" --notes "更新内容" --target main
```

> 注意：`build.sh [版本号]` 会把 `CFBundleShortVersionString` 设为该版本号，**必须与 tag 一致**，否则更新检查会误判。

## 说明

- 包 ID 沿用 `com.alfye.NewAPIMonitor`，配置写在 `~/Library/Preferences/com.alfye.NewAPIMonitor.plist`（改名不影响既有配置）。
- 首次启动会尝试从旧版应用的 `site1_*` 配置迁移，若为空则生成一个禁用占位站点。
- Apple Silicon 必须 ad-hoc 签名，build.sh 已处理。
