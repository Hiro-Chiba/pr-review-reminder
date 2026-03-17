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

# Slack blocks array (JSON)
blocks='[]'

has_stale_prs=false

for repo in "${repos[@]}"; do
  repo=$(echo "$repo" | xargs) # trim whitespace
  full_repo="${GH_ORG_NAME}/${repo}"

  echo "Checking ${full_repo}..."

  prs=$(gh pr list \
    --repo "$full_repo" \
    --state open \
    --author "$PR_AUTHOR" \
    --json number,title,author,createdAt,isDraft,reviewDecision,url,reviewRequests,assignees \
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
      reviewers: [.reviewRequests[]? | .login // .name // .slug // empty] | join(", "),
      assignees: [.assignees[]? | .login // empty] | join(", ")
    }] | sort_by(-.days_elapsed)')

  count=$(echo "$stale_prs" | jq 'length')

  if [[ "$count" -gt 0 ]]; then
    has_stale_prs=true

    # Add repo header
    blocks=$(echo "$blocks" | jq --arg repo "$repo" '. + [
      {"type": "section", "text": {"type": "mrkdwn", "text": ("*" + $repo + "*")}}
    ]')

    # Add each PR
    while IFS= read -r pr; do
      number=$(echo "$pr" | jq -r '.number')
      title=$(echo "$pr" | jq -r '.title')
      url=$(echo "$pr" | jq -r '.url')
      days=$(echo "$pr" | jq -r '.days_elapsed')
      reviewers=$(echo "$pr" | jq -r '.reviewers')
      assignees=$(echo "$pr" | jq -r '.assignees')

      line="<${url}|#${number} ${title}> - ${days}日経過"
      if [[ -n "$reviewers" ]]; then
        line="${line}\n      Reviewer: ${reviewers}"
      else
        line="${line}\n      Reviewer: _未設定_"
      fi
      if [[ -n "$assignees" ]]; then
        line="${line}\n      Assignee: ${assignees}"
      fi

      blocks=$(echo "$blocks" | jq --arg line "$line" '. + [
        {"type": "section", "text": {"type": "mrkdwn", "text": $line}}
      ]')
    done < <(echo "$stale_prs" | jq -c '.[]')

    # Add divider between repos
    blocks=$(echo "$blocks" | jq '. + [{"type": "divider"}]')
  fi
done

if [[ "$has_stale_prs" == "false" ]]; then
  echo "No stale PRs found. Skipping Slack notification."
  exit 0
fi

# Build final payload with header
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
