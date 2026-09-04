# API Mug — macOS 菜单栏 API 余额/用量监测

原生 **Swift + AppKit** 写的 macOS 菜单栏应用：**无 Dock 图标、纯代码 UI、无 Xcode**。常驻菜单栏，实时监测多个 API 平台（DeepSeek、NewAPI/中转站、OpenRouter、Kimi、StepFun、DeepInfra、**联并千行 MaaS**）的余额与用量，余额低时通知提醒。

它也是一个「**联并千行 MaaS（LBQH）客户端**」：配合自托管的 [lbqh-monitor](https://github.com/ryanyang7899/lbqh-monitor) 服务端，就能在 macOS 菜单栏随时查看联并千行平台的余额，无需打开网页。

---

## 一、下载安装（2 分钟）

### 1. 下载

从 GitHub Releases 页下载最新版安装包，两种格式任选：

- **`APIMug-vX.Y.Z-macOS.dmg`** —— 磁盘映像，拖入即装（推荐）
- **`APIMug-vX.Y.Z-macOS.zip`** —— 压缩包，解压即用

下载地址：**[github.com/ryanyang7899/APIMug/releases/latest](https://github.com/ryanyang7899/APIMug/releases/latest)**

### 2. 安装

**方式 A：DMG（推荐）**

1. 打开下载的 `.dmg`，会挂载出一个磁盘映像窗口
2. 把 **APIMug** 图标**拖进 /Applications 文件夹**
3. 从「应用程序」里双击 APIMug 启动

**方式 B：ZIP**

1. 双击解压得到 `APIMug.app`
2. 将其拖入 `/Applications/`（或任意位置）
3. 双击启动

### 3. 首次打开的「安全提示」处理

因为是个人开发者签名（ad-hoc 签名，非 App Store 公证），首次打开可能被 macOS Gatekeeper 拦截。任选一种方式解除：

- **右键** APIMug 图标 → 选「打开」→ 在弹窗里点「打开」；
- 或终端执行：`xattr -dr com.apple.quarantine /Applications/APIMug.app`

### 4. 确认运行成功

菜单栏（屏幕顶部）出现一个 **☕ 图标**即运行成功。点击图标弹出监控菜单，点「设置…」开始配置。

> **要求**：macOS 14.0+（Sonoma 及以上），Apple Silicon（M1/M2/M3/M4）或 Intel 均可。

---

## 二、快速上手（使用细节）

### 1. 添加一个监控站点

1. 点菜单栏 **☕** → **设置…**（或按 `⌘ ,`）
2. 在「监测站点」区点 **+ 添加站点**
3. 填四项：
   - **名称**：任意，如 `DeepSeek`（菜单栏会用它的**首字符**做标注）
   - **URL**：平台 Base 地址（选「类型」会自动填默认值）
   - **Token**：平台的 API Key
   - **类型**：平台协议，见下方支持列表
4. 点「**保存**」（立即生效）或「**应用**」（保留窗口继续改）

### 2. 菜单栏显示什么

每个站点可独立勾选「菜单栏显示」：**余额 / 本日用量 / 本月用量**。勾选后菜单栏聚合显示，数据带**站点名首字符**标注，一眼区分：

| 显示 | 含义 |
|---|---|
| `D ¥40.74` | DeepSeek 余额 40.74 元 |
| `K 今日 ¥3.89` | Kimi 今日用量 |
| `联 ¥984.50` | 联并千行（LBQH）余额 |
| `⚠︎` 前缀 | 有站点查询报错 |
| `!` 前缀 | 有站点余额低于阈值 |
| `☕` | 所有站点都未勾选显示项 |

点开菜单弹窗，每个站点两行详情：`✓ 平台 — 余额/用量` + `本日 · 本月 · 更新时间`；弹窗顶部是**近 7 日用量折线图**（悬停查看每日明细）。

### 3. 低余额提醒

- 设置 → 通用设置 → **默认低余额阈值**（元/美元），或每个站点单独设「低余额阈值」
- 余额低于阈值时：菜单栏出现 `!` 前缀 + 系统通知
- 每个站点**每天只提醒一次**，不会刷屏

### 4. 刷新频率

- 设置 → 通用设置 → **自动刷新间隔（分钟）**，默认 30 分钟
- 菜单栏 → **立即刷新**（`⌘ R`）随时手动刷新

### 5. 其他常用功能

- **开机自动启动**：通用设置勾选「开机自动启动」即生效（无需去系统设置）
- **检查更新**：菜单底部「检查更新…」，或应用启动时自动检查；发现新版菜单栏出现「⬆ 前往下载」+ 系统通知
- **本日/本月用量**：对只有余额的余额型平台，App 用**余额差值**推算用量（充值会抬升基准、不清零累计），不用平台用量接口

---

## 三、与联并千行（lbqh-monitor）联动 ⭐

APIMug 内置「联并千行余额监控」，配合服务端 [**lbqh-monitor**](https://github.com/ryanyang7899/lbqh-monitor)（多用户版，Docker 部署）使用。整体架构：

```
┌─────────────────────┐     GET /user/balance      ┌──────────────────────┐
│   APIMug (macOS)    │ ─────────────────────────▶ │  lbqh-monitor 服务端   │
│   菜单栏显示余额      │   Authorization: Bearer    │  (Docker, :8100)      │
└─────────────────────┘ ◀───────────────────────── └──────────────────────┘
                                                         │ 定时登录抓取
                                                         ▼
                                                联并千行 MaaS 平台
                                                (lbqh.paratera.com)
```

**lbqh-monitor** 负责：用户注册登录、填写联并千行平台账号密码、自动登录 + 验证码识别 + 抓余额入库（每用户按自己的间隔），并通过 `GET /user/balance` 对外开放。APIMug 只需拉取余额，不需要实现登录、验证码、翻页。

### 第一步：部署 lbqh-monitor（服务端，只需一次）

> 完整部署文档见 [lbqh-monitor 仓库](https://github.com/ryanyang7899/lbqh-monitor)。以下是 Docker 快速步骤：

```bash
git clone https://github.com/ryanyang7899/lbqh-monitor.git
cd lbqh-monitor
cp .env.example .env        # 编辑：MAAS_API_KEY 必填（验证码识别模型的 API Key）
docker compose up -d --build   # 构建并启动（首次构建较慢，镜像含 Chromium 约 4GB）
```

启动后浏览器打开 `http://<服务器IP>:8100/`：

1. **注册第一个邮箱**（自动成为管理员），登录
2. 「配置管理」→ 填写联并千行平台账号、密码、验证码模型 API 地址与 Key、抓取间隔 → 点「**测试连接**」→ 保存，拖开「启用」开关
3. 「监控看板」开始显示余额卡片与曲线，即服务端已就绪

### 第二步：创建 API 令牌

1. 网页端「**API 令牌**」页 → 点「创建令牌」（如命名 `apimug`）
2. 复制令牌（格式 `lbqh-<32位hex>`）——**只在创建时明文显示一次**，请立即保存

### 第三步：APIMug 里启用联并千行监控

1. 打开 APIMug → **设置…** → **通用设置**
2. 勾选「**监控联并千行余额**」
3. 填写：
   - **服务地址**：lbqh-monitor 的地址，默认 `http://localhost:8100`（服务跑在别的机器/容器时填 `http://<IP或域名>:8100`，**无需写 http:// 前缀**，App 会自动补全）
   - **API 令牌**：上一步创建的 `lbqh-...` 令牌
4. （可选）勾选「在菜单栏显示余额」；设「低余额阈值」
5. 点「**保存**」

### 第四步：查看余额

- 菜单栏聚合标题出现 **`联 ¥984.50`**（若勾选了「在菜单栏显示余额」）
- 点开菜单弹窗，站点区多了一行：**`✓ 联并千行 — 余额 ¥984.50`** + 更新时间
- 余额同样参与**低余额提醒**（低于阈值 → `!` 前缀 + 通知）和**近 7 日折线图**

### 立即刷新 vs 定时刷新

| 触发方式 | 服务端行为 | 成本 |
|---|---|---|
| APIMug 定时自动刷新（默认 30 分钟） | `GET /user/balance` 读**已缓存**余额 | 无 |
| 菜单栏「立即刷新」 | 额外触发 `POST /api/balance/fetch`，服务端**重新登录+验证码识别**抓一次（约 10~20 秒） | 消耗验证码模型 API 少量额度 |

> ⚠️ `POST /api/balance/fetch` 每次都会消耗服务端验证码识别模型的 API 额度，请勿高频使用「立即刷新」。日常看余额用定时刷新即可。

### 常见问题（联动）

- **菜单显示「鉴权失败 (HTTP 401)」**：API 令牌填错或已删除。去 lbqh-monitor 网页端「API 令牌」页重新创建/确认。
- **显示「接口不存在 (HTTP 404)」**：服务端还没抓到第一条数据（刚部署/未启用/未配置好）。等几秒让服务端完成首次抓取，或先到看板「立即更新余额」。
- **连不上（网络错误）**：确认 lbqh-monitor 容器在运行（`docker logs -f lbqh-monitor`）；APIMug 所在机器能访问该地址（容器默认只监听本机，跨机器需调整 docker-compose 端口映射或反向代理）。
- **余额长时间不变**：两次抓取间账户没消费属正常（服务端默认每小时才抓一次）。

---

## 支持平台一览

每站点可选一种协议（均为「普通 API Key + 一次请求」）：

| 类型 | 接口 | 显示内容 |
|---|---|---|
| `deepseek`（DeepSeek 官方） | `GET {base}/user/balance` | 余额（¥） |
| `newapi`（OpenAI / NewAPI 网关） | `GET {base}/v1/dashboard/billing/subscription` + `/usage` | 今日/本月用量、额度上限（$） |
| `openrouter`（OpenRouter） | `GET {base}/api/v1/key` | 余额、今日/本月用量、上限（$） |
| `kimi`（月之暗面） | `GET {base}/v1/users/me/balance` | 余额（¥，现金+代金券） |
| `stepfun`（阶跃星辰） | `GET {base}/v1/accounts` | 余额（¥） |
| `deepinfra`（DeepInfra） | `GET {base}/payment/checklist` | 余额、上限（$） |
| **`lbqh`（联并千行）** | `GET {base}/user/balance` + `POST /api/balance/fetch` | 余额（¥，配合 lbqh-monitor） |

> 说明：`newapi` 协议适用于自建 new-api / one-api 网关及基于它们的中转站；**OpenAI 官方已封禁普通 Key 访问 billing 接口**，请勿用于 OpenAI 官方。切换协议时设置窗口会自动填入该平台默认 Base URL。余额型平台（DeepSeek/Kimi/StepFun/DeepInfra）自动启用本日/本月用量追踪。
>
> 硅基流动（SiliconFlow）因官方停用余额查询接口（`/v1/user/info` 余额字段自 2025-12-25 返回 0），已从支持列表中移除。

---

## 开发构建（可选）

```sh
./build.sh                 # 编译 + 签名 + 重启应用
./build.sh --no-launch     # 只构建不启动
./build.sh 1.2.0           # 指定版本号（须与发布 tag 一致）
```

无头自测：`APIMug --test <provider> <url> <token>`、`APIMug --lbqhtest [baseURL] [令牌] [--force]`、`APIMug --sim` 等。

---

## 说明

- 包 ID：`com.alfye.NewAPIMonitor`，配置存于 `~/Library/Preferences/com.alfye.NewAPIMonitor.plist`（改名不影响既有配置）
- 首次启动会尝试从旧版应用的 `site1_*` 配置迁移
- Apple Silicon 必须 ad-hoc 签名，build.sh 已处理
