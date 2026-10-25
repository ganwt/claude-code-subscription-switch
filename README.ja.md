# claude-code-subscription-switch

[中文](README.md) · [English](README.en.md) · **日本語**

コマンド名: `claude-switch`

[Claude Code](https://code.claude.com) の認証を、**Claude サブスクリプション**（Pro/Max/Team の利用上限）と自分の **Anthropic API キー**の間で自動的に切り替えるツールです。サブスクリプションの枠が残っている間はそちらを使い、5 時間または週間ウィンドウを使い切ったら API キーに切り替え、ウィンドウがリセットされたらサブスクリプションに戻します。実行中のセッション（CLI と VS Code 拡張）にも再起動なしで効きます。Claude Code の公式な拡張ポイントのみを使用。Linux / WSL 対応、依存は Python 3 のみ。

```text
サブスク使用率 ≥ 95%  ──►  apiKeyHelper を追加 ──► API モード（トークン課金）
        ▲                                               │
        └── apiKeyHelper を削除 ◄── resets_at に到達 ◄────┘
                             （またはソフト上限 / API エラー → サブスクに戻し API をロック）
```

## 仕組み

Claude Code の公式な拡張ポイントだけを使います。環境変数には触れず、ログイン状態も変更しません。

| 拡張ポイント | 役割 |
|---|---|
| `statusLine` | 応答のたびに Claude Code が `rate_limits`（5 時間 / 7 日の使用率とリセット時刻）、`cost`、`session_id` をスクリプトに渡します。スクリプトはこれをもとに判断し、現在のモードと使用率をステータスバーに表示します |
| `apiKeyHelper` | **API モードの間だけ** `~/.claude/settings.json` に書き込まれます。settings.json はホットリロードされるため、実行中のセッションも次のリクエストからキーを使い、削除すればサブスクリプションに戻ります（実セッションで検証済み、docs/02 参照） |
| `StopFailure` フック | フォールバック: サブスクリプションの上限エラー（`rate_limit`）で切り替えを発火。API モード中の認証/課金エラーは即座にサブスクリプションへ戻し、API モードをロック |
| `Stop` フック | 応答ごとの軽い再チェック（リセット時刻到達？ソフト上限超過？）。ステータスラインのないセッション向け |

サブスクリプションモードでは、キーはどのプロセスの環境変数にも設定ファイルにも存在しないため、誤って課金されることはありません。

## 前提条件

- Linux または WSL（macOS は動くはずですが未検証）。`python3` 3.8 以上、サードパーティパッケージ不要。
- Claude Code 2.1.26x 以上（`StopFailure` フックと statusLine の `rate_limits` が必要）。2.1.299 / 2.1.310 で検証。
- サブスクリプションアカウントで `claude` にログイン済み（`claude auth status` が `claude.ai` を表示）。
- Anthropic API キー（`sk-ant-api03-...`）。
- 環境変数に `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` が**ない**こと、settings に他の `apiKeyHelper` がないこと。これらはサブスクリプションより優先されるため、「デフォルトはサブスク」が成り立たなくなります。

## インストール

```bash
git clone https://github.com/ganwt/claude-code-subscription-switch.git
cd claude-code-subscription-switch
bash install.sh              # ~/.local/share/claude-switch にコピー、~/.local/bin にリンク、statusLine/hooks を登録（settings.json は事前にバックアップ）
claude-switch set-key        # API キーを貼り付け（非表示入力）。~/.config/claude-switch/api_key に 0600 で保存
claude-switch status
```

`status` に `effective: max`、`apiKeyHelper: absent`、`api key file: present`、`claude auth: claude.ai` と出れば完了です。新しいセッションには即座に反映され、開いているセッションも settings.json をホットリロードします。

あわせて [Anthropic Console](https://console.anthropic.com) でこのキー専用の workspace を作り、月間の spend limit を設定しておくことを推奨します（後述「コスト管理」参照）。

## 日常の使い方

```bash
claude-switch status            # モード、5h/7d 使用率、API 支出、Claude Code が実際に解決している認証方式
claude-switch set-mode auto     # デフォルト: 自動切替。API ロックの解除にも使う
claude-switch set-mode max      # サブスクリプション固定（上限に達しても切り替えない）
claude-switch set-mode api      # API キー固定
claude-switch log [N]           # 切替履歴: 時刻、理由、前後のモード、検証結果
claude-switch check             # 今すぐ再評価
```

ステータスバーの例: `MAX · 5h 42% ↻22:30 · 7d 12% ↻Mon 09:00` / `API · today $0.42/5 · Max back ↻22:30`

## 設定 `~/.config/claude-switch/config.json`

| キー | 既定値 | 意味 |
|---|---|---|
| `switch_pct` | 95 | いずれかのウィンドウの使用率がこの値に達したら API へ切替（ステータスラインは成功した応答の後にしか更新されないため、100% のエラーを待つより余裕を持たせた方が確実） |
| `rate_limit_guard_pct` | 80 | `StopFailure rate_limit` を「上限到達」とみなすのは、直近の既知使用率がこの値以上、または使用率データが古い場合のみ。通常の 429 を誤認しないため |
| `usage_stale_sec` | 900 | 使用率データがこの秒数より古ければ「古い」とみなす（ステータスラインのない拡張のみの利用など） |
| `cooldown_sec` | 600 | サブスクリプションへ戻すまでの最小間隔（フラッピング防止） |
| `api_daily_limit_usd` | 5.0 | API モードの 1 日あたり**ソフト**上限（クライアント側の定価見積もり） |
| `api_monthly_limit_usd` | 50.0 | 月間ソフト上限 |

ソフト上限を超えた場合、または API モード中に `authentication_failed` / `billing_error` / `account_on_hold` / `invalid_request` が発生した場合は、即座にサブスクリプションに戻して **API モードをロック**します。以降は上限に達しても自動切替せず、`claude-switch set-mode auto` を実行するまで解除されません。

## コスト管理の実際の限界

- ローカルのソフト上限はハードキャップではありません。成功した応答ごとに精算するため、長い応答 1 回で超過することがあります。ステータスラインを実行しない拡張セッションは計測されません。
- **ハードキャップは Anthropic Console でのみ可能**です。このキー専用の workspace と月間 spend limit を設定してください。
- 切替直後の最初のリクエストにはプロンプトキャッシュが効きません（サブスクリプションと API キーは別の課金主体）。長いセッションではコンテキスト全体を一度、定価で読み直します。
- `cost.total_cost_usd` は Claude Code による定価ベースのクライアント側見積もりで、実際の請求と異なる場合があります。

## ファイルの場所

```text
~/.local/share/claude-switch/claude-switch   本体
~/.local/bin/claude-switch                   シンボリックリンク
~/.config/claude-switch/
  ├── state.json      モード、有効な認証、使用率、復帰時刻、セッション別コスト
  ├── config.json     しきい値
  ├── api_key         0600
  └── log/switch.log, log/api-cost.jsonl
~/.claude/settings.json                      statusLine / hooks.StopFailure / hooks.Stop / apiKeyHelper のみ追加・削除
~/.claude/backups/claude-switch/             settings.json 変更前のバックアップ（直近 20 件を保持）
```

## アンインストール / 元に戻す

```bash
bash uninstall.sh               # 上記キーを settings.json から削除（バックアップ取得）、本体とリンクを削除
rm -rf ~/.config/claude-switch  # 状態・ログ・キーも消したい場合
```

`~/.claude/backups/claude-switch/settings-*.json` を手でコピーして戻すこともできます。

## テスト

```bash
bash tests/test.sh      # 一時ディレクトリで 12 シナリオを実行。実設定・ネットワーク・実キーは使わない
```

## 既知の制限

- 切替はリクエストとリクエストの間で行われます。上限に達したそのリクエスト自体は失敗し、Claude Code の auto-continue が「リセット待ち」状態に入ることがあります。新しいメッセージを送る（または `/rate-limit-options`）と新しい認証で続行します。会話履歴は保持されます。
- VS Code 拡張が `statusLine` コマンドを実行するかは未検証です。フックはドキュメント上 IDE 拡張でも動作します。拡張がステータスラインを実行しない場合、拡張側の上限検知は `StopFailure rate_limit` のみ、復帰は `Stop` フックのチェックに頼り、計測は行われません。
- サブスクリプションの上限エラーが `StopFailure.error == rate_limit` として現れることはドキュメントからの推定で、実際に上限を使い切っての検証はしていません。
- Linux / WSL のみ対応。Windows ネイティブの Claude Code は対象外です。

## ドキュメント（中国語）

- [Prompt.md](Prompt.md): AI コーディングアシスタントに渡した元の要件プロンプト（汎用化版）
- [docs/01-调查与方案.md](docs/01-调查与方案.md): 環境調査、公式機能の確認、実現可能性とアーキテクチャ
- [docs/02-实施与测试记录.md](docs/02-实施与测试记录.md): 2 つの重要な実験、E2E テスト、シナリオテスト結果

## ライセンス

MIT
