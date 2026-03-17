#!/usr/bin/env bash
set -euo pipefail

STALE_DAYS="${STALE_DAYS:-2}"
SECONDS_PER_DAY=86400

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "エラー: SLACK_WEBHOOK_URL が設定されていません"
  exit 1
fi

if [[ -z "${GH_ORG_NAME:-}" ]]; then
  echo "エラー: GH_ORG_NAME が設定されていません"
  exit 1
fi

if [[ -z "${TARGET_REPOS:-}" ]]; then
  echo "エラー: TARGET_REPOS が設定されていません"
  exit 1
fi

if [[ -z "${PR_AUTHOR:-}" ]]; then
  echo "エラー: PR_AUTHOR が設定されていません"
  exit 1
fi

now=$(date +%s)
threshold=$((STALE_DAYS * SECONDS_PER_DAY))

# 除外対象レビュアーのJSON配列を構築
ignore_json="[]"
if [[ -n "${IGNORE_REVIEWERS:-}" ]]; then
  IFS=',' read -ra ignore_arr <<< "$IGNORE_REVIEWERS"
  ignore_json=$(printf '%s\n' "${ignore_arr[@]}" | jq -R . | jq -s .)
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IFS=',' read -ra repos <<< "$TARGET_REPOS"

blocks='[]'
has_stale_prs=false
repo_success_count=0

for repo in "${repos[@]}"; do
  repo=$(echo "$repo" | xargs)
  full_repo="${GH_ORG_NAME}/${repo}"

  echo "${full_repo} を確認中..."

  # コミット情報を除いたPR一覧を取得（GraphQLノード数制限の回避）
  if ! prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --author "$PR_AUTHOR" \
    --json number,title,createdAt,isDraft,reviewDecision,url,reviewRequests,latestReviews,reviews \
    --limit 100 2>&1); then
    echo "エラー: ${full_repo} のPR一覧取得に失敗しました: ${prs}" >&2
    continue
  fi


  # PR個別に最終コミット日を取得
  prs_with_commits="[]"
  while IFS= read -r pr_number; do
    pr_data=$(echo "$prs" | jq --argjson n "$pr_number" '[.[] | select(.number == $n)][0]')
    last_commit=$(gh pr view "$pr_number" --repo "$full_repo" --json commits --jq '.commits | last | .committedDate' 2>&1) || {
      echo "警告: ${full_repo}#${pr_number} のコミット情報取得に失敗しました: ${last_commit}" >&2
      last_commit=""
    }
    if [[ -n "$last_commit" ]]; then
      pr_data=$(echo "$pr_data" | jq --arg lc "$last_commit" '. + {commits: [{committedDate: $lc}]}')
    else
      # createdAtにフォールバック
      created=$(echo "$pr_data" | jq -r '.createdAt')
      pr_data=$(echo "$pr_data" | jq --arg lc "$created" '. + {commits: [{committedDate: $lc}]}')
    fi
    prs_with_commits=$(echo "$prs_with_commits" | jq --argjson pr "$pr_data" '. + [$pr]')
  done < <(echo "$prs" | jq -r '.[] | select(.isDraft == false and .reviewDecision != "APPROVED") | .number')

  repo_success_count=$((repo_success_count + 1))
  stale_prs=$(echo "$prs_with_commits" | jq -r --argjson now "$now" --argjson threshold "$threshold" --argjson ignore_reviewers "$ignore_json" -f "${SCRIPT_DIR}/filter-stale-prs.jq")

  count=$(echo "$stale_prs" | jq 'length')

  if [[ "$count" -gt 0 ]]; then
    has_stale_prs=true

    # リポジトリ名のヘッダーブロック
    blocks=$(echo "$blocks" | jq --arg repo "$repo" '. + [
      {"type": "context", "elements": [{"type": "mrkdwn", "text": ("*" + $repo + "*")}]}
    ]')

    while IFS= read -r pr; do
      url=$(echo "$pr" | jq -r '.url')
      number=$(echo "$pr" | jq -r '.number')
      title=$(echo "$pr" | jq -r '.title')
      days=$(echo "$pr" | jq -r '.days_elapsed')
      status_key=$(echo "$pr" | jq -r '.status')

      case "$status_key" in
        review_pending)       status="⏳ レビュー待ち" ;;
        changes_requested)    status="✏️ 修正待ち（自分が対応する番）" ;;
        re_request_forgotten) status="🔄 再レビュー依頼忘れ" ;;
        no_reviewer)          status="⚠️ Reviewer未設定" ;;
        *)                    status="$status_key" ;;
      esac

      reviewers=$(echo "$pr" | jq -r '
        ([.review_requests[]] + [.latest_reviews[]? | .author]) | unique | join(", ")')

      if [[ -z "$reviewers" ]]; then
        reviewers="未設定"
      fi

      # PRリンクと詳細情報のブロック
      blocks=$(echo "$blocks" | jq \
        --arg url "$url" \
        --arg number "$number" \
        --arg title "$title" \
        --arg days "$days" \
        --arg reviewers "$reviewers" \
        --arg status "$status" \
        '. + [
          {"type": "section", "text": {"type": "mrkdwn", "text": ("<" + $url + "|#" + $number + " " + $title + ">")}},
          {"type": "context", "elements": [{"type": "mrkdwn", "text": ($days + "日経過  |  Reviewer: " + $reviewers + "  |  " + $status)}]}
        ]')
    done < <(echo "$stale_prs" | jq -c '.[]')

    blocks=$(echo "$blocks" | jq '. + [{"type": "divider"}]')
  fi
done

if [[ "$repo_success_count" -eq 0 ]]; then
  echo "エラー: すべてのリポジトリでAPI取得に失敗しました" >&2
  exit 1
fi

if [[ "$has_stale_prs" == "false" ]]; then
  echo "対象PRなし。Slack通知をスキップします。"
  exit 0
fi

header_block='[
  {"type": "header", "text": {"type": "plain_text", "text": "👀 レビュー待ちPRリマインダー"}},
  {"type": "section", "text": {"type": "mrkdwn", "text": "'"${STALE_DAYS}"'日以上レビューされていないPRがあります:"}},
  {"type": "divider"}
]'

all_blocks=$(jq -n --argjson header "$header_block" --argjson body "$blocks" '$header + $body')
payload=$(jq -n --argjson blocks "$all_blocks" '{blocks: $blocks}')

response=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 10 --max-time 30 \
  -X POST \
  -H 'Content-type: application/json' \
  --data "$payload" \
  "$SLACK_WEBHOOK_URL")

if [[ "$response" == "200" ]]; then
  echo "Slack通知を送信しました。"
else
  echo "エラー: Slack通知に失敗しました（HTTPステータス: ${response}）"
  exit 1
fi
