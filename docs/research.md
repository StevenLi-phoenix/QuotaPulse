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
- 凭据：API key（env `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY` 或设置里手填，存自家 Keychain）。
- 余额：`GET https://api.deepseek.com/user/balance` `Authorization: Bearer <key>` → `{is_available, balance_infos:[{currency:"CNY"|"USD", total_balance:"12.34", granted_balance, topped_up_balance}]}`（金额是字符串）。
- 用量明细需要 platform.deepseek.com 的 web session（`/api/v0/usage/amount`），不做。

### OpenCode（Zen / Go）
- 凭据：API key（`opencode-go` 条目，本地在 `~/.local/share/opencode/auth.json` → `{"opencode-go":{"key":"…"}}`，本机不存在）或设置手填。
- Go 订阅用量：`GET https://opencode.ai/zen/go/v1/usage` `Authorization: Bearer <key>` → `{usage:{rolling:{usagePercent|usedPercent|…, resetInSec|resetAt…}, weekly:{…}, monthly:{…}}, renewAt?}`。键名不稳定，解析时按候选列表取（percentKeys / resetInKeys / resetAtKeys）。
- PAYG 余额/月度花费只有 console cookie 接口（`/console/api/billing/status`、`/console/api/usage/summary`），需要浏览器 cookie，不做。

### 智谱 GLM（z.ai / bigmodel.cn，扩展点）
- `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`（global 为 `https://api.z.ai/…`）`Authorization: Bearer <key>` → `{code, data:{limits:[{type, percentage, usage, currentValue, remaining, nextResetTime(ms), unit, number}]}}`。已按此实现 `ZaiProvider`（默认关闭，需手填 key）。

## 架构决定

1. **Mac 是 hub**：Mac Mini 常开、在 Tailscale 上。菜单栏 App 持凭据、轮询、存样本、算预测，并用 `NWListener` 提供 `GET /v1/health|snapshot|history`（Bearer token）。iOS/watch 只消费 JSON，不碰任何供应商凭据，也不需要 Apple 付费能力（无 CloudKit/Push）。
2. **预测**在 `QuotaCore.ForecastEngine`：对当前窗口（`resetsAt - windowDuration` 之后，或检测到 utilization 下跌即视为新窗口）内样本做最小二乘回归；输出 reset 时预计用量、打满时刻、pace（相对线性预算的偏差）。余额型对最近 7 天做回归得日均花费与剩余天数。样本不足 2 个或跨度 < 10 分钟 → `insufficient`。
3. **macOS 不用 App Group**（本机 Xcode 没登录 Apple ID，profile 拿不到）：主 App 和 widget 都是 Manual 签名 "Apple Development" / team `88U7V98QAC`，无 sandbox，共享 `~/Library/Application Support/QuotaPulse/snapshot.json`。iOS/watchOS 用 App Group `group.app.lishuyu.quotapulse`（模拟器不校验，真机需在开发者账号开通）。
4. **通知权限懒申请**：阈值告警默认关；打开时才 `requestAuthorization`，避免无人值守时弹系统对话框。
5. **Keychain 读取走 `/usr/bin/security` 子进程 + 3 秒超时**：Claude Code 自己用该 CLI 写入，ACL 已包含它，因此不会弹窗；万一弹窗，超时 kill 子进程即关闭对话框并退回文件读取。
6. **不做浏览器 cookie 导入**：CodexBar 的 cookie 路线需要读 Chrome cookie 数据库（Keychain 弹窗 + 隐私面大），与"无人值守、不弹窗"冲突。
