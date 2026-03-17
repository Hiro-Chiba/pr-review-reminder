#!/usr/bin/env bash
set -euo pipefail

STALE_DAYS="${STALE_DAYS:-2}"

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "Error: SLACK_WEBHOOK_URL is not set"
  exit 1
fi

if [[ -z "${GH_ORG_NAME:-}" ]]; then
  echo "Error: GH_ORG_NAME is not set"
  exit 1
fi

if [[ -z "${TARGET_REPOS:-}" ]]; then
  echo "Error: TARGET_REPOS is not set"
  exit 1
fi

if [[ -z "${PR_AUTHOR:-}" ]]; then
  echo "Error: PR_AUTHOR is not set"
  exit 1
fi

now=$(date +%s)
threshold=$((STALE_DAYS * 86400))

IFS=',' read -ra repos <<< "$TARGET_REPOS"

blocks='[]'
has_stale_prs=false

for repo in "${repos[@]}"; do
  repo=$(echo "$repo" | xargs)
  full_repo="${GH_ORG_NAME}/${repo}"

  echo "Checking ${full_repo}..."

  prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --author "$PR_AUTHOR" \
    --json number,title,createdAt,isDraft,reviewDecision,url,reviewRequests,latestReviews,reviews \
    --limit 100 2>/dev/null || echo "[]")

  stale_prs=$(echo "$prs" | jq -r --argjson now "$now" --argjson threshold "$threshold" '
    [.[] | select(
      .isDraft == false
      and (.reviewDecision != "APPROVED")
      and (($now - (.createdAt | fromdateiso8601)) > $threshold)
    ) | {
      number,
      title,
      url,
      days_elapsed: ((($now - (.createdAt | fromdateiso8601)) / 86400) | floor),
      review_requests: [.reviewRequests[]? | .login // .name // .slug // empty],
      latest_reviews: [.latestReviews[]? | {author: .author.login, state: .state}],
      has_reviews: ((.reviews | length) > 0),
      has_changes_requested: ([.latestReviews[]? | select(.state == "CHANGES_REQUESTED")] | length > 0)
    }] | sort_by(-.days_elapsed)')

  count=$(echo "$stale_prs" | jq 'length')

  if [[ "$count" -gt 0 ]]; then
    has_stale_prs=true

    blocks=$(echo "$blocks" | jq '. + [
      {"type": "section", "text": {"type": "mrkdwn", "text": "*'"$repo"'*"}}
    ]')

    while IFS= read -r pr; do
      url=$(echo "$pr" | jq -r '.url')
      number=$(echo "$pr" | jq -r '.number')
      title=$(echo "$pr" | jq -r '.title')
      days=$(echo "$pr" | jq -r '.days_elapsed')

      has_request=$(echo "$pr" | jq -r '.review_requests | length > 0')
      has_changes_requested=$(echo "$pr" | jq -r '.has_changes_requested')
      has_reviews=$(echo "$pr" | jq -r '.has_reviews')

      # Reviewer list: merge pending requests + reviewed people
      reviewers=$(echo "$pr" | jq -r '
        ([.review_requests[]] + [.latest_reviews[]? | .author]) | unique | join(", ")')

      # Determine status
      if [[ "$has_changes_requested" == "true" ]]; then
        status="✏️ 修正待ち（自分が対応する番）"
      elif [[ "$has_request" == "true" ]]; then
        status="⏳ レビュー待ち"
      elif [[ "$has_reviews" == "true" && "$has_request" == "false" ]]; then
        status="🔄 再レビュー依頼忘れ"
      else
        status="⚠️ Reviewer未設定"
      fi

      if [[ -z "$reviewers" ]]; then
        reviewers="未設定"
      fi

      text=$(jq -n \
        --arg url "$url" \
        --arg number "$number" \
        --arg title "$title" \
        --arg days "$days" \
        --arg reviewers "$reviewers" \
        --arg status "$status" \
        '"<" + $url + "|#" + $number + " " + $title + ">\n- " + $days + "日経過\n- Reviewer: " + $reviewers + "\n- " + $status')

      blocks=$(echo "$blocks" | jq --arg text "$text" '. + [
        {"type": "section", "text": {"type": "mrkdwn", "text": $text}}
      ]')
    done < <(echo "$stale_prs" | jq -c '.[]')

    blocks=$(echo "$blocks" | jq '. + [{"type": "divider"}]')
  fi
done

if [[ "$has_stale_prs" == "false" ]]; then
  echo "No stale PRs found. Skipping Slack notification."
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
  -X POST \
  -H 'Content-type: application/json' \
  --data "$payload" \
  "$SLACK_WEBHOOK_URL")

if [[ "$response" == "200" ]]; then
  echo "Slack notification sent successfully."
else
  echo "Error: Slack notification failed with HTTP status ${response}"
  exit 1
fi
