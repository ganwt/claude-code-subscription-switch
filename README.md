# claude-code-subscription-switch

Command name: `claude-switch`.

Automatic switching for [Claude Code](https://code.claude.com) between your **Claude subscription** (Pro/Max/Team usage limits) and your own **Anthropic API key**: stay on the subscription while it has quota, fall over to the API key when a 5-hour or weekly window is exhausted, and fall back to the subscription when the window resets. Works for running sessions (CLI and the VS Code extension) without restarts, using only official Claude Code extension points (`statusLine`, `apiKeyHelper`, hooks). Linux / WSL; no dependencies beyond Python 3.

以下为中文说明。

---

## 它做什么

平时用订阅套餐（Pro/Max/Team 的 5 小时 / 7 天限额），任一窗口用量到 95% 时自动改用你自己的 Anthropic API Key，窗口重置后自动切回。正在运行的会话（CLI 和 VS Code 扩展）无需重启。

```text
订阅用量 ≥ 95%  ──►  写入 apiKeyHelper ──► API 模式（按 Token 计费）
       ▲                                        │
       └── 删除 apiKeyHelper ◄── 到达 resets_at ◄┘
                            （或软限额 / API 错误 → 切回并锁定 API）
```

## 原理

只用 Claude Code 的官方扩展点，不碰环境变量，不改登录状态：

| 扩展点 | 用途 |
|---|---|
| `statusLine` | 每次响应后 Claude Code 把 `rate_limits`（5h / 7d 用量和重置时间）、`cost`、`session_id` 喂给脚本；脚本据此决策，并在状态栏显示当前模式和用量 |
| `apiKeyHelper` | **只在 API 模式下**写进 `~/.claude/settings.json`。settings.json 是热重载的，所以正在运行的会话下一次请求就会改用 Key，删掉后又回到订阅（已实测，见 docs/02） |
| `StopFailure` hook | 兜底：订阅限额错误（`rate_limit`）触发切换；API 模式下出现认证/计费错误立即切回订阅并锁定 API |
| `Stop` hook | 每次响应后做一次廉价检查（重置时间到了没、软限额超了没），供没有状态栏的会话使用 |

订阅模式下 Key 不会出现在任何进程环境或 settings 里，不可能被误计费。

## 前提

- Linux 或 WSL（macOS 理论可用，未测试）；`python3`（3.8+，无第三方包）。
- Claude Code ≥ 2.1.26x（需要 `StopFailure` hook 和 statusLine `rate_limits`）。本项目在 2.1.299 / 2.1.310 上验证。
- 已用订阅账号 `claude` 登录（`claude auth status` 显示 `claude.ai`）。
- 一个 Anthropic API Key（`sk-ant-api03-...`）。
- 环境里**没有** `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`，settings 里没有别的 `apiKeyHelper`——它们的优先级高于订阅，会让"默认订阅"失效。

## 安装

```bash
git clone https://github.com/ganwt/claude-code-subscription-switch.git
cd claude-code-subscription-switch
bash install.sh              # 复制到 ~/.local/share/claude-switch，链接到 ~/.local/bin，注册 statusLine/hooks（先备份 settings.json）
claude-switch set-key        # 隐藏输入粘贴 API Key，存到 ~/.config/claude-switch/api_key（0600）
claude-switch status
```

`status` 里看到 `effective: max`、`apiKeyHelper: absent`、`api key file: present`、`claude auth: claude.ai` 即可。新开的会话立即生效；已经打开的会话会热重载 settings.json。

建议顺手在 [Anthropic Console](https://console.anthropic.com) 给这个 Key 单独建一个 workspace 并设置月度 spend limit（见下文"费用控制"）。

## 日常使用

```bash
claude-switch status            # 当前模式、5h/7d 用量、API 花费、Claude Code 实际解析到的认证方式
claude-switch set-mode auto     # 默认：自动切换；也用于解除 API 锁定
claude-switch set-mode max      # 强制订阅（即使限额耗尽也不切）
claude-switch set-mode api      # 强制 API
claude-switch log [N]           # 切换记录：时间、原因、前后模式、验证结果
claude-switch check             # 立即重新评估
```

状态栏示例：`MAX · 5h 42% ↻22:30 · 7d 12% ↻Mon 09:00`，或 `API · today $0.42/5 · Max back ↻22:30`。

## 配置 `~/.config/claude-switch/config.json`

| 键 | 默认 | 含义 |
|---|---|---|
| `switch_pct` | 95 | 任一窗口用量达到此百分比即切到 API（状态栏只在成功响应后更新，留余量比等到 100% 报错更可靠） |
| `rate_limit_guard_pct` | 80 | `StopFailure rate_limit` 只有在最近已知用量 ≥ 此值、或用量数据过期时才视为限额耗尽，避免把普通 429 当成耗尽 |
| `usage_stale_sec` | 900 | 用量数据超过这么久没更新就视为过期（例如只用扩展、没有状态栏的情况） |
| `cooldown_sec` | 600 | 切回订阅的最小间隔，防抖 |
| `api_daily_limit_usd` | 5.0 | API 模式每日**软**上限（客户端按标价估算） |
| `api_monthly_limit_usd` | 50.0 | API 模式每月软上限 |

超过软上限、或 API 模式下出现 `authentication_failed` / `billing_error` / `account_on_hold` / `invalid_request`：立即切回订阅并**锁定 API**，之后即使限额耗尽也不再自动切换，直到运行 `claude-switch set-mode auto`。

## 费用控制的真实边界

- 本地软上限不是硬限制：它在每次成功响应后结算，一次长响应可能略超；扩展会话若不执行 statusLine 则无法计费。
- **硬限制只能在 Anthropic Console 做**：为这个 Key 单独建 workspace 并设置月度 spend limit。
- 切换后的第一次请求没有 prompt cache（订阅和 API Key 是不同计费主体），长会话会按全价重读一次上下文。
- `cost.total_cost_usd` 是 Claude Code 按标价的客户端估算，可能与账单有出入。

## 文件位置

```text
~/.local/share/claude-switch/claude-switch   程序
~/.local/bin/claude-switch                   符号链接
~/.config/claude-switch/
  ├── state.json      模式、当前生效认证、用量、恢复时间、各会话成本
  ├── config.json     阈值配置
  ├── api_key         0600
  └── log/switch.log, log/api-cost.jsonl
~/.claude/settings.json                      只增删 statusLine / hooks.StopFailure / hooks.Stop / apiKeyHelper
~/.claude/backups/claude-switch/             每次修改 settings.json 前的备份（保留最近 20 份）
```

## 卸载 / 恢复原环境

```bash
bash uninstall.sh               # 从 settings.json 移除以上键并备份；删除程序和链接
rm -rf ~/.config/claude-switch  # 需要时再删状态、日志和 Key
```

settings.json 也可以直接从 `~/.claude/backups/claude-switch/settings-*.json` 复制回去。

## 测试

```bash
bash tests/test.sh      # 在临时目录里跑 12 组场景，不碰真实配置，不联网，不用真实 Key
```

## 已知限制

- 切换发生在请求之间：限额命中的那一轮请求本身会失败，Claude Code 的 auto-continue 可能进入"等待重置"状态，此时发一条新消息（或 `/rate-limit-options`）即可用新认证继续；会话历史完整保留。
- VS Code 扩展是否执行 `statusLine` 命令尚未验证；hooks 按文档在 IDE 扩展里生效。若扩展不跑 statusLine，扩展侧的耗尽检测只能靠 `StopFailure rate_limit`，恢复靠 `Stop` hook 的检查，且不计费。
- 订阅限额命中时 `StopFailure.error` 是否为 `rate_limit` 来自文档推断，未在不耗尽真实限额的情况下验证。
- 只覆盖 Linux / WSL；Windows 原生 Claude Code 未处理。

## 文档

- [Prompt.md](Prompt.md)：交给 AI 编程助手的原始需求提示词（通用版）
- [docs/01-调查与方案.md](docs/01-调查与方案.md)：环境调查、官方能力确认、可行性与架构
- [docs/02-实施与测试记录.md](docs/02-实施与测试记录.md)：两个关键实验、端到端测试、场景测试结果

## License

MIT
