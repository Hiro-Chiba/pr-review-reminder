# 放置PRのフィルタリングと分類
# 入力: gh pr list から取得したPR配列
# 引数: $now (UNIXタイムスタンプ), $threshold (秒数), $ignore_reviewers (除外対象ログイン名の配列)
($ignore_reviewers // []) as $ignored |
[.[] | select(.isDraft == false) |
# 除外対象レビュアーを除去
.reviewRequests = [.reviewRequests[]? | select((.login // .name // .slug) as $l | $ignored | index($l) | not)] |
.latestReviews = [.latestReviews[]? | select(.author.login as $l | $ignored | index($l) | not)] |
.reviews = [.reviews[]? | select(.author.login as $l | $ignored | index($l) | not)] |

# APPROVED PRはapprovedステータスで即返却（閾値チェック不要）
if .reviewDecision == "APPROVED" then
  {
    number,
    title,
    url,
    days_elapsed: 0,
    review_requests: [.reviewRequests[]? | .login // .name // .slug // empty],
    latest_reviews: [.latestReviews[]? | {author: .author.login, state: .state}],
    status: "approved"
  }
else
  # ステータス判定フラグ
  (.reviewRequests | length > 0) as $has_request |
  ([.latestReviews[]? | select(.state == "CHANGES_REQUESTED")] | length > 0) as $has_changes_requested |
  ((.reviews | length) > 0) as $has_reviews |

  # ステータスに応じた基準日を算出
  (.commits | last | .committedDate | fromdateiso8601) as $last_commit |
  ([.reviews[]? | .submittedAt | fromdateiso8601] | if length > 0 then max else 0 end) as $last_review |

  # ステータスと経過日数
  (if $has_changes_requested then
    { status: "changes_requested", ref_date: $last_review }
  elif $has_request then
    { status: "review_pending", ref_date: $last_commit }
  elif $has_reviews and ($has_request | not) then
    { status: "re_request_forgotten", ref_date: $last_commit }
  else
    { status: "no_reviewer", ref_date: $last_commit }
  end) as $state |

  # 基準日からの経過が閾値を超えているかフィルタ
  select(($now - $state.ref_date) > $threshold) |

  {
    number,
    title,
    url,
    # 86400 = 1日の秒数
    days_elapsed: ((($now - $state.ref_date) / 86400) | floor),
    review_requests: [.reviewRequests[]? | .login // .name // .slug // empty],
    latest_reviews: [.latestReviews[]? | {author: .author.login, state: .state}],
    status: $state.status
  }
end
] | sort_by(-.days_elapsed)
