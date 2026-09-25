# Shapes `gh api --paginate` output into pastor lines. The input is slurped:
# an array of pages, each a JSON array of issues. Pull requests come from the
# same endpoint (with a `pull_request` key) and are not issues to work on.
[.[][] | select(.pull_request == null)]
| sort_by(.updated_at)
| {
    type: "log",
    level: "info",
    message: "\(length) issues in \($repo) labelled \($label), state \($state), updated since \($since)"
  },
  (.[] | {
    type: "item",
    key: (.number | tostring),
    title: .title,
    body: (.body // ""),
    url: .html_url,
    author: .user.login
  }),
  # The newest change seen; the next run asks for updates from here on.
  (if length > 0 then {type: "cursor", value: .[-1].updated_at} else empty end)
