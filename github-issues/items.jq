# Shapes `gh api --paginate` output into pastor lines. The input is slurped:
# an array of pages, each a JSON array of issues. Pull requests come from the
# same endpoint (with a `pull_request` key) and are not issues to work on, but
# they still move the cursor: otherwise a run whose newest rows are all pull
# requests would ask for the same page forever.
[.[][]] | sort_by(.updated_at) as $all
| [$all[] | select(.pull_request == null)]
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
  (if ($all | length) > 0 then {type: "cursor", value: $all[-1].updated_at} else empty end)
