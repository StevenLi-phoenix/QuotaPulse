# QuotaPulse — 研究笔记（2026-10-16）

来源：`steipete/CodexBar`、`tddworks/ClaudeBar`、`sam-pop/QuotaBar` 源码（只读，clone 在 scratchpad）、opencode.ai/docs/zen、本机凭据存在性探测（只 `test -f`，未读内容）、一次性 curl 探测（token 通过子 shell 替换注入，响应脱敏）。

## 本机凭据现状（2026-10-16 03:00）

| 来源 | 存在 | 备注 |
|---|---|---|
| `~/.claude/.credentials.json` | ✅ | `claudeAiOauth.accessToken` **已过期**（expiresAt 2026-10-09）。macOS 上 Claude Code 以 Keychain 为主，文件是旧副本 |
| Keychain `Claude Code-credentials` | ✅ | 真正新鲜的 token 在这里。Claude Code 自己通过 `/usr/bin/security` 写入，因此用 `security find-generic-password -w` 读取不会触发 ACL 弹窗（CodexBar 的 "securityCLI" 读取策略同理） |
| `~/.codex/auth.json` | ✅ | `tokens.{access_token,refresh_token,id_token,account_id}`，`auth_mode=chatgpt`，`last_refresh=2026-06-14`，JWT `exp` 2026-06-24 → **已过期 4 个月**，需要 refresh |
| `~/.local/share/opencode/auth.json` | ❌ | 本机没装 opencode；OpenCode 走设置里手填 API key |
| `DEEPSEEK_API_KEY` env | ❌ | 走设置里手填 |

## 供应商接口速查

### Claude（Claude Code OAuth）
- 凭据：Keychain service `Claude Code-credentials`（JSON 同文件格式）→ 退回 `$CLAUDE_CONFIG_DIR/.credentials.json` / `~/.claude/.credentials.json`。JSON：`{"claudeAiOauth":{"accessToken","refreshToken","expiresAt"(ms),"scopes":[],"rateLimitTier","subscriptionType"}}`
- 用量：`GET https://api.anthropic.com/api/oauth/usage`，header `Authorization: Bearer <token>`、`anthropic-beta: oauth-2025-04-20`、`Accept: application/json`、UA `claude-cli/<ver> (external, cli)`。
- 响应：`five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet`/`seven_day_oauth_apps` 各 `{utilization: 0-100, resets_at: ISO8601}`；`extra_usage {is_enabled, monthly_limit, used_credits, utilization, currency}`；新形态 `limits: [{kind, group, percent, resets_at, scope{model{id,display_name}}, is_active}]`。
- 401 body：`{"type":"error","error":{"type":"authentication_error","message":"OAuth access token has expired…"}}`（实测）。
- 429：无 `Retry-After` 时按 5 分钟冷却（CodexBar `ClaudeOAuthUsageRateLimitGate`），claude-code#31637 说明限流可能持续数小时 → 默认轮询 ≥ 5 min，429 退避指数到 30 min 上限。
- Refresh：`POST https://platform.claude.com/v1/oauth/token` `{grant_type:refresh_token, refresh_token, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`。**默认不刷新**：Claude Code 自己会刷新并轮换 refresh token，第三方刷新会让 Claude Code 的 Keychain 副本失效（CodexBar 为此做了 "delegated refresh"）。QuotaPulse 的策略：每次轮询重读 Keychain，过期则显示"打开 Claude Code 即可自动刷新"。

### OpenAI Codex（ChatGPT 订阅）
- 凭据：`$CODEX_HOME/auth.json` 或 `~/.codex/auth.json`：`{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"last_refresh":ISO,"tokens":{"access_token"(JWT),"refresh_token","id_token","account_id"}}`。JWT payload 含 `exp`、`https://api.openai.com/auth.chatgpt_plan_type`。
- 用量：`GET https://chatgpt.com/backend-api/wham/usage`，header `Authorization: Bearer <access_token>`、`ChatGPT-Account-Id: <account_id>`、`Accept: application/json`。
- 响应：`{plan_type, rate_limit:{primary_window:{used_percent:Int, reset_at:epoch_s, limit_window_seconds}, secondary_window:{…}}, credits?, additional_rate_limits:[{limit_name, metered_feature, rate_limit:{…}}]}`。primary = 5h（18000s），secondary = 周（604800s）。
- 401 body（实测，token 过期）：`{"error":{"message":"Could not parse your authentication token…","code":"unauthorized_unknown"},"status":401}`。
- Refresh：`POST https://auth.openai.com/oauth/token` JSON `{client_id:"app_EMoamEEZ73f0CkXaXp7hrann", grant_type:"refresh_token", refresh_token}` → `{access_token, refresh_token?, id_token?}`；错误码 `refresh_token_expired`/`refresh_token_reused`/`invalid_grant`。CodexBar 刷新后把新 token 写回 auth.json（保留其他键、更新 `last_refresh`）。QuotaPulse 同样做（默认开，可关）。

### DeepSeek
- 有 `gateway.json` 时改走网关（架构决定第 8 条），下面是无网关时的直连方式。
- 凭据：API key（env `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY` 或设置里手填，存自家 Keychain）。
- 余额：`GET https://api.deepseek.com/user/balance` `Authorization: Bearer <key>` → `{is_available, balance_infos:[{currency:"CNY"|"USD", total_balance:"12.34", granted_balance, topped_up_balance}]}`（金额是字符串）。一个币种一项，顺序不固定，可能含余额为 0 的币种，App 取余额最大的一项。
- 用量明细需要 platform.deepseek.com 的 web session（`/api/v0/usage/amount`），不做。

### OpenCode（Zen / Go）
- 有 `gateway.json` 时改走网关（架构决定第 8 条），下面是无网关时的直连方式。
- 凭据：API key（`opencode-go` 条目，本地在 `~/.local/share/opencode/auth.json` → `{"opencode-go":{"key":"…"}}`，本机不存在）或设置手填。
- Go 订阅用量：`GET https://opencode.ai/zen/go/v1/usage` `Authorization: Bearer <key>` → `{usage:{rolling:{usagePercent|usedPercent|…, resetInSec|resetAt…}, weekly:{…}, monthly:{…}}, renewAt?}`。键名不稳定，解析时按候选列表取（percentKeys / resetInKeys / resetAtKeys）。
- PAYG 余额/月度花费只有 console cookie 接口（`/console/api/billing/status`、`/console/api/usage/summary`），需要浏览器 cookie，不做。

### 智谱 GLM（z.ai / bigmodel.cn，扩展点）
- `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`（global 为 `https://api.z.ai/…`）`Authorization: Bearer <key>` → `{code, data:{limits:[{type, percentage, usage, currentValue, remaining, nextResetTime(ms), unit, number}]}}`。已按此实现 `ZaiProvider`（默认关闭，需手填 key）。

### Grok Bot（桌面 App，Cursor 后端）
- Grok Bot 是 Electron 应用（bundle id `com.anysphere.sand`，`/Applications/Grok Bot.app`），后端是 Cursor 的 `https://api2.cursor.sh`，Connect 协议（JSON）。`POST /aiserver.v1.DashboardService/GetSandUsageStatus`，body `{}`，头 `Authorization: Bearer <access token>`、`Content-Type: application/json`、`Connect-Protocol-Version: 1` → `{currentPeriodStart, nextResetTimestampUtc, usagePercent, cursorPlanName, grokPlanLabel, prepaidAvailableCents(字符串), additionalUsageLimit{state, spentCents}, …}`。窗口 7 天、`fixedCadence`；protobuf JSON 省略零值，新周期没有 `usagePercent` 键，按 0 处理。`GetCurrentPeriodUsage` 给同一个百分比（`planUsage.totalPercentUsed`），没有读它。
- 凭据：`~/Library/Application Support/Grok Bot/sand-secrets.json`，`cursor-accounts` 是 JSON 字符串 `{active, accounts:{<id>:{cursor-access-token, cursor-refresh-token, …}}}`，值是 Electron `safeStorage` 密文（`v10` + AES-128-CBC，key = PBKDF2-SHA1(Keychain 项 `Grok Bot Safe Storage` / 账户 `Grok Bot Key` 的口令, "saltysalt", 1003, 16)，IV 16 个空格），可带 `scoped:v1:<hash>:` 前缀。口令用 `/usr/bin/security -w` 读（5 秒超时），解密在进程内用 CommonCrypto。
- 不刷新 token：Grok Bot 自己轮换，第二个刷新方可能把它挤下线；过期报 “Open Grok Bot to refresh it”。
- 展示信息（名称 Grok Bot、副标题 Desktop app、灰色 0x8E8E93、图标 `scope`、dashboard cursor.com/dashboard/spending）随快照发布，是第一个不需要客户端升级的 provider。
- 只有装了 Grok Bot 的 Mac 能读；另一台 Mac 读不到时是 `notConfigured`，`CloudPublisher` 不写这类快照，所以不会覆盖有读数那台的 `provider.grokbot`。网关 `reported` 集合没加它（网关侧未支持）。

## 架构决定

1. **Mac 是 hub**：Mac Mini 常开、在 Tailscale 上。菜单栏 App 持凭据、轮询、存样本、算预测，并用 `NWListener` 提供 `GET /v1/health|snapshot|history`（Bearer token）。iOS/watch 只消费 JSON，不碰任何供应商凭据。hub 现在是可选直连，本地脚本和设备日志上传走它；数据同步默认走第 7 条的 iCloud。
2. **预测**在 `QuotaCore.ForecastEngine`：对当前窗口（`resetsAt - windowDuration` 之后，或检测到 utilization 下跌即视为新窗口）内样本做最小二乘回归；输出 reset 时预计用量、打满时刻、pace（相对线性预算的偏差）。余额型对最近 7 天做回归得花费和剩余时间，同时给两套单位：`rate`（每天）/`daysRemaining` 和 `ratePerHour`（每小时）/`hoursRemaining`，旧版 App 继续读前一对，读不到小时字段的记录由 `Forecast.balanceRatePerHour`/`balanceHoursRemaining` 换算；显示上剩余 72 小时以内用小时，以上用天。样本不足 2 个或跨度 < 10 分钟 → `insufficient`。
3. **macOS 签名**：主 App 用 Automatic 签名（CloudKit 需要 provisioning profile），无 sandbox；widget 用 Manual 签名、有 sandbox、无 profile。两者共用团队前缀 App Group `88U7V98QAC.app.lishuyu.quotapulse`，数据在对应 Group Container 下。iOS/watchOS 用 App Group `group.app.lishuyu.quotapulse`（模拟器不校验，真机需在开发者账号开通）。
4. **通知权限懒申请**：阈值告警默认关；打开时才 `requestAuthorization`，避免无人值守时弹系统对话框。
5. **Keychain 读取走 `/usr/bin/security` 子进程 + 3 秒超时**：Claude Code 自己用该 CLI 写入，ACL 已包含它，因此不会弹窗；万一弹窗，超时 kill 子进程即关闭对话框并退回文件读取。
6. **不做浏览器 cookie 导入**：CodexBar 的 cookie 路线需要读 Chrome cookie 数据库（Keychain 弹窗 + 隐私面大），与"无人值守、不弹窗"冲突。

7. **同步走 CloudKit 私有库**：Mac 发布、iPhone/Watch 读取，不再要求设备能连上 Mac。容器 `iCloud.app.lishuyu.quotapulse`，zone `QuotaPulse`，记录类型 `QuotaBlob`（payload 为 lzfse 压缩的 JSON，schema 2）。记录：`provider.<id>`（读数）、`history.<id>`（7 天降采样历史）、`samples.<id>.<n>`（90 天原始样本，分片，每片一条记录）、`settings`（整份设置，`updatedAt` 新者胜）。
   - 选 CloudKit 而不是另外两种：KVS 有写入节流，iCloud Documents 在手表上不可靠。
   - 凭据（API key、hub token、gateway 配置）不走 CloudKit，走 iCloud 钥匙串：`synchronizable` 的 data-protection 钥匙串条目，需要 `keychain-access-groups` 权限（`macOS/App/QuotaPulse.entitlements`）。旧的本地条目在首次读取时搬进去；写入被拒时保留在本机，不丢。Claude Code / Codex 的登录不同步：它们是 CLI 自己的会话，刷新 token 会轮换，复制到两台 Mac 会让其中一台失效。
   - gateway 配置以钥匙串为准；`gateway.json`（0600）是它的副本，供脚本和 Windows 读取。文件有、钥匙串没有时导入。
   - 记录按 provider 分：账号内每个 provider 只有一份用量，所以 `provider.<id>`（快照）和 `history.<id>`（历史）由任何读到该 provider 的 Mac 写入。快照：较新的读数覆盖较旧的，较旧的写入会被跳过。历史：两台 Mac 的样本按（窗口, 时间）合并。删除历史时写入截止时间 `clearedAt`，早于它的样本在所有 Mac 上都被丢弃。发布在 `CloudPublisher` 内串行：actor 在 await 处可重入，并发的两次发布实测会重复写 history。
   - 全部是 Apple Development 签名，走 Development 环境，schema 首次写入时自动创建。
   - 没用 `encryptedValues`：它依赖 iCloud Keychain，没开的设备会读不到。
   - 无 entitlement 时 `CKContainer(identifier:)` 直接 SIGTRAP（实测退出码 133），所以 `CloudKitRecordStore.standard()` 先用 SecTask 检查 entitlement，缺失返回 nil，未签名构建和 `swift test` 不会崩。
   - App ID 刚关联容器后，服务器可能返回 `Invalid bundle ID for container`（CKError permissionFailure 一类），同一秒内有的请求成功、有的失败。iPhone 实测（UTC，2026-11-06）：profile 00:39:46 生成；00:44–00:47 大多失败；00:52 起 11 次 snapshot、9 次 history 全部成功。Apple 没有说明原因，时间线符合服务端逐步生效。Mac 的 App ID 从未出现。`CloudError.rejected` 把它转成人话，App 在前台每 30 秒重试。
   - Mac 停止发布不会产生任何错误，所以 snapshot 超过 30 分钟时界面显示过期横幅。
   - provider 自描述：`ProviderID` 是字符串 struct（单值编码与原 enum 相同；不实现 `CodingKeyRepresentable`，`[ProviderID: …]` 仍是数组形式，与已存的 settings 兼容），`ProviderSnapshot.info`（`ProviderInfo`：名称、副标题、kind、品牌色、SF Symbol、dashboard）由读到它的 Mac 盖章发布。展示端一律用 `snapshot.display` = `info` → `ProviderInfo.builtIn`（原 5 个，给旧 Mac 和网关的快照兜底）→ 中性样式。Grok Bot 的样式只在 `GrokBotProvider.swift`，展示代码不认识它。
   - 发现新 provider 用索引记录 `providers`（`CloudProviderIndex`），不枚举 zone：`recordZoneChanges(since: nil, desiredKeys: [])` 实测翻 20 页只拿到 1 条记录（变更流要走完每次历史写入），iPhone 和小组件等不起。发布端在已有的那次 fetch 里顺带取索引，缺了就把本轮 due 的 id 并进去写回（含被保留的他人更新读数）；只增不删，两台 Mac 同时写丢掉的条目在下一次心跳补回；读不了的索引（更新的 schema）不覆盖。读取端第一次请求取原 5 个 + 索引，索引里有别的才发第二次。macm4 实测两次请求共 321 ms。
   - 旧客户端兼容：旧 iPhone 只按原 5 个 id 取 `provider.<id>`，碰不到新记录；hub 的 `/v1/snapshot` 默认只给原 5 个（`QuotaSnapshot.legacyCompatible`），新客户端带 `?providers=all`。旧 enum 解码到未知 id 会让整份快照失败，测试 `HubLegacyClientTests` 用一份旧 enum 复现。网关上报去掉 `info`，保持原格式。

8. **网关 hub（可选）**：Mac 的 `QuotaPulse/gateway.json`（0600，`{baseURL, token}`，baseURL 默认 `https://llm.lishuyu.app/llm/hub`）存在时，OpenCode、DeepSeek 不再用本机上游 key（也不读 `opencode/auth.json`），改为 `GET <base>/v1/snapshot` 取对应 provider；一轮刷新只请求一次（`GatewaySnapshotCache` 按本轮 `now` 共享）。401/403 → unauthorized，网络错误 → network，429 → rateLimited，snapshot 缺该 provider → notConfigured，provider 自带的错误 status 原样返回。刷新结束后 `POST <base>/v1/report` 上报 claude、codex、zai 的快照（去掉 `account.label`）和 opencode、deepseek 的 `forecasts`；失败只记 `QPLog.hub`，5 分钟内不重试。日期是不带小数秒的 ISO-8601（`2026-11-06T20:33:35Z`），`ProviderStatus` 用 Swift 合成的枚举编码（`{"ok":{}}`、`{"server":{"code":500,"_1":"msg"}}`）。没有 `gateway.json` 时行为与之前完全一致，这是回滚路径。有 base path 的 hub 不接 `/v1/telemetry`，iOS 跳过日志上传。接口约定见网关仓库。

9. **Claude、Codex、GLM 也由网关读，Mac 是回退**：phm 的 quota-reader 插件用单独的登录读 Claude、Codex（refresh token 会轮换，共用一份会把对方挤下线；Worker 读不了 Codex，`chatgpt.com` 对 Worker 返回 403，对 phm 和 mini 返回 200），Worker 读 GLM。有 `gateway.json` 时这三家先看 `GatewayLink.reading`：快照里的读数 `status` 是 ok、`fetchedAt` 在 30 分钟内、`source` 是 `reader` 或 `gateway` 就直接用，不碰本机凭据；否则走原来的本地读取，这就是自动回退。`source` 是 `mac` 的读数是自己上报的回声，不算，否则 Mac 会用自己 25 分钟前的读数骗自己。上报带 `source:"mac"`，网关给的读数只报 `forecasts`（条目带 `source`，网关看到就只取预测），预测仍然只在 Mac 上算，历史样本照常用读数累积。网关优先级：自己读的、reader、Mac，各自须是新鲜好读数；都不满足取最新的一份，所以 reader 过期时 App 能看到“要重新登录”。

## Reset 语义实测（2026-10-16 12:23Z，本机真实账号）

| | Claude（Max 20x） | Codex（Plus） |
|---|---|---|
| 5h 窗口 `resets_at` | `2026-10-16T15:29:59.89Z`（整个白天不变；样本 11:41Z→12:18Z 期间固定）。窗口始于 10:30Z 附近的首条请求，值对齐到 **:00/:30 半小时边界** | 本账号 `secondary_window: null`，只有 `primary_window`：`limit_window_seconds=604800`、`reset_at=1792649646`（2026-10-22T06:14:06Z，**非整点**，固定周期滚动） |
| 周窗口 | `2026-10-22T14:59:59.89Z` = 上周首次请求后 7 天，同样对齐半小时 | 同上（单一窗口） |
| 单窗口 | `plan_type == "pro"` → 只有周窗口是正常的（`.notApplicable`，UI 隐藏）；其他套餐出现 `secondary_window: null` 是 Codex 服务端已知 bug（`.notReported`，灰色占位 "Not reported by Codex API (known bug)"，API 恢复后自动显示） | |
| 到期行为 | 额度清零，**不开新窗**；下次请求才开新窗，届时 `resets_at` 变为新值（utilization 回落 → 新周期） | 额度与周期一起重置，`reset_at` 按周期长度前推 |
| 新字段 | `five_hour.limit_dollars/used_dollars/remaining_dollars/locked_reason`（均 null）；`limits[]` 含 `kind: session / weekly_all / weekly_scoped`（后者 15%，无 `scope.model`） | `credits.balance` 是 **credits 数量不是美元**（62484.43），`approx_local_messages` 区间、`rate_limit_reset_credits`、`model_usage` |

落地（`QuotaCore`）：`UsageWindow.resetSemantics`（Claude `.rollingFromFirstUse`，Codex/OpenCode/GLM `.fixedCadence`）；`effectiveResetsAt(now:)`（fixed 过期后按周期前推，rolling 过期返回 nil）；`phase(now:)` → `.active / .awaitingFirstUse / .unknown`；`currentUtilization(now:)`（rolling 过期视为 0）。预测与 pace 用 `cycleStart(now:)`；rolling 过期直接 `.insufficient`。UI：rolling 过期显示 "Fresh · next window starts on first request"（小组件 "Fresh"），不再出现负倒计时；Codex 单窗口标注 "Only window reported for this plan"，credits 显示为 "62,484 credits"。
