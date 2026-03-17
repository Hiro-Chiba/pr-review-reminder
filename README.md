# PR Review Reminder

自分のPRがレビューされずに放置されていないかチェックし、Slackに通知するBot。

GitHub Actions cron（平日10:00 JST）で自動実行。該当PRが0件なら通知しない。

## 通知イメージ

```
👀 レビュー待ちPRリマインダー

2日以上レビューされていないPRがあります:

partner-prop-api

#3230 fix: 未知のcolumn_idに対する警告レスポンス追加
- 40日経過
- Reviewer: kenfukumori
- ⏳ レビュー待ち

#3441 feat: グループ作成時パートナー同時指定
- 24日経過
- Reviewer: kenfukumori
- 🔄 再レビュー依頼忘れ
```

### ステータス一覧

| 表示 | 意味 |
|---|---|
| ⏳ レビュー待ち | レビュアーがまだ見ていない |
| ✏️ 修正待ち | Changes Requested。自分が対応する番 |
| 🔄 再レビュー依頼忘れ | 対応済みだがre-requestを送っていない |
| ⚠️ Reviewer未設定 | レビュアーが設定されていない |

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
  - cron: '0 1 * * 1-5'  # 平日 10:00 JST (UTC+9)
```

## License

MIT
