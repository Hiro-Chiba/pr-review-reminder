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

message_blocks=""

for repo in "${repos[@]}"; do
  repo=$(echo "$repo" | xargs) # trim whitespace
  full_repo="${GH_ORG_NAME}/${repo}"

  echo "Checking ${full_repo}..."

  prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --author "$PR_AUTHOR" \
    --json number,title,author,createdAt,isDraft,reviewDecision,url \
    --limit 100 2>/dev/null || echo "[]")

  stale_prs=$(echo "$prs" | jq -r --argjson now "$now" --argjson threshold "$threshold" '
    [.[] | select(
      .isDraft == false
      and (.reviewDecision != "APPROVED")
      and (($now - (.createdAt | fromdateiso8601)) > $threshold)
    ) | {
      number,
      title,
      author: .author.login,
      url,
      days_elapsed: ((($now - (.createdAt | fromdateiso8601)) / 86400) | floor)
    }] | sort_by(-.days_elapsed)')

  count=$(echo "$stale_prs" | jq 'length')

  if [[ "$count" -gt 0 ]]; then
    repo_block="*${repo}*\n"

    while IFS= read -r pr; do
      number=$(echo "$pr" | jq -r '.number')
      title=$(echo "$pr" | jq -r '.title')
      author=$(echo "$pr" | jq -r '.author')
      url=$(echo "$pr" | jq -r '.url')
      days=$(echo "$pr" | jq -r '.days_elapsed')

      repo_block+="• <${url}|#${number} ${title}> (@${author}) - ${days}日経過\n"
    done < <(echo "$stale_prs" | jq -c '.[]')

    message_blocks+="${repo_block}\n"
  fi
done

if [[ -z "$message_blocks" ]]; then
  echo "No stale PRs found. Skipping Slack notification."
  exit 0
fi

text=":eyes: *レビュー待ちPRリマインダー*\n\n${STALE_DAYS}日以上レビューされていないPRがあります:\n\n${message_blocks}"

payload=$(jq -n --arg text "$text" '{text: $text}')

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
