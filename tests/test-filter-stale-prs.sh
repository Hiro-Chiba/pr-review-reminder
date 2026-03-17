#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JQ_FILTER="${SCRIPT_DIR}/../scripts/filter-stale-prs.jq"

passed=0
failed=0
total=0

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  total=$((total + 1))

  if [[ "$expected" == "$actual" ]]; then
    echo "  ✅ ${test_name}"
    passed=$((passed + 1))
  else
    echo "  ❌ ${test_name}"
    echo "     expected: ${expected}"
    echo "     actual:   ${actual}"
    failed=$((failed + 1))
  fi
}

run_filter() {
  local input="$1"
  local now="$2"
  local threshold="$3"
  local ignore="${4:-[]}"
  echo "$input" | jq --argjson now "$now" --argjson threshold "$threshold" --argjson ignore_reviewers "$ignore" -f "$JQ_FILTER"
}

# Fixed "now" for all tests: 2026-03-17T06:00:00Z
NOW=1773727200
# 2 days in seconds
THRESHOLD=172800

# ============================================================
echo ""
echo "=== Case 1: レビュー待ち (reviewer assigned, not yet reviewed) ==="
# Last commit: 5 days ago, reviewer requested, no reviews
INPUT='[{
  "number": 100,
  "title": "feat: add login",
  "url": "https://github.com/org/repo/pull/100",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [{"login": "alice"}],
  "latestReviews": [],
  "reviews": [],
  "commits": [{"committedDate": "2026-03-12T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "status is review_pending" "review_pending" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "days_elapsed is 5" "5" "$(echo "$result" | jq -r '.[0].days_elapsed')"
assert_eq "reviewer is alice" "alice" "$(echo "$result" | jq -r '.[0].review_requests[0]')"

# ============================================================
echo ""
echo "=== Case 2: 修正待ち (changes requested) ==="
# Last review (CHANGES_REQUESTED): 3 days ago, last commit: 10 days ago
INPUT='[{
  "number": 200,
  "title": "fix: tax calc",
  "url": "https://github.com/org/repo/pull/200",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "CHANGES_REQUESTED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "bob"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-03-14T06:00:00Z"}],
  "reviews": [{"author": {"login": "bob"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-03-14T06:00:00Z"}],
  "commits": [{"committedDate": "2026-03-07T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "status is changes_requested" "changes_requested" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "days_elapsed is 3 (from last review, not commit)" "3" "$(echo "$result" | jq -r '.[0].days_elapsed')"

# ============================================================
echo ""
echo "=== Case 3: 再レビュー依頼忘れ (reviewed, fixed, but no re-request) ==="
# Has reviews, reviewRequests is empty, last commit: 4 days ago
INPUT='[{
  "number": 300,
  "title": "refactor: auth",
  "url": "https://github.com/org/repo/pull/300",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "charlie"}, "state": "COMMENTED", "submittedAt": "2026-03-10T06:00:00Z"}],
  "reviews": [{"author": {"login": "charlie"}, "state": "COMMENTED", "submittedAt": "2026-03-10T06:00:00Z"}],
  "commits": [{"committedDate": "2026-03-05T06:00:00Z"}, {"committedDate": "2026-03-13T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "status is re_request_forgotten" "re_request_forgotten" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "days_elapsed is 4 (from last commit)" "4" "$(echo "$result" | jq -r '.[0].days_elapsed')"

# ============================================================
echo ""
echo "=== Case 4: Reviewer未設定 ==="
# No reviewRequests, no reviews, last commit: 6 days ago
INPUT='[{
  "number": 400,
  "title": "chore: update deps",
  "url": "https://github.com/org/repo/pull/400",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [],
  "latestReviews": [],
  "reviews": [],
  "commits": [{"committedDate": "2026-03-11T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "status is no_reviewer" "no_reviewer" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "days_elapsed is 6" "6" "$(echo "$result" | jq -r '.[0].days_elapsed')"

# ============================================================
echo ""
echo "=== Case 5: Draft PRは除外される ==="
INPUT='[{
  "number": 500,
  "title": "wip: something",
  "url": "https://github.com/org/repo/pull/500",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": true,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [{"login": "alice"}],
  "latestReviews": [],
  "reviews": [],
  "commits": [{"committedDate": "2026-03-10T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "draft PR is excluded" "0" "$(echo "$result" | jq 'length')"

# ============================================================
echo ""
echo "=== Case 6: APPROVEDは除外される ==="
INPUT='[{
  "number": 600,
  "title": "feat: approved one",
  "url": "https://github.com/org/repo/pull/600",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "APPROVED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "alice"}, "state": "APPROVED", "submittedAt": "2026-03-10T06:00:00Z"}],
  "reviews": [{"author": {"login": "alice"}, "state": "APPROVED", "submittedAt": "2026-03-10T06:00:00Z"}],
  "commits": [{"committedDate": "2026-03-05T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "approved PR is excluded" "0" "$(echo "$result" | jq 'length')"

# ============================================================
echo ""
echo "=== Case 7: 閾値以内のPRは除外される ==="
# Last commit: 1 day ago (within 2-day threshold)
INPUT='[{
  "number": 700,
  "title": "feat: fresh PR",
  "url": "https://github.com/org/repo/pull/700",
  "createdAt": "2026-03-16T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [{"login": "alice"}],
  "latestReviews": [],
  "reviews": [],
  "commits": [{"committedDate": "2026-03-16T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "PR within threshold is excluded" "0" "$(echo "$result" | jq 'length')"

# ============================================================
echo ""
echo "=== Case 8: 古いPRでも最近コミットしたら除外 ==="
# Created 30 days ago, but last commit: yesterday
INPUT='[{
  "number": 800,
  "title": "feat: old but active",
  "url": "https://github.com/org/repo/pull/800",
  "createdAt": "2026-02-15T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [{"login": "alice"}],
  "latestReviews": [],
  "reviews": [],
  "commits": [{"committedDate": "2026-02-15T00:00:00Z"}, {"committedDate": "2026-03-16T12:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "old PR with recent commit is excluded" "0" "$(echo "$result" | jq 'length')"

# ============================================================
echo ""
echo "=== Case 9: 修正待ちで最近レビューされたら除外 ==="
# CHANGES_REQUESTED yesterday
INPUT='[{
  "number": 900,
  "title": "fix: just reviewed",
  "url": "https://github.com/org/repo/pull/900",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "CHANGES_REQUESTED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "bob"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-03-16T12:00:00Z"}],
  "reviews": [{"author": {"login": "bob"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-03-16T12:00:00Z"}],
  "commits": [{"committedDate": "2026-03-01T00:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "recently reviewed changes_requested is excluded" "0" "$(echo "$result" | jq 'length')"

# ============================================================
echo ""
echo "=== Case 10: 複数PRの並び順 (経過日数が大きい順) ==="
INPUT='[
  {
    "number": 1001,
    "title": "newer",
    "url": "https://github.com/org/repo/pull/1001",
    "createdAt": "2026-03-01T00:00:00Z",
    "isDraft": false,
    "reviewDecision": "REVIEW_REQUIRED",
    "reviewRequests": [{"login": "alice"}],
    "latestReviews": [],
    "reviews": [],
    "commits": [{"committedDate": "2026-03-14T06:00:00Z"}]
  },
  {
    "number": 1002,
    "title": "older",
    "url": "https://github.com/org/repo/pull/1002",
    "createdAt": "2026-02-01T00:00:00Z",
    "isDraft": false,
    "reviewDecision": "REVIEW_REQUIRED",
    "reviewRequests": [{"login": "bob"}],
    "latestReviews": [],
    "reviews": [],
    "commits": [{"committedDate": "2026-03-07T06:00:00Z"}]
  }
]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "2 PRs returned" "2" "$(echo "$result" | jq 'length')"
assert_eq "older PR (more days) comes first" "1002" "$(echo "$result" | jq -r '.[0].number')"
assert_eq "newer PR comes second" "1001" "$(echo "$result" | jq -r '.[1].number')"

# ============================================================
echo ""
echo "=== Case 11: botのCOMMENTEDレビューのみ → Reviewer未設定扱い ==="
# Only bot review, no human reviewers
INPUT='[{
  "number": 1100,
  "title": "feat: bot only",
  "url": "https://github.com/org/repo/pull/1100",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"}],
  "reviews": [{"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"}],
  "commits": [{"committedDate": "2026-03-10T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
# Bot review counts as "has_reviews=true" + no reviewRequests → re_request_forgotten
assert_eq "bot-only review status is re_request_forgotten" "re_request_forgotten" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "days_elapsed is 7 (from last commit)" "7" "$(echo "$result" | jq -r '.[0].days_elapsed')"

# ============================================================
echo ""
echo "=== Case 12: CHANGES_REQUESTED + reviewRequests あり → 修正待ちが優先 ==="
# Reviewer re-requested but latestReview is still CHANGES_REQUESTED
INPUT='[{
  "number": 1200,
  "title": "fix: complex state",
  "url": "https://github.com/org/repo/pull/1200",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "CHANGES_REQUESTED",
  "reviewRequests": [{"login": "alice"}],
  "latestReviews": [{"author": {"login": "alice"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-03-10T06:00:00Z"}],
  "reviews": [{"author": {"login": "alice"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-03-10T06:00:00Z"}],
  "commits": [{"committedDate": "2026-03-12T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD")
assert_eq "changes_requested takes priority" "changes_requested" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "days from last review (7)" "7" "$(echo "$result" | jq -r '.[0].days_elapsed')"

# ============================================================
echo ""
echo "=== Case 13: 空配列 ==="
result=$(run_filter "[]" "$NOW" "$THRESHOLD")
assert_eq "empty input returns empty" "0" "$(echo "$result" | jq 'length')"

# ============================================================
echo ""
echo "=== Case 14: IGNORE_REVIEWERS でbotレビュアーを除外 ==="
INPUT='[{
  "number": 1400,
  "title": "feat: with bot reviewer",
  "url": "https://github.com/org/repo/pull/1400",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"}],
  "reviews": [{"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"}],
  "commits": [{"committedDate": "2026-03-10T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD" '["aws-security-agent"]')
assert_eq "bot ignored → no_reviewer (not re_request_forgotten)" "no_reviewer" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "bot not in latest_reviews" "0" "$(echo "$result" | jq '.[0].latest_reviews | length')"

# ============================================================
echo ""
echo "=== Case 15: IGNORE_REVIEWERS で人間レビュアーは残る ==="
INPUT='[{
  "number": 1500,
  "title": "feat: mixed reviewers",
  "url": "https://github.com/org/repo/pull/1500",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [{"login": "alice"}],
  "latestReviews": [
    {"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"},
    {"author": {"login": "alice"}, "state": "COMMENTED", "submittedAt": "2026-03-05T00:00:00Z"}
  ],
  "reviews": [
    {"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"},
    {"author": {"login": "alice"}, "state": "COMMENTED", "submittedAt": "2026-03-05T00:00:00Z"}
  ],
  "commits": [{"committedDate": "2026-03-10T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD" '["aws-security-agent"]')
assert_eq "human reviewer kept → review_pending" "review_pending" "$(echo "$result" | jq -r '.[0].status')"
assert_eq "alice in review_requests" "alice" "$(echo "$result" | jq -r '.[0].review_requests[0]')"

# ============================================================
echo ""
echo "=== Case 16: IGNORE_REVIEWERS 空なら何も除外しない ==="
INPUT='[{
  "number": 1600,
  "title": "feat: no ignore",
  "url": "https://github.com/org/repo/pull/1600",
  "createdAt": "2026-03-01T00:00:00Z",
  "isDraft": false,
  "reviewDecision": "REVIEW_REQUIRED",
  "reviewRequests": [],
  "latestReviews": [{"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"}],
  "reviews": [{"author": {"login": "aws-security-agent"}, "state": "COMMENTED", "submittedAt": "2026-03-02T00:00:00Z"}],
  "commits": [{"committedDate": "2026-03-10T06:00:00Z"}]
}]'

result=$(run_filter "$INPUT" "$NOW" "$THRESHOLD" '[]')
assert_eq "empty ignore list keeps bot" "re_request_forgotten" "$(echo "$result" | jq -r '.[0].status')"

# ============================================================
echo ""
echo "================================================"
echo "Results: ${passed}/${total} passed, ${failed} failed"
echo "================================================"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
