#!/usr/bin/env bash
set -euo pipefail

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

# 除外対象レビュアーのJSON配列を構築
ignore_json="[]"
if [[ -n "${IGNORE_REVIEWERS:-}" ]]; then
  IFS=',' read -ra ignore_arr <<< "$IGNORE_REVIEWERS"
  ignore_json=$(printf '%s\n' "${ignore_arr[@]}" | jq -R . | jq -s .)
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IFS=',' read -ra repos <<< "$TARGET_REPOS"

# 自分のPR用ブロック（stale + approved）
my_pr_blocks='[]'
has_my_prs=false

# レビュー依頼用ブロック
reviewer_blocks='[]'
has_reviewer_prs=false

repo_success_count=0

for repo in "${repos[@]}"; do
  repo=$(echo "$repo" | xargs)
  full_repo="${GH_ORG_NAME}/${repo}"

  echo "${full_repo} を確認中..."

  # ========================================
  # 自分のPR一覧を取得
  # ========================================
  if ! prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --author "$PR_AUTHOR" \
    --json number,title,createdAt,isDraft,reviewDecision,url,reviewRequests,latestReviews,reviews \
    --limit 100 2>&1); then
    echo "エラー: ${full_repo} のPR一覧取得に失敗しました: ${prs}" >&2
    continue
  fi

  # PR個別に最終コミット日を取得（Draft・APPROVEDも含む — jqフィルタで分類）
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
  done < <(echo "$prs" | jq -r '.[] | select(.isDraft == false) | .number')

  repo_success_count=$((repo_success_count + 1))

  # jqフィルタで分類（approved + stale）
  filtered_prs=$(echo "$prs_with_commits" | jq -r --argjson now "$now" --argjson ignore_reviewers "$ignore_json" -f "${SCRIPT_DIR}/filter-stale-prs.jq")

  count=$(echo "$filtered_prs" | jq 'length')

  if [[ "$count" -gt 0 ]]; then
    has_my_prs=true

    # リポジトリ名のヘッダーブロック
    my_pr_blocks=$(echo "$my_pr_blocks" | jq --arg repo "$repo" '. + [
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
        changes_requested)    status="✏️ 修正待ち" ;;
        re_request_forgotten) status="🔄 再レビュー依頼忘れ" ;;
        no_reviewer)          status="⚠️ Reviewer未設定" ;;
        approved)             status="✅ マージ可能" ;;
        *)                    status="$status_key" ;;
      esac

      reviewers=$(echo "$pr" | jq -r '
        ([.review_requests[]] + [.latest_reviews[]? | .author]) | unique | join(", ")')

      if [[ -z "$reviewers" ]]; then
        reviewers="未設定"
      fi

      # ステータスごとにコンテキスト行を構築
      if [[ "$status_key" == "approved" ]]; then
        context_text="${status} | <${url}|#${number} ${title}>"
      else
        context_text="${status} | <${url}|#${number} ${title}> | ${days}日経過 | Reviewer: ${reviewers}"
      fi

      my_pr_blocks=$(echo "$my_pr_blocks" | jq \
        --arg text "$context_text" \
        '. + [
          {"type": "section", "text": {"type": "mrkdwn", "text": $text}}
        ]')
    done < <(echo "$filtered_prs" | jq -c '.[]')
  fi

  # ========================================
  # レビュアーとして割り当てられたPRを取得
  # ========================================
  if ! reviewer_prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --search "review-requested:${PR_AUTHOR}" \
    --json number,title,url,createdAt,isDraft \
    --limit 100 2>&1); then
    echo "警告: ${full_repo} のレビュー依頼PR取得に失敗しました: ${reviewer_prs}" >&2
    continue
  fi

  # Draft PRを除外し、経過日数を計算
  reviewer_prs_filtered=$(echo "$reviewer_prs" | jq --argjson now "$now" '[
    .[] | select(.isDraft == false) |
    (.createdAt | fromdateiso8601) as $created |
    . + { days_elapsed: ((($now - $created) / 86400) | floor) }
  ] | sort_by(-.days_elapsed)')

  reviewer_count=$(echo "$reviewer_prs_filtered" | jq 'length')

  if [[ "$reviewer_count" -gt 0 ]]; then
    has_reviewer_prs=true

    reviewer_blocks=$(echo "$reviewer_blocks" | jq --arg repo "$repo" '. + [
      {"type": "context", "elements": [{"type": "mrkdwn", "text": ("*" + $repo + "*")}]}
    ]')

    while IFS= read -r pr; do
      url=$(echo "$pr" | jq -r '.url')
      number=$(echo "$pr" | jq -r '.number')
      title=$(echo "$pr" | jq -r '.title')
      days=$(echo "$pr" | jq -r '.days_elapsed')

      context_text="🔍 レビューしてね | <${url}|#${number} ${title}> | ${days}日経過"

      reviewer_blocks=$(echo "$reviewer_blocks" | jq \
        --arg text "$context_text" \
        '. + [
          {"type": "section", "text": {"type": "mrkdwn", "text": $text}}
        ]')
    done < <(echo "$reviewer_prs_filtered" | jq -c '.[]')
  fi
done

if [[ "$repo_success_count" -eq 0 ]]; then
  echo "エラー: すべてのリポジトリでAPI取得に失敗しました" >&2
  exit 1
fi

# Slackメッセージの構築
if [[ "$has_my_prs" == "false" && "$has_reviewer_prs" == "false" ]]; then
  all_blocks=$(jq -n '[
    {"type": "header", "text": {"type": "plain_text", "text": "👀 PRリマインダー"}},
    {"type": "section", "text": {"type": "mrkdwn", "text": "対象PRなし"}}
  ]')
else
  all_blocks=$(jq -n '[
    {"type": "header", "text": {"type": "plain_text", "text": "👀 PRリマインダー"}}
  ]')

  if [[ "$has_my_prs" == "true" ]]; then
    section_header=$(jq -n '[
      {"type": "section", "text": {"type": "mrkdwn", "text": "── 自分のPR ──"}},
      {"type": "divider"}
    ]')
    all_blocks=$(jq -n --argjson a "$all_blocks" --argjson h "$section_header" --argjson b "$my_pr_blocks" '$a + $h + $b + [{"type": "divider"}]')
  fi

  if [[ "$has_reviewer_prs" == "true" ]]; then
    section_header=$(jq -n '[
      {"type": "section", "text": {"type": "mrkdwn", "text": "── レビュー依頼 ──"}},
      {"type": "divider"}
    ]')
    all_blocks=$(jq -n --argjson a "$all_blocks" --argjson h "$section_header" --argjson b "$reviewer_blocks" '$a + $h + $b + [{"type": "divider"}]')
  fi
fi

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
