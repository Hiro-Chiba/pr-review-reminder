# PR Review Reminder

PRの状態をチェックし、Slackにリマインダーを送るBot。

- 自分のPR: レビュー待ち・修正待ち・マージ可能などのステータスを通知
- レビュー依頼: 自分がレビュアーに設定されている他人のPRを通知

GitHub Actions cron（平日8:00 JST）で自動実行。該当PRが0件なら「対象PRなし」を通知。

## 通知イメージ

```
👀 PRリマインダー

── 自分のPR ──
my-api
⏳ レビュー待ち | #142 feat: add billing endpoint | 5日経過 | Reviewer: alice
✅ マージ可能 | #456 approved PR title
✏️ 修正待ち | #138 fix: correct tax calculation | 3日経過 | Reviewer: bob

── レビュー依頼 ──
frontend
🔍 レビューしてね | #321 feat: new dashboard | 2日経過
```

### ステータス一覧

| 表示 | 意味 |
|---|---|
| ⏳ レビュー待ち | レビュアーがまだ見ていない |
| ✏️ 修正待ち | Changes Requested。自分が対応する番 |
| 🔄 再レビュー依頼忘れ | 対応済みだがre-requestを送っていない |
| ⚠️ Reviewer未設定 | レビュアーが設定されていない |
| ✅ マージ可能 | Approveされており、マージできる状態 |
| 🔍 レビューしてね | 自分がレビュアーに設定されている他人のPR |

## セットアップ

### 1. GitHub Secrets の設定

Settings > Secrets and variables > Actions に以下を登録：

| Secret名 | 内容 | 例 |
|---|---|---|
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL | `https://hooks.slack.com/services/...` |
| `GH_PAT` | GitHub Fine-grained PAT（対象orgのPR読み取り権限） | `github_pat_...` |
| `GH_ORG_NAME` | GitHub Organization名 | `my-org` |
| `TARGET_REPOS` | 監視対象リポジトリ（カンマ区切り） | `api,frontend,admin` |
| `PR_AUTHOR` | 通知対象のGitHubユーザー名 | `octocat` |
| `IGNORE_REVIEWERS` | 除外するレビュアー（任意、カンマ区切り） | `aws-security-agent,dependabot[bot]` |

### 2. Slack Incoming Webhook の作成

1. [Slack API](https://api.slack.com/apps) > Create an App > From scratch
2. Incoming Webhooks を On にする
3. Add New Webhook to Workspace で通知先チャンネルを選択
4. 生成されたURLを `SLACK_WEBHOOK_URL` に設定

### 3. GitHub PAT の作成

1. GitHub Settings > Developer settings > Fine-grained personal access tokens
2. Resource owner: 対象Organization
3. Repository access: 監視対象リポジトリを選択
4. Permissions > Pull requests: **Read**

### 4. 動作確認

Actions > PR Review Reminder > Run workflow で手動実行。

## カスタマイズ

**経過日数** — ワークフローの env に `STALE_DAYS` を追加（デフォルト: 2）

**実行スケジュール** — `.github/workflows/pr-review-reminder.yml` の cron を変更

```yaml
schedule:
  - cron: '0 23 * * 0-4'  # 平日 08:00 JST (UTC+9)
```

## License

MIT
