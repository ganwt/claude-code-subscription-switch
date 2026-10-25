# claude-switch

让 Claude Code 在订阅套餐（Pro/Max/Team 限额）与 Anthropic API Key 之间自动切换。使用说明见 README.md，调查与方案见 docs/01-调查与方案.md，实施与测试见 docs/02-实施与测试记录.md，原始需求提示词见 Prompt.md。

- 目标环境：WSL / Linux 的 CLI 与 VS Code Remote 扩展。主程序是 `bin/claude-switch`（Python 3 单文件，无第三方依赖）。
- 本仓库不得出现任何 API Key、OAuth token 或其值；测试一律用假 key（`sk-ant-api03-TESTKEY` 之类）。
- 修改 `~/.claude/settings.json` 前必须备份，只增删 `statusLine` / `hooks.Stop` / `hooks.StopFailure` / `apiKeyHelper` 四个键。
- 改动逻辑后运行 `bash tests/test.sh`；它在临时目录运行，不碰真实配置。
