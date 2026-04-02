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

# ========================================
# Phase 1: データ収集（ステータス別JSON配列に蓄積）
# ========================================
approved_prs='[]'
review_pending_prs='[]'
changes_requested_prs='[]'
re_request_forgotten_prs='[]'
no_reviewer_prs='[]'
reviewer_prs='[]'

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

  # jqフィルタで分類
  filtered_prs=$(echo "$prs_with_commits" | jq -r --argjson now "$now" --argjson ignore_reviewers "$ignore_json" -f "${SCRIPT_DIR}/filter-stale-prs.jq")

  # ステータス別に振り分け
  while IFS= read -r pr; do
    status=$(echo "$pr" | jq -r '.status')
    pr_with_repo=$(echo "$pr" | jq --arg repo "$repo" '. + {repo: $repo}')

    case "$status" in
      approved)
        approved_prs=$(echo "$approved_prs" | jq --argjson pr "$pr_with_repo" '. + [$pr]')
        ;;
      review_pending)
        review_pending_prs=$(echo "$review_pending_prs" | jq --argjson pr "$pr_with_repo" '. + [$pr]')
        ;;
      changes_requested)
        changes_requested_prs=$(echo "$changes_requested_prs" | jq --argjson pr "$pr_with_repo" '. + [$pr]')
        ;;
      re_request_forgotten)
        re_request_forgotten_prs=$(echo "$re_request_forgotten_prs" | jq --argjson pr "$pr_with_repo" '. + [$pr]')
        ;;
      no_reviewer)
        no_reviewer_prs=$(echo "$no_reviewer_prs" | jq --argjson pr "$pr_with_repo" '. + [$pr]')
        ;;
    esac
  done < <(echo "$filtered_prs" | jq -c '.[]')

  # ========================================
  # レビュアーとして割り当てられたPRを取得
  # ========================================
  if ! rev_prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --search "review-requested:${PR_AUTHOR}" \
    --json number,title,url,createdAt,isDraft \
    --limit 100 2>&1); then
    echo "警告: ${full_repo} のレビュー依頼PR取得に失敗しました: ${rev_prs}" >&2
    continue
  fi

  # Draft PRを除外し、経過日数を計算
  rev_prs_filtered=$(echo "$rev_prs" | jq --argjson now "$now" '[
    .[] | select(.isDraft == false) |
    (.createdAt | fromdateiso8601) as $created |
    . + { days_elapsed: ((($now - $created) / 86400) | floor) }
  ] | sort_by(-.days_elapsed)')

  # repoフィールドを追加して蓄積
  reviewer_prs=$(echo "$reviewer_prs" | jq --argjson prs "$rev_prs_filtered" --arg repo "$repo" \
    '. + [$prs[] | . + {repo: $repo}]')
done

if [[ "$repo_success_count" -eq 0 ]]; then
  echo "エラー: すべてのリポジトリでAPI取得に失敗しました" >&2
  exit 1
fi

# ========================================
# Phase 2: サマリー行の生成
# ========================================
count_approved=$(echo "$approved_prs" | jq 'length')
count_review_pending=$(echo "$review_pending_prs" | jq 'length')
count_changes_requested=$(echo "$changes_requested_prs" | jq 'length')
count_re_request_forgotten=$(echo "$re_request_forgotten_prs" | jq 'length')
count_no_reviewer=$(echo "$no_reviewer_prs" | jq 'length')
count_reviewer=$(echo "$reviewer_prs" | jq 'length')

total_my_prs=$((count_approved + count_review_pending + count_changes_requested + count_re_request_forgotten + count_no_reviewer))

# サマリー行を構築（件数0のステータスは省略）
summary_parts=()
[[ "$count_approved" -gt 0 ]] && summary_parts+=("マージ可能 ${count_approved}")
[[ "$count_review_pending" -gt 0 ]] && summary_parts+=("レビュー待ち ${count_review_pending}")
[[ "$count_changes_requested" -gt 0 ]] && summary_parts+=("修正待ち ${count_changes_requested}")
[[ "$count_re_request_forgotten" -gt 0 ]] && summary_parts+=("再依頼忘れ ${count_re_request_forgotten}")
[[ "$count_no_reviewer" -gt 0 ]] && summary_parts+=("未設定 ${count_no_reviewer}")
[[ "$count_reviewer" -gt 0 ]] && summary_parts+=("レビュー依頼 ${count_reviewer}")

if [[ ${#summary_parts[@]} -eq 0 ]]; then
  summary_line="対象PRなし"
else
  summary_line=$(IFS=' / '; echo "${summary_parts[*]}")
fi

# ========================================
# Phase 3: ステータス別セクション構築
# ========================================

# jq用の経過日数フォーマット関数定義（0日→今日）
JQ_FORMAT_DAYS='def fmt_days: if . == 0 then "今日" else "\(.)日" end;'

# --- マージ可能セクション ---
build_approved_section() {
  if [[ "$count_approved" -eq 0 ]]; then return; fi

  local lines=()
  while IFS= read -r repo; do
    local nums
    nums=$(echo "$approved_prs" | jq -r --arg r "$repo" \
      '[.[] | select(.repo == $r)] | sort_by(.number) | [.[] | "<\(.url)|#\(.number)>"] | join(", ")')
    lines+=("  ${repo}: ${nums}")
  done < <(echo "$approved_prs" | jq -r '[.[].repo] | unique | .[]')

  local IFS=$'\n'
  printf '*▸ マージ可能*\n%s' "${lines[*]}"
}

# --- レビュー待ちセクション ---
build_review_pending_section() {
  if [[ "$count_review_pending" -eq 0 ]]; then return; fi

  local lines=()
  while IFS= read -r repo; do
    local repo_prs
    repo_prs=$(echo "$review_pending_prs" | jq -c --arg r "$repo" \
      '[.[] | select(.repo == $r)] | sort_by(-.days_elapsed)')

    # Reviewerセット全体（ソート済み）でグループ化
    local repo_line
    repo_line=$(echo "$repo_prs" | jq -r "${JQ_FORMAT_DAYS}"'
      group_by(.review_requests | sort | join(",")) |
      [.[] |
        (.[0].review_requests | sort | join(", ")) as $reviewer |
        ($reviewer | if . == "" then "" else " \u2192 \(.)" end) as $reviewer_part |
        if length == 1 then
          "<\(.[0].url)|#\(.[0].number)>\($reviewer_part) (\(.[0].days_elapsed | fmt_days))"
        else
          (sort_by(-.days_elapsed)) as $sorted |
          "<\($sorted[0].url)|#\($sorted[0].number)> 他\(length - 1)件\($reviewer_part) (\($sorted[0].days_elapsed | fmt_days))"
        end
      ] | join(", ")')

    lines+=("  ${repo}: ${repo_line}")
  done < <(echo "$review_pending_prs" | jq -r '[.[].repo] | unique | .[]')

  local IFS=$'\n'
  printf '*▸ レビュー待ち*\n%s' "${lines[*]}"
}

# --- 修正待ちセクション ---
build_changes_requested_section() {
  if [[ "$count_changes_requested" -eq 0 ]]; then return; fi

  local lines=()
  while IFS= read -r repo; do
    local repo_prs
    repo_prs=$(echo "$changes_requested_prs" | jq -c --arg r "$repo" \
      '[.[] | select(.repo == $r)] | sort_by(-.days_elapsed)')

    local repo_line
    repo_line=$(echo "$repo_prs" | jq -r "${JQ_FORMAT_DAYS}"'[.[] |
      ([.latest_reviews[]? | .author] | unique | join(", ")) as $reviewer |
      ($reviewer | if . == "" then "" else " \u2192 \(.)" end) as $reviewer_part |
      "<\(.url)|#\(.number)>\($reviewer_part) (\(.days_elapsed | fmt_days))"
    ] | join(", ")')

    lines+=("  ${repo}: ${repo_line}")
  done < <(echo "$changes_requested_prs" | jq -r '[.[].repo] | unique | .[]')

  local IFS=$'\n'
  printf '*▸ 修正待ち*\n%s' "${lines[*]}"
}

# --- 再依頼忘れセクション ---
build_re_request_forgotten_section() {
  if [[ "$count_re_request_forgotten" -eq 0 ]]; then return; fi

  local lines=()
  while IFS= read -r repo; do
    local repo_prs
    repo_prs=$(echo "$re_request_forgotten_prs" | jq -c --arg r "$repo" \
      '[.[] | select(.repo == $r)] | sort_by(-.days_elapsed)')

    local repo_line
    repo_line=$(echo "$repo_prs" | jq -r "${JQ_FORMAT_DAYS}"'[.[] |
      "<\(.url)|#\(.number)> (\(.days_elapsed | fmt_days))"
    ] | join(", ")')

    lines+=("  ${repo}: ${repo_line}")
  done < <(echo "$re_request_forgotten_prs" | jq -r '[.[].repo] | unique | .[]')

  local IFS=$'\n'
  printf '*▸ 再依頼忘れ*\n%s' "${lines[*]}"
}

# --- Reviewer未設定セクション ---
build_no_reviewer_section() {
  if [[ "$count_no_reviewer" -eq 0 ]]; then return; fi

  local lines=()
  while IFS= read -r repo; do
    local repo_prs
    repo_prs=$(echo "$no_reviewer_prs" | jq -c --arg r "$repo" \
      '[.[] | select(.repo == $r)] | sort_by(-.days_elapsed)')

    local repo_line
    repo_line=$(echo "$repo_prs" | jq -r "${JQ_FORMAT_DAYS}"'
      ([.[].days_elapsed] | max | fmt_days) as $max_days |
      ([.[] | "<\(.url)|#\(.number)>"] | join(", ")) + " (\($max_days))"')

    lines+=("  ${repo}: ${repo_line}")
  done < <(echo "$no_reviewer_prs" | jq -r '[.[].repo] | unique | .[]')

  local IFS=$'\n'
  printf '*▸ Reviewer未設定*\n%s' "${lines[*]}"
}

# --- レビュー依頼セクション ---
build_reviewer_section() {
  if [[ "$count_reviewer" -eq 0 ]]; then return; fi

  local lines=()
  while IFS= read -r repo; do
    local repo_prs
    repo_prs=$(echo "$reviewer_prs" | jq -c --arg r "$repo" \
      '[.[] | select(.repo == $r)] | sort_by(-.days_elapsed)')

    local repo_line
    repo_line=$(echo "$repo_prs" | jq -r "${JQ_FORMAT_DAYS}"'[.[] |
      "<\(.url)|#\(.number)> (\(.days_elapsed | fmt_days))"
    ] | join(", ")')

    lines+=("  ${repo}: ${repo_line}")
  done < <(echo "$reviewer_prs" | jq -r '[.[].repo] | unique | .[]')

  local IFS=$'\n'
  printf '*▸ レビュー依頼*\n%s' "${lines[*]}"
}

# ========================================
# Phase 4: Slackメッセージの構築
# ========================================
if [[ "$total_my_prs" -eq 0 && "$count_reviewer" -eq 0 ]]; then
  all_blocks=$(jq -n '[
    {"type": "header", "text": {"type": "plain_text", "text": "PRリマインダー"}},
    {"type": "section", "text": {"type": "mrkdwn", "text": "対象PRなし"}}
  ]')
else
  # ヘッダー + サマリー
  all_blocks=$(jq -n --arg summary "$summary_line" '[
    {"type": "header", "text": {"type": "plain_text", "text": "PRリマインダー"}},
    {"type": "section", "text": {"type": "mrkdwn", "text": $summary}},
    {"type": "divider"}
  ]')

  # 自分のPRセクションを追加（件数0は自動スキップ）
  my_sections=(
    "$(build_approved_section)"
    "$(build_review_pending_section)"
    "$(build_changes_requested_section)"
    "$(build_re_request_forgotten_section)"
    "$(build_no_reviewer_section)"
  )

  for section_text in "${my_sections[@]}"; do
    if [[ -n "$section_text" ]]; then
      all_blocks=$(echo "$all_blocks" | jq --arg text "$section_text" \
        '. + [{"type": "section", "text": {"type": "mrkdwn", "text": $text}}]')
    fi
  done

  # レビュー依頼セクション（dividerで区切る）
  reviewer_text=$(build_reviewer_section)
  if [[ -n "$reviewer_text" ]]; then
    all_blocks=$(echo "$all_blocks" | jq --arg text "$reviewer_text" \
      '. + [{"type": "divider"}, {"type": "section", "text": {"type": "mrkdwn", "text": $text}}]')
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
