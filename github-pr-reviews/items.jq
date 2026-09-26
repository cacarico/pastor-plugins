# Shapes `gh api graphql --paginate` output into pastor lines. The input is
# slurped: an array of pages, each holding a page of open pull requests with
# their reviews and review threads. Every review submitted since the cursor
# moves it, whoever wrote it and whether or not it makes an item, so a run
# never looks at the same reviews twice.
def location: .path + (if (.line // .originalLine) then ":\(.line // .originalLine)" else "" end);

[.[].data.repository.pullRequests.nodes[]] as $prs
| [ $prs[] as $pr
    | $pr.reviews.nodes[]
    # A pending review has no submittedAt; it is not written yet.
    | select(.submittedAt != null and .submittedAt >= $since)
    | {pr: $pr, review: .} ]
| sort_by(.review.submittedAt) as $new
| [ $new[]
    | select((.review.author.login // "") | test($reviewer; "i"))
    | .review as $r
    # A thread belongs to the review that opened it, but replies in it come
    # from other reviews: keep only this review's comments.
    | [ .pr.reviewThreads.nodes[]
        | select(.isResolved | not)
        | .comments.nodes[]
        | select(.pullRequestReview.databaseId == $r.databaseId) ] as $open
    | select(($open | length) > 0 or ($only_with_findings | not))
    | {
        type: "item",
        key: ($r.databaseId | tostring),
        pr: .pr.number,
        title: .pr.title,
        branch: .pr.headRefName,
        head: .pr.headRefOid,
        review_url: $r.url,
        body: ($open | map("## \(.databaseId)\n\(location)\n\(.body)") | join("\n\n"))
      } ]
| {
    type: "log",
    level: "info",
    message: "\(length) reviews by \($reviewer) on \($prs | length) open pull requests in \($repo), submitted since \($since)"
  },
  ($prs[]
    | select(.reviews.pageInfo.hasNextPage or .reviewThreads.pageInfo.hasNextPage)
    | {type: "log", level: "warn", message: "pull request #\(.number) has more than 100 reviews or review threads; only the first 100 are read"}),
  .[],
  # The newest review seen; the next run looks from here on.
  (if ($new | length) > 0 then {type: "cursor", value: $new[-1].review.submittedAt} else empty end)
