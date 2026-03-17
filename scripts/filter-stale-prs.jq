# Filter and classify stale PRs
# Input: array of PRs from gh pr list
# Arguments: $now (unix timestamp), $threshold (seconds)
[.[] | select(
  .isDraft == false
  and (.reviewDecision != "APPROVED")
) |
# Determine status flags
(.reviewRequests | length > 0) as $has_request |
([.latestReviews[]? | select(.state == "CHANGES_REQUESTED")] | length > 0) as $has_changes_requested |
((.reviews | length) > 0) as $has_reviews |

# Calculate reference date based on status
(.commits | last | .committedDate | fromdateiso8601) as $last_commit |
([.reviews[]? | .submittedAt | fromdateiso8601] | if length > 0 then max else 0 end) as $last_review |

# Status and elapsed days
(if $has_changes_requested then
  { status: "changes_requested", ref_date: $last_review }
elif $has_request then
  { status: "review_pending", ref_date: $last_commit }
elif $has_reviews and ($has_request | not) then
  { status: "re_request_forgotten", ref_date: $last_commit }
else
  { status: "no_reviewer", ref_date: $last_commit }
end) as $state |

# Filter by threshold using the appropriate reference date
select(($now - $state.ref_date) > $threshold) |

{
  number,
  title,
  url,
  days_elapsed: ((($now - $state.ref_date) / 86400) | floor),
  review_requests: [.reviewRequests[]? | .login // .name // .slug // empty],
  latest_reviews: [.latestReviews[]? | {author: .author.login, state: .state}],
  status: $state.status
}] | sort_by(-.days_elapsed)
