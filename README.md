# PR Review Reminder

GitHub Actions cron で動作する Slack Bot。指定した GitHub Organization のリポジトリで、2日以上レビューされていない PR を Slack に通知します。

## 特徴

- サーバー不要（GitHub Actions のみ）
- 依存関係ゼロ（gh CLI + jq + curl）
- パブリックリポジトリ対応（機密情報はすべて GitHub Secrets で管理）
- 平日 10:00 JST に自動実行
- レビュー待ち PR が 0 件なら通知しない

## Slack メッセージ例

```
👀 レビュー待ちPRリマインダー

2日以上レビューされていないPRがあります:

repo-name
• #123 feat: add login flow (@author) - 3日経過
```

## セットアップ

### 1. Slack Incoming Webhook の作成

1. [Slack API](https://api.slack.com/apps) で Slack App を作成
2. 「Incoming Webhooks」を有効化
3. 通知先チャンネルへの Webhook URL を生成

### 2. GitHub PAT の作成

1. GitHub Settings > Developer settings > Fine-grained personal access tokens
2. 対象の Organization を選択
3. Repository access で対象リポジトリを選択
4. Permissions > Repository permissions > Pull requests: **Read**

### 3. GitHub Secrets の設定

リポジトリの Settings > Secrets and variables > Actions に以下を設定：

| Secret 名 | 内容 |
|---|---|
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL |
| `GH_ORG_NAME` | GitHub Organization 名 |
| `TARGET_REPOS` | 監視対象リポジトリ名（カンマ区切り、例: `repo-a,repo-b,repo-c`） |
| `GH_PAT` | GitHub Personal Access Token |
| `PR_AUTHOR` | 通知対象の GitHub ユーザー名 |

### 4. 動作確認

Actions タブ > PR Review Reminder > Run workflow で手動実行して確認。

## カスタマイズ

### 経過日数の変更

デフォルトは 2 日。`STALE_DAYS` 環境変数で変更可能：

```yaml
env:
  STALE_DAYS: '3'
```

### 実行スケジュールの変更

`.github/workflows/pr-review-reminder.yml` の cron 式を変更：

```yaml
schedule:
  - cron: '0 1 * * 1-5'  # 平日 10:00 JST
```

## License

MIT
