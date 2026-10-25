# claude-code-subscription-switch

[中文](README.md) · **English** · [日本語](README.ja.md)

Command name: `claude-switch`.

Automatic switching for [Claude Code](https://code.claude.com) between your **Claude subscription** (Pro/Max/Team usage limits) and your own **Anthropic API key**. Stay on the subscription while it has quota, fall over to the API key when a 5-hour or weekly window is exhausted, and fall back to the subscription when the window resets. Works for running sessions (CLI and the VS Code extension) without restarts, using only official Claude Code extension points. Linux / WSL; no dependencies beyond Python 3.

```text
subscription usage ≥ 95%  ──►  add apiKeyHelper ──► API mode (pay per token)
         ▲                                              │
         └── remove apiKeyHelper ◄── resets_at reached ◄┘
                              (or soft spend limit / API error → back to subscription, API locked)
```

## How it works

Only official Claude Code extension points are used. No environment variables are touched and your login is never changed.

| Extension point | Role |
|---|---|
| `statusLine` | After every response Claude Code feeds the script `rate_limits` (5-hour / 7-day usage and reset time), `cost` and `session_id`. The script decides and renders the current mode and usage in the status bar |
| `apiKeyHelper` | Written into `~/.claude/settings.json` **only while in API mode**. Claude Code hot-reloads settings.json, so a running session uses the key on its very next request and returns to the subscription when the key is removed (verified on a live session, see docs/02) |
| `StopFailure` hook | Fallback: a subscription usage-limit error (`rate_limit`) triggers the switch; an auth/billing error while in API mode switches back immediately and locks API mode |
| `Stop` hook | A cheap re-check after each response (reset time reached? soft limit exceeded?) for sessions without a status line |

In subscription mode the key is present in no process environment and no settings file, so it cannot be billed by accident.

## Prerequisites

- Linux or WSL (macOS should work but is untested); `python3` 3.8+, no third-party packages.
- Claude Code ≥ 2.1.26x (needs the `StopFailure` hook and statusLine `rate_limits`). Verified on 2.1.299 / 2.1.310.
- Logged in to `claude` with your subscription account (`claude auth status` shows `claude.ai`).
- An Anthropic API key (`sk-ant-api03-...`).
- **No** `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` in the environment and no other `apiKeyHelper` in settings — they take precedence over the subscription and would defeat "subscription by default".

## Install

```bash
git clone https://github.com/ganwt/claude-code-subscription-switch.git
cd claude-code-subscription-switch
bash install.sh              # copies to ~/.local/share/claude-switch, links into ~/.local/bin, registers statusLine/hooks (settings.json is backed up first)
claude-switch set-key        # paste the API key (hidden input); stored in ~/.config/claude-switch/api_key with mode 0600
claude-switch status
```

`status` should show `effective: max`, `apiKeyHelper: absent`, `api key file: present`, `claude auth: claude.ai`. New sessions pick it up immediately; already-open sessions hot-reload settings.json.

Also create a dedicated workspace for this key in the [Anthropic Console](https://console.anthropic.com) and set a monthly spend limit there (see "Cost control" below).

## Daily use

```bash
claude-switch status            # mode, 5h/7d usage, API spend, and the credential Claude Code actually resolves
claude-switch set-mode auto     # default: switch automatically; also clears an API lock
claude-switch set-mode max      # force subscription (never switch, even when exhausted)
claude-switch set-mode api      # force API key
claude-switch log [N]           # switch history: time, reason, before/after, verification
claude-switch check             # re-evaluate now
```

Status bar examples: `MAX · 5h 42% ↻22:30 · 7d 12% ↻Mon 09:00` or `API · today $0.42/5 · Max back ↻22:30`.

## Configuration `~/.config/claude-switch/config.json`

| Key | Default | Meaning |
|---|---|---|
| `switch_pct` | 95 | Switch to API when any window reaches this used percentage (the status line only updates after successful responses, so a margin is more reliable than waiting for the error at 100%) |
| `rate_limit_guard_pct` | 80 | A `StopFailure rate_limit` counts as exhaustion only if the last known usage is at least this high, or usage data is stale — so an ordinary 429 is not mistaken for exhaustion |
| `usage_stale_sec` | 900 | Usage data older than this is considered stale (e.g. extension-only sessions without a status line) |
| `cooldown_sec` | 600 | Minimum interval before switching back to the subscription (anti-flapping) |
| `api_daily_limit_usd` | 5.0 | Daily **soft** spend limit in API mode (client-side estimate at list price) |
| `api_monthly_limit_usd` | 50.0 | Monthly soft spend limit |

When a soft limit is exceeded, or `authentication_failed` / `billing_error` / `account_on_hold` / `invalid_request` occurs in API mode, the tool switches back to the subscription immediately and **locks API mode**: no more automatic switching, even when exhausted, until you run `claude-switch set-mode auto`.

## Cost control: the honest boundaries

- The local soft limits are not hard caps: they settle after each successful response, so one long response can overshoot; extension sessions that do not run the status line are not metered.
- **A hard cap is only possible in the Anthropic Console**: give this key its own workspace and a monthly spend limit.
- The first request after a switch has no prompt cache (subscription and API key are different billing entities), so a long session re-reads its whole context once at full price.
- `cost.total_cost_usd` is Claude Code's client-side estimate at list price and may differ from your invoice.

## File locations

```text
~/.local/share/claude-switch/claude-switch   program
~/.local/bin/claude-switch                   symlink
~/.config/claude-switch/
  ├── state.json      mode, effective credential, usage, recovery time, per-session cost
  ├── config.json     thresholds
  ├── api_key         0600
  └── log/switch.log, log/api-cost.jsonl
~/.claude/settings.json                      only statusLine / hooks.StopFailure / hooks.Stop / apiKeyHelper are added or removed
~/.claude/backups/claude-switch/             backup before every settings.json change (last 20 kept)
```

## Uninstall / restore

```bash
bash uninstall.sh               # removes the keys above from settings.json (backup taken), deletes program and symlink
rm -rf ~/.config/claude-switch  # state, logs and the key, when you want them gone
```

You can also copy a `~/.claude/backups/claude-switch/settings-*.json` back by hand.

## Tests

```bash
bash tests/test.sh      # 12 scenarios in a temp dir: no real config, no network, no real key
```

## Known limitations

- Switching happens between requests. The request that hits the limit fails, and Claude Code's auto-continue may enter its "waiting for reset" state; send a new message (or `/rate-limit-options`) and it continues with the new credential. Conversation history is preserved.
- Whether the VS Code extension executes the `statusLine` command is unverified; hooks run in IDE extensions per the docs. If the extension does not run the status line, exhaustion detection there relies on `StopFailure rate_limit` and recovery on the `Stop` hook check, with no metering.
- That a subscription usage-limit error surfaces as `StopFailure.error == rate_limit` is inferred from the docs; it was not verified without exhausting a real quota.
- Linux / WSL only; native Windows Claude Code is not covered.

## Documents (Chinese)

- [Prompt.md](Prompt.md): the original task prompt given to the AI coding assistant (generalized)
- [docs/01-调查与方案.md](docs/01-调查与方案.md): environment investigation, confirmed official capabilities, feasibility and architecture
- [docs/02-实施与测试记录.md](docs/02-实施与测试记录.md): the two key experiments, end-to-end test, scenario test results

## License

MIT
